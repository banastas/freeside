import AppKit
import FreesideKit
import SwiftUI
import UniformTypeIdentifiers

/// What's holding a drive, with ways to let go of it, inside the drive's
/// card. Confirmations are inline too: a transient popover is a poor host
/// for sheets, and errors never appear as modal alerts (PRD §6.4).
struct BlockersView: View {
    let ejector: Ejector
    let targetID: EjectTarget.ID

    private enum Confirmation: Equatable {
        case terminate(Blocker)
        /// After SIGTERM, until the process is gone from the scan.
        case kill(Blocker)
        case force
    }

    @State private var confirmation: Confirmation?

    private var status: Ejector.Status? { ejector.statuses[targetID] }

    var body: some View {
        if let status {
            VStack(alignment: .leading, spacing: 8) {
                header(status)
                if let report = status.report {
                    rows(report, failed: status.failure != nil)
                } else {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Looking for what's using it…")
                    }
                    .foregroundStyle(.secondary)
                }
                footer(status)
            }
            .font(.caption)
            .controlSize(.small)
            .padding(8)
            .background(.fill.quaternary, in: .rect(cornerRadius: 8))
            .onAppear {
                ejector.setWatching(targetID, true)
                // The 2 s rescans stop while the popover is closed.
                if status.report != nil, status.phase == .idle {
                    Task { await ejector.rescan(targetID) }
                }
            }
            .onDisappear { ejector.setWatching(targetID, false) }
            .onChange(of: status.report?.blockers.map(\.pid)) { _, pids in
                // A process that was terminated has gone.
                if case .kill(let blocker) = confirmation, pids?.contains(blocker.pid) != true { confirmation = nil }
            }
        }
    }

    @ViewBuilder
    private func header(_ status: Ejector.Status) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(status.failure == nil ? "Who's using it" : "Couldn't eject")
                .fontWeight(.semibold)
            if let failure = status.failure {
                Text(failure.message)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if status.failure != nil, !status.stillMounted.isEmpty {
                Text("Still mounted: \(status.stillMounted.formatted(.list(type: .and)))")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func rows(_ report: BlockerReport, failed: Bool) -> some View {
        if report.isEmpty {
            Text(failed
                ? "None of your apps is using the drive. A system process may be holding it, such as Spotlight (mds) or Time Machine (backupd)."
                : "None of your apps is using the drive.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        ForEach(report.images) { image in
            HStack(spacing: 8) {
                // By type, so nothing on the drive is read.
                Image(nsImage: NSWorkspace.shared.icon(for: UTType(filenameExtension: "dmg") ?? .diskImage))
                    .resizable()
                    .frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(image.fileName).lineLimit(1).truncationMode(.middle)
                    Text("Mounted from this drive").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Button("eject image") {
                    Task { await ejector.ejectImage(image, from: targetID) }
                }
            }
        }
        ForEach(report.blockers) { blocker in
            BlockerRow(blocker: blocker) {
                ejector.quit(blocker)
            } terminate: {
                confirmation = .terminate(blocker)
            }
        }
    }

    @ViewBuilder
    private func footer(_ status: Ejector.Status) -> some View {
        switch confirmation {
        case .terminate(let blocker):
            confirm(
                "Terminate \(blocker.displayName)? It's asked to stop (SIGTERM); unsaved work in it may be lost.",
                action: "terminate"
            ) {
                ejector.terminate(blocker)
                confirmation = .kill(blocker)
            }
        case .kill(let blocker):
            confirm(
                "Waiting for \(blocker.displayName) to exit. It can be stopped at once (SIGKILL), with no chance to save.",
                action: "kill", cancel: "wait"
            ) {
                ejector.terminate(blocker, kill: true)
                confirmation = nil
            }
        case .force:
            confirm("Force eject? Apps with files open on the drive may lose or damage them.", action: "force eject") {
                confirmation = nil
                Task { await ejector.retry(targetID, force: true) }
            }
        case nil:
            HStack {
                if status.phase != .idle { ProgressView().controlSize(.mini) }
                Spacer()
                Button("close") { ejector.dismiss(targetID) }
                if status.failure != nil {
                    Button("force eject…") { confirmation = .force }
                        .disabled(status.phase != .idle)
                }
                Button(status.failure == nil ? "eject" : "retry") {
                    Task { await ejector.retry(targetID) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(status.phase != .idle)
            }
        }
    }

    private func confirm(_ message: String, action: String, cancel: String = "cancel", perform: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(cancel) { confirmation = nil }
                    .keyboardShortcut(.cancelAction)
                Button(action, role: .destructive, action: perform)
                    .tint(.red)
            }
        }
        .padding(6)
        .background(Color.red.opacity(0.08), in: .rect(cornerRadius: 6))
    }
}

private struct BlockerRow: View {
    let blocker: Blocker
    let quit: () -> Void
    let terminate: () -> Void
    @State private var expanded = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(blocker.isAppProcess ? blocker.displayName : blocker.processName)
                    .lineLimit(1)
                Text(summary).font(.caption2).foregroundStyle(.secondary)
                if let first = blocker.uses.first {
                    Text(first.path)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(first.path)
                        .textSelection(.enabled)
                }
                if blocker.uses.count > 1 {
                    DisclosureGroup("\(blocker.uses.count - 1) more", isExpanded: $expanded) {
                        ForEach(Array(blocker.uses.dropFirst().enumerated()), id: \.offset) { _, use in
                            Text("\(use.reason.rawValue): \(use.path)")
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(use.path)
                        }
                    }
                    .font(.caption2)
                }
            }
            Spacer(minLength: 4)
            if blocker.isAppProcess {
                Button("quit", action: quit)
            } else {
                Button("terminate…", action: terminate)
            }
        }
    }

    /// "in Terminal · pid 4321 · working directory"
    private var summary: String {
        var parts: [String] = []
        if let app = blocker.app, app.pid != blocker.pid {
            // A helper is titled with its app; a shell with its own name.
            parts.append(blocker.isAppProcess ? blocker.processName : "in \(app.name)")
        }
        parts.append("pid \(blocker.pid)")
        parts.append(blocker.uses.first?.reason.rawValue ?? "")
        return parts.joined(separator: " · ")
    }

    /// From the running app, so freeside never opens anything on the drive.
    private var icon: NSImage {
        if let pid = blocker.app?.pid, let icon = NSRunningApplication(processIdentifier: pid)?.icon { return icon }
        return NSImage(systemSymbolName: "terminal", accessibilityDescription: nil) ?? NSImage()
    }
}
