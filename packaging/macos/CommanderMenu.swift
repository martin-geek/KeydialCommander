import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct RotateButton: View {
    @ObservedObject var preferences: Preferences

    var body: some View {
        Button(action: preferences.rotate) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 23, height: 23)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .accessibilityLabel("Rotate keypad clockwise")
        .accessibilityValue("Dial \(preferences.orientation.rawValue.lowercased())")
        .help("Rotate keypad 90° clockwise")
    }
}

struct DeviceIndicators: View {
    @ObservedObject var model: CommanderModel

    private var bluetooth: Bool { model.status?.device.transport == "bluetooth" }
    private var usb: Bool { model.status?.device.transport == "usb" }
    private var charging: Bool { model.status?.device.charging == true }

    var body: some View {
        HStack(spacing: 9) {
            Group {
                if usb {
                    Image(systemName: "cable.connector")
                } else {
                    BluetoothGlyph().stroke(lineWidth: 1.6).frame(width: 10, height: 14)
                }
            }
            .foregroundStyle(bluetooth ? Color.blue : Color.secondary)
            .accessibilityLabel(bluetooth ? "Bluetooth connected" : usb ? "USB connected" : "Keypad disconnected")
            .help(bluetooth ? "Connected via Bluetooth" : usb ? "Connected via USB" : "Keypad disconnected")
            if bluetooth || usb {
                HStack(spacing: 4) {
                    Image(systemName: batterySymbol)
                    if let battery = model.battery {
                        Text("\(battery)%").monospacedDigit()
                    } else {
                        Text("—").foregroundStyle(.secondary)
                    }
                    if charging { Image(systemName: "bolt.fill").foregroundStyle(.yellow) }
                }
                .font(.caption)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(model.battery.map { "Battery \($0) percent" } ?? "Battery level unavailable")
                .accessibilityValue(charging ? "Charging over USB" : "")
                .help(charging ? "Charging over USB" : model.battery.map { "Battery \($0)%" } ?? "Battery level unavailable")
                if model.canRequestBluetoothBattery {
                    Button { model.requestBluetoothBattery() } label: { Image(systemName: "info.circle") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Read Bluetooth battery")
                        .help("Read battery level from the Keydial’s Bluetooth service")
                }
            }
        }
        .fixedSize()
    }

    private var batterySymbol: String {
        guard let level = model.battery else { return "battery.0percent" }
        switch level {
        case 76...100: return "battery.100percent"
        case 51...75: return "battery.75percent"
        case 26...50: return "battery.50percent"
        case 1...25: return "battery.25percent"
        default: return "battery.0percent"
        }
    }
}

private struct BluetoothGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let x = rect.midX
        path.move(to: CGPoint(x: x, y: 0))
        path.addLine(to: CGPoint(x: x, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.height * 0.74))
        path.addLine(to: CGPoint(x: 0, y: rect.height * 0.19))
        path.move(to: CGPoint(x: x, y: 0))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.height * 0.25))
        path.addLine(to: CGPoint(x: 0, y: rect.height * 0.81))
        return path
    }
}

struct AppearancePicker: View {
    @ObservedObject var preferences: Preferences

    var body: some View {
        Picker("Appearance", selection: $preferences.appearance) {
            ForEach(Appearance.allCases) { Text($0.rawValue).tag($0) }
        }
    }
}

