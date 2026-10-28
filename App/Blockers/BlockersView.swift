import AppKit
import FreesideKit
import SwiftUI
import UniformTypeIdentifiers

/// What's holding a drive, with ways to let go of it. Shown in its own
/// panel for now; it moves into the popover in M5.
struct BlockersView: View {
    let ejector: Ejector
    let targetID: EjectTarget.ID
    let close: () -> Void

    @State private var confirmTerminate: Blocker?
    @State private var confirmKill: Blocker?
    @State private var confirmForce = false
    /// "Who's using this?" opens the panel just before its scan starts.
    @State private var seenStatus = false

    private var status: Ejector.Status? { ejector.statuses[targetID] }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let status {
                header(status)
                if let report = status.report {
                    rows(report, failed: status.failure != nil)
                } else {
                    ProgressView().controlSize(.small)
                }
                footer(status)
            } else if !seenStatus {
                ProgressView().controlSize(.small)
            } else {
                Label("Ejected", systemImage: "checkmark.circle")
                    .font(.headline)
                    .task {
                        try? await Task.sleep(for: .seconds(1))
                        close()
                    }
            }
        }
        .padding(16)
        .frame(width: 420)
        .onAppear { ejector.setWatching(targetID, true) }
        .onChange(of: status != nil, initial: true) { _, present in
            if present { seenStatus = true }
        }
        .onDisappear { ejector.setWatching(targetID, false) }
        .confirmationDialog(
            "Terminate \(confirmTerminate?.displayName ?? "")?", isPresented: present($confirmTerminate), presenting: confirmTerminate
        ) { blocker in
            Button("Terminate", role: .destructive) {
                ejector.terminate(blocker)
                confirmKill = blocker
            }
        } message: { _ in
            Text("The process is asked to stop (SIGTERM). Unsaved work in it may be lost.")
        }
        .confirmationDialog(
            "Force \(confirmKill?.displayName ?? "") to stop?", isPresented: present($confirmKill), presenting: confirmKill
        ) { blocker in
            Button("Kill", role: .destructive) { ejector.terminate(blocker, kill: true) }
            Button("Wait", role: .cancel) {}
        } message: { _ in
            Text("If it hasn't exited, it can be stopped at once (SIGKILL). It gets no chance to save.")
        }
        .confirmationDialog("Force eject \(status?.target.name ?? "")?", isPresented: $confirmForce) {
            Button("Force Eject", role: .destructive) {
                Task { await ejector.retry(targetID, force: true) }
            }
        } message: {
            Text("Apps with files open on the drive may lose or damage them.")
        }
    }

    @ViewBuilder
    private func header(_ status: Ejector.Status) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(status.failure == nil ? "Who's using \(status.target.name)" : "\(status.target.name) couldn't be ejected")
                .font(.headline)
            if let failure = status.failure {
                Text(failure.message).foregroundStyle(.secondary)
            }
            if status.failure != nil, !status.stillMounted.isEmpty {
                Text("Still mounted: \(status.stillMounted.formatted(.list(type: .and)))")
                    .foregroundStyle(.secondary)
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
            HStack {
                // By type, so nothing on the drive is read.
                Image(nsImage: NSWorkspace.shared.icon(for: UTType(filenameExtension: "dmg") ?? .diskImage))
                    .resizable()
                    .frame(width: 32, height: 32)
                VStack(alignment: .leading) {
                    Text(image.fileName)
                    Text("Mounted from this drive").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Eject Image") {
                    Task { await ejector.ejectImage(image, from: targetID) }
                }
            }
        }
        ForEach(report.blockers) { blocker in
            BlockerRow(blocker: blocker) {
                ejector.quit(blocker)
            } terminate: {
                confirmTerminate = blocker
            }
        }
    }

    @ViewBuilder
    private func footer(_ status: Ejector.Status) -> some View {
        HStack {
            if status.phase != .idle { ProgressView().controlSize(.small) }
            Spacer()
            Button("Close") {
                ejector.dismiss(targetID)
                close()
            }
            if status.failure != nil {
                Button("Force Eject…") { confirmForce = true }
                    .disabled(status.phase != .idle)
            }
            Button(status.failure == nil ? "Eject" : "Retry") {
                Task { await ejector.retry(targetID) }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(status.phase != .idle)
        }
    }

    private func present<T>(_ binding: Binding<T?>) -> Binding<Bool> {
        Binding(get: { binding.wrappedValue != nil }, set: { if !$0 { binding.wrappedValue = nil } })
    }
}

private struct BlockerRow: View {
    let blocker: Blocker
    let quit: () -> Void
    let terminate: () -> Void
    @State private var expanded = false

    var body: some View {
        HStack(alignment: .top) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(blocker.isAppProcess ? blocker.displayName : blocker.processName)
                Text(summary).font(.caption).foregroundStyle(.secondary)
                if let first = blocker.uses.first {
                    Text(first.path)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(first.path)
                }
                if blocker.uses.count > 1 {
                    DisclosureGroup("\(blocker.uses.count - 1) more", isExpanded: $expanded) {
                        ForEach(Array(blocker.uses.dropFirst().enumerated()), id: \.offset) { _, use in
                            Text("\(use.reason.rawValue): \(use.path)")
                                .font(.caption.monospaced())
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .font(.caption)
                }
            }
            Spacer()
            if blocker.isAppProcess {
                Button("Quit", action: quit)
            } else {
                Button("Terminate…", action: terminate)
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
