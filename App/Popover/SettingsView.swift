import AppKit
import FreesideKit
import ServiceManagement
import SwiftUI

/// Every §6.6 setting, inline in the popover, as in flatline.
struct SettingsView: View {
    @Bindable var preferences: Preferences
    let volumes: VolumeStore
    let notifier: Notifier
    let updater: Updater
    let copyDiagnostics: () -> Void
    @Environment(\.accent) private var accent
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var copied = false
    /// The fixed amount, kept while a percentage is chosen.
    @State private var gigabytes = 50
    @State private var autoCheck = false
    @State private var autoDownload = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Section(title: "MENU BAR") {
                Row("style") {
                    Picker("style", selection: $preferences.menuBarStyle) {
                        ForEach(MenuBarStyle.allCases) { Text(Self.shortLabel($0)).tag($0) }
                    }
                }
                Row("volume") {
                    Picker("volume for space", selection: $preferences.pinnedVolumeID) {
                        Text(automaticLabel).tag(String?.none)
                        ForEach(volumes.volumes) { Text($0.name).tag(String?.some($0.id)) }
                        if let id = preferences.pinnedVolumeID, !volumes.volumes.contains(where: { $0.id == id }) {
                            Text("not mounted").tag(String?.some(id))
                        }
                    }
                    .pickerStyle(.menu)
                }
                Toggle("activity during transfers", isOn: $preferences.activityDuringTransfers)
                Toggle("activity trace", isOn: $preferences.activityTrace)
                Toggle("hide with no external drives", isOn: $preferences.hideWhenNoExternal)
            }