struct CommanderMenu: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var model: CommanderModel
    @ObservedObject var preferences: Preferences

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text("Keydial Commander").font(.headline)
                Spacer()
                DeviceIndicators(model: model)
            }
            Divider()
            menuButton("Open Commander", icon: "macwindow") { open("commander") }
            menuButton("Settings Preview", icon: "list.bullet.rectangle") { model.showPreview?() }
            menuButton("Rotate Keydial", icon: "arrow.clockwise") { preferences.rotate() }
            menuButton(model.identify ? "Cancel Identify" : "Identify a Control", icon: "scope") {
                model.identify.toggle()
                if model.identify { open("commander") }
            }
            .disabled(model.status?.device.ready != true)
            Divider()
            Picker("Profile", selection: Binding(
                get: { model.activeProfile ?? "" }, set: { model.activate($0) })) {
                if model.activeProfile == nil { Text("Unavailable").tag("") }
                ForEach(model.profiles) { Text($0.name).tag($0.name) }
            }.disabled(model.busy || model.activeProfile == nil)
            ProfileMenu(model: model) { open("app-profiles") }
            AppearancePicker(preferences: preferences)
            Divider()
            if model.status?.output.available == false || model.status?.device.state == "input_permission_required" {
                menuButton("Permissions…", icon: "lock.shield") { openKeydialPermissions(model) }
            }
            if model.status == nil && !model.starting {
                menuButton("Restart Service", icon: "arrow.clockwise") { model.start() }
            }
            menuButton("Quit Commander", icon: "power") { NSApp.terminate(nil) }
        }
        .padding(15)
        .frame(width: 285)
        .background(.regularMaterial)
        .preferredColorScheme(preferences.appearance.colorScheme)
    }

    private func open(_ id: String) {
        NSApp.activate(ignoringOtherApps: true)
        if id == "commander", let window = NSApp.windows.first(where: {
            $0.title == "Keydial Commander" && ($0.isVisible || $0.isMiniaturized)
        }) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: id)
        }
    }

    private func menuButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct AppProfilesWindow: View {
    @ObservedObject var model: CommanderModel
    @ObservedObject var preferences: Preferences

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Toggle("Switch profiles with the active Mac app", isOn: $preferences.automaticProfiles)
                .onChange(of: preferences.automaticProfiles) { model.reconsiderProfile() }
            Picker("All other apps", selection: $preferences.defaultProfile) {
                if preferences.defaultProfile == nil { Text("Current profile").tag(nil as String?) }
                ForEach(model.profiles) { Text($0.name).tag(Optional($0.name)) }
            }
            .onChange(of: preferences.defaultProfile) { model.reconsiderProfile() }
            Divider()
            if preferences.appProfiles.isEmpty {
                ContentUnavailableView("No app profiles yet", systemImage: "app.dashed",
                                       description: Text("Add a Mac app and choose the keypad profile to use when it’s active."))
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(preferences.appProfiles) { item in
                            HStack {
                                Image(systemName: "app").foregroundStyle(.secondary)
                                Text(item.name).lineLimit(1)
                                Spacer()
                                Picker("Profile for \(item.name)", selection: Binding(
                                    get: { item.profile }, set: { profile in
                                        var change = item
                                        change.profile = profile
                                        preferences.assign(change)
                                        model.reconsiderProfile()
                                    })) {
                                    ForEach(model.profiles) { Text($0.name).tag($0.name) }
                                }
                                .labelsHidden().frame(width: 154)
                                Button {
                                    preferences.remove(item)
                                    model.reconsiderProfile()
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Remove \(item.name) association")
                            }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            Button("Add App…", action: addApp)
                .disabled(model.activeProfile == nil)
        }
        .padding(20)
        .preferredColorScheme(preferences.appearance.colorScheme)
    }

    private func addApp() {
        guard let profile = model.activeProfile else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = FileManager.default.urls(for: .applicationDirectory, in: .localDomainMask).first
        panel.prompt = "Add App"
        guard panel.runModal() == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier else { return }
        guard id != Bundle.main.bundleIdentifier else {
            model.error = "Choose the Mac app that will use this profile."
            return
        }
        preferences.assign(AppProfile(bundleID: id, name: url.deletingPathExtension().lastPathComponent,
                                      profile: profile))
        model.reconsiderProfile()
    }
}

struct MappingPreview: View {
    @ObservedObject var model: CommanderModel
    @ObservedObject var preferences: Preferences

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text(model.activeProfile ?? "Current Profile").font(.title2.weight(.semibold))
                Spacer()
                Text("Dial \(preferences.orientation.rawValue.lowercased())").foregroundStyle(.secondary)
            }
            Divider()
            HStack(alignment: .top, spacing: 24) {
                DeviceBoard(model: model, orientation: preferences.orientation, readOnly: true)
                    .frame(minWidth: 260)
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(assigned, id: \.self) { id in
                            HStack(alignment: .firstTextBaseline) {
                                Text(Control.name(id))
                                    .foregroundStyle(.secondary)
                                Spacer(minLength: 12)
                                Text(model.bindings[id]?.detail ?? "")
                                    .multilineTextAlignment(.trailing)
                            }
                            Divider()
                        }
                        if assigned.isEmpty {
                            Text("No controls are assigned in this profile.").foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(width: 305)
            }
        }
        .padding(22)
        .frame(minWidth: 670, minHeight: 470)
        .background(.regularMaterial)
        .preferredColorScheme(preferences.appearance.colorScheme)
    }

    private var assigned: [String] {
        let controls = Control.all.map(\.id)
        return controls.filter { model.bindings[$0] != nil } +
            model.bindings.keys.filter { !controls.contains($0) }.sorted()
    }
}

@MainActor
func exportProfile(_ profile: String, model: CommanderModel) {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.yaml]
    panel.nameFieldStringValue = "\(profile).yaml"
    if panel.runModal() == .OK, let url = panel.url { model.export(profile, to: url) }
}

@MainActor
func importProfile(_ model: CommanderModel) {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.yaml]
    if panel.runModal() == .OK, let url = panel.url,
       let name = prompt("Import Profile", initial: url.deletingPathExtension().lastPathComponent) {
        model.importProfile(name, from: url)
    }
}