            Section(title: "VOLUMES") {
                HStack(alignment: .top) {
                    Text("show").frame(width: 48, alignment: .leading)
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                        GridRow {
                            Toggle(Self.label(.external), isOn: shown(.external))
                            Toggle(Self.label(.diskImage), isOn: shown(.diskImage))
                        }
                        GridRow {
                            Toggle(Self.label(.internal), isOn: shown(.internal))
                            Toggle(Self.label(.network), isOn: shown(.network))
                        }
                    }
                    .toggleStyle(.checkbox)
                }
                Row("units") {
                    Picker("units", selection: $preferences.units) {
                        Text("GB").tag(ByteUnits.decimal)
                        Text("GiB").tag(ByteUnits.binary)
                    }
                }
                Row("low") {
                    Picker("low space", selection: thresholdChoice) {
                        ForEach([5, 10, 20], id: \.self) { Text("\($0) %").tag(Optional($0)) }
                        Text("GB").tag(Int?.none)
                    }
                }
                if case .gigabytes = preferences.lowSpaceThreshold {
                    Row("") {
                        HStack(spacing: 6) {
                            Text("below")
                            TextField("gigabytes", value: $gigabytes, format: .number)
                                .frame(width: 60)
                                .multilineTextAlignment(.trailing)
                                .onSubmit { preferences.lowSpaceThreshold = .gigabytes(max(1, gigabytes)) }
                            Stepper("gigabytes", value: $gigabytes, in: 1...100_000, step: 10)
                                .labelsHidden()
                                .onChange(of: gigabytes) { _, value in preferences.lowSpaceThreshold = .gigabytes(max(1, value)) }
                            Text("GB")
                        }
                    }
                }
            }

            Section(title: "NOTIFICATIONS") {
                Toggle("low space", isOn: notification(\.notifyLowSpace))
                Toggle("transfer finished (1 GB or more)", isOn: notification(\.notifyTransferFinished))
                if notifier.isDenied, preferences.notifyLowSpace || preferences.notifyTransferFinished {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Notifications are turned off for freeside in System Settings.")
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("open notification settings") { NSWorkspace.shared.open(Notifier.settingsURL) }
                            .buttonStyle(.borderless)
                    }
                    .font(.caption2)
                }
            }

            Section(title: "GENERAL") {
                Row("accent") {
                    HStack(spacing: 8) {
                        ForEach(Accent.allCases) { option in
                            Button {
                                preferences.accent = option
                            } label: {
                                Circle()
                                    .fill(option.color)
                                    .frame(width: 16, height: 16)
                                    .overlay(Circle().strokeBorder(.primary, lineWidth: preferences.accent == option ? 2 : 0))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(option.label)
                            .accessibilityAddTraits(preferences.accent == option ? .isSelected : [])
                        }
                    }
                }
                Toggle("launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                if let loginError {
                    Text(loginError).font(.caption2).foregroundStyle(.red)
                }
                HStack {
                    Button("copy diagnostics") {
                        copyDiagnostics()
                        copied = true
                    }
                    .buttonStyle(.borderless)
                    if copied {
                        Text("copied, ready to paste into an issue")
                            .foregroundStyle(.secondary)
                            .task {
                                try? await Task.sleep(for: .seconds(3))
                                copied = false
                            }
                    }
                }
            }

            Section(title: "UPDATES") {
                Toggle("check automatically (daily)", isOn: $autoCheck)
                    .onChange(of: autoCheck) { _, on in updater.automaticallyChecks = on }
                Toggle("download automatically", isOn: $autoDownload)
                    .onChange(of: autoDownload) { _, on in updater.automaticallyDownloads = on }
                    .disabled(!autoCheck)
                Button("check now") { updater.checkForUpdates() }
                    .buttonStyle(.borderless)
            }
        }
        .font(.caption)
        .pickerStyle(.segmented)
        .toggleStyle(.switch)
        .controlSize(.small)
        .onAppear {
            autoCheck = updater.automaticallyChecks
            autoDownload = updater.automaticallyDownloads
            if case .gigabytes(let value) = preferences.lowSpaceThreshold { gigabytes = value }
            Task { await notifier.refreshAuthorization() }
        }
    }

    private var automaticLabel: String {
        Volume.defaultPinned(in: volumes.volumes).map { "automatic (\($0.name))" } ?? "automatic"
    }

    private func shown(_ kind: VolumeKind) -> Binding<Bool> {
        Binding {
            preferences.volumesShown.contains(kind)
        } set: { on in
            if on { preferences.volumesShown.insert(kind) } else { preferences.volumesShown.remove(kind) }
        }
    }

    /// A percentage, or nil for a fixed amount in GB.
    private var thresholdChoice: Binding<Int?> {
        Binding {
            if case .percent(let value) = preferences.lowSpaceThreshold { return value }
            return nil
        } set: { choice in
            preferences.lowSpaceThreshold = choice.map(LowSpaceThreshold.percent) ?? .gigabytes(max(1, gigabytes))
        }
    }

    /// Turning one on asks for permission the first time.
    private func notification(_ keyPath: ReferenceWritableKeyPath<Preferences, Bool>) -> Binding<Bool> {
        Binding {
            preferences[keyPath: keyPath]
        } set: { on in
            preferences[keyPath: keyPath] = on
            if on { Task { await notifier.requestAuthorization() } }
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
        }
        let actual = SMAppService.mainApp.status == .enabled
        if actual != launchAtLogin { launchAtLogin = actual }
    }

    private static func shortLabel(_ style: MenuBarStyle) -> String {
        switch style {
        case .icon: "icon"
        case .space: "space"
        case .activity: "activity"
        case .spaceActivity: "both"
        }
    }

    private static func label(_ kind: VolumeKind) -> String {
        switch kind {
        case .external: "external"
        case .diskImage: "disk images"
        case .network: "network"
        case .internal: "internal"
        }
    }
}

private struct Section<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    @Environment(\.accent) private var accent

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .tracking(1.5)
                .foregroundStyle(accent)
            content
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.quinary, in: .rect(cornerRadius: 10))
    }
}

private struct Row<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack {
            Text(label).frame(width: 48, alignment: .leading)
            content.labelsHidden()
        }
    }
}
