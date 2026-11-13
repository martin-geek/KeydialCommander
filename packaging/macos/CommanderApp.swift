import AppKit
import CoreGraphics
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let preferences = Preferences()
    lazy var model = CommanderModel(preferences: preferences)
    private var previewWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = preferences.appearance.native
        model.showPreview = { [weak self] in self?.presentPreview() }
        model.start()
    }

    func applicationWillTerminate(_ notification: Notification) { model.stop() }

    private func presentPreview() {
        let window: NSWindow
        if let previewWindow {
            window = previewWindow
        } else {
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 810, height: 560),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
            window.title = "Settings Preview"
            window.isReleasedWhenClosed = false
            window.contentMinSize = NSSize(width: 670, height: 470)
            window.contentViewController = NSHostingController(
                rootView: MappingPreview(model: model, preferences: preferences))
            window.center()
            previewWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

@main
struct CommanderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup("Keydial Commander", id: "commander") {
            CommanderWindow(model: delegate.model, preferences: delegate.preferences)
                .frame(minWidth: 820, minHeight: 565)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Keydial") {
                Button("Settings Preview") { delegate.model.showPreview?() }
                Button("Rotate Keydial") { delegate.preferences.rotate() }
                AppearancePicker(preferences: delegate.preferences)
            }
        }
        MenuBarExtra {
            CommanderMenu(model: delegate.model, preferences: delegate.preferences)
        } label: {
            Image(nsImage: KeypadMenuIcon.image)
                .accessibilityLabel("Keydial Commander")
        }
        .menuBarExtraStyle(.window)
        Window("App Profiles", id: "app-profiles") {
            AppProfilesWindow(model: delegate.model, preferences: delegate.preferences)
                .frame(width: 485, height: 385)
        }
        .windowResizability(.contentSize)
    }
}

struct CommanderWindow: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var model: CommanderModel
    @ObservedObject var preferences: Preferences

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Label("Keydial Commander", systemImage: "rectangle.grid.3x2")
                    .font(.headline)
                Spacer()
                Picker("Profile", selection: Binding(
                    get: { model.activeProfile ?? "" }, set: { model.activate($0) })) {
                    if model.activeProfile == nil { Text("Loading…").tag("") }
                    ForEach(model.profiles) { profile in Text(profile.name).tag(profile.name) }
                }
                .fixedSize()
                .disabled(model.busy || model.activeProfile == nil)
                ProfileMenu(model: model) { openWindow(id: "app-profiles") }
            }
            .padding(14)
            Divider()
            HSplitView {
                VStack(spacing: 12) {
                    HStack {
                        RotateButton(preferences: preferences)
                        Text("Dial \(preferences.orientation.rawValue.lowercased())")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Toggle(isOn: $model.identify) {
                            Label(model.identify ? "Press a control…" : "Identify", systemImage: "scope")
                        }
                        .toggleStyle(.button)
                        .disabled(model.status?.device.ready != true)
                    }
                    DeviceBoard(model: model, orientation: preferences.orientation)
                }
                .padding(16)
                .frame(minWidth: 450, maxWidth: .infinity, maxHeight: .infinity)
                .background(.quaternary.opacity(0.18))
                if let profile = model.activeProfile {
                    BindingEditor(model: model, profile: profile, control: model.selection,
                                  saved: model.bindings[model.selection])
                        .id("\(profile):\(model.selection)")
                        .frame(minWidth: 300, idealWidth: 330, maxWidth: 400)
                } else {
                    Text("Waiting for Commander…")
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 300, idealWidth: 330, maxWidth: 400, maxHeight: .infinity)
                }
            }
            Divider()
            HStack(spacing: 10) {
                Circle().fill(model.status?.device.ready == true ? Color.green : Color.secondary)
                    .frame(width: 8, height: 8)
                Text(statusText).font(.callout)
                Spacer()
                DeviceIndicators(model: model)
                if model.status?.output.available == false || model.status?.device.state == "input_permission_required" {
                    Button("Permissions…") { model.showPermissionSetup = true }
                }
                if model.status == nil && !model.starting {
                    Button("Restart Service", action: model.start)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
        }
        .preferredColorScheme(preferences.appearance.colorScheme)
        .sheet(isPresented: $model.showPermissionSetup) {
            PermissionSetupView()
        }
        .alert("Keydial Commander", isPresented: Binding(
            get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }

    private var statusText: String {
        if model.starting { return "Starting the remapping service…" }
        guard let status = model.status else { return "Remapping service unavailable" }
        if !status.output.available { return "Accessibility permission required for shortcut output" }
        switch status.device.state {
        case "ready": return "Keydial Mini connected"
        case "input_permission_required": return "Input Monitoring permission required for the Keydial Mini"
        case "release_controls": return "Release the keypad controls to resume"
        case "recovering": return "Recovering keypad input…"
        case "missing_input": return "Waiting for all keypad controls"
        case "device_busy": return "Keypad in use by another app. Quit it and reconnect the keypad."
        case "capture_failed": return "Commander couldn’t read keypad input. Reconnect the keypad to retry."
        default: return "Keydial Mini not connected"
        }
    }

}

struct ProfileMenu: View {
    @ObservedObject var model: CommanderModel
    var openAppProfiles: () -> Void

    var body: some View {
        Menu {
            Button("App Profiles…", action: openAppProfiles)
            Divider()
            Button("New Profile…") {
                if let name = prompt("New Profile") { model.create(name, clone: false) }
            }
            if let profile = model.activeProfile {
                Button("Duplicate Profile…") {
                    if let name = prompt("Duplicate Profile") { model.create(name, clone: true) }
                }
                Button("Rename Profile…") {
                    if let name = prompt("Rename Profile", initial: profile) { model.rename(profile, to: name) }
                }
                Button("Delete Profile…", role: .destructive) {
                    let alert = NSAlert()
                    alert.messageText = "Delete the profile “\(profile)”?"
                    alert.informativeText = "The bindings saved in this profile will be removed."
                    alert.addButton(withTitle: "Delete")
                    alert.addButton(withTitle: "Cancel")
                    if alert.runModal() == .alertFirstButtonReturn { model.delete(profile) }
                }
                .disabled(model.profiles.count < 2)
                Divider()
                Button("Export Profile…") {
                    exportProfile(profile, model: model)
                }
            }
            Button("Import Profile…") {
                importProfile(model)
            }
        } label: { Label("Manage Profiles", systemImage: "ellipsis.circle") }
        .fixedSize().disabled(model.busy || model.activeProfile == nil)
    }

}

@MainActor
func prompt(_ title: String, initial: String = "") -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "Enter a profile name."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = initial
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }


private struct PermissionSetupView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Set Up Keydial Permissions").font(.title2.bold())
            Text("Allow Commander to read the keypad and send the shortcuts you assign.")
            permission("Shortcut Output", explanation: "Enable Keydial Commander under Device Control and Data Access (Accessibility on older macOS versions).",
                       pane: "Privacy_Accessibility", request: CGRequestPostEventAccess)
            permission("Input Monitoring", explanation: "Enable Keydial Commander under Input Monitoring so it can read the buttons and dial.",
                       pane: "Privacy_ListenEvent", request: CGRequestListenEventAccess)
            Text("If an enabled entry still blocks access, remove it and add Keydial Commander from Applications. Then quit and reopen Commander.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .frame(width: 450)
        .padding(24)
        .fixedSize(horizontal: true, vertical: false)
    }

    private func permission(_ title: String, explanation: String, pane: String,
                            request: @escaping () -> Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(explanation).font(.callout)
            Button(title + " Settings…") {
                _ = request()
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }
}

struct DeviceBoard: View {
    @ObservedObject var model: CommanderModel
    let orientation: Orientation
    var readOnly = false
    private static let artwork = Bundle.main.url(forResource: "Keydial", withExtension: "heic")
        .flatMap { NSImage(contentsOf: $0) }

    var body: some View {
        GeometryReader { proxy in
            let size = orientation.size
            let unit = max(1, min(proxy.size.width / size.width, proxy.size.height / size.height))
            ZStack(alignment: .topLeading) {
                let natural = Orientation.upperLeft.size
                if let image = Self.artwork {
                    Image(nsImage: image)
                        .resizable()
                        .frame(width: natural.width * unit, height: natural.height * unit)
                        .rotationEffect(.degrees(orientation.degrees))
                        .position(x: size.width * unit / 2, y: size.height * unit / 2)
                        .shadow(color: .black.opacity(0.24), radius: 11, y: 5)
                        .accessibilityHidden(true)
                }
                ForEach(Control.all) { control in
                    let rect = orientation.place(control.frame)
                    tile(control, width: rect.width * unit, height: rect.height * unit)
                        .position(x: rect.midX * unit, y: rect.midY * unit)
                }
            }
            .frame(width: size.width * unit, height: size.height * unit)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func tile(_ control: Control, width: CGFloat, height: CGFloat) -> some View {
        let action = model.bindings[control.id]
        let selected = !readOnly && model.selection == control.id
        let highlighted = model.highlighted?.split(separator: "+").contains(Substring(control.id)) == true
        let corner: CGFloat = control.dialCenter ? min(width, height) / 2 : 9
        let title = action?.title ?? ""
        let face = VStack(spacing: 3) {
            Text(title.isEmpty ? control.label : title)
                .font(.system(size: title.isEmpty && control.id.hasPrefix("DIAL") ? 15 : 12,
                              weight: .semibold, design: .rounded))
                .lineLimit(1).minimumScaleFactor(0.6)
                .padding(.horizontal, 4)
            if !title.isEmpty && !control.dialCenter {
                Text(control.label).font(.system(size: 9, weight: .medium)).opacity(0.68)
            }
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.85), radius: 2, y: 1)
        .frame(width: width, height: height)
        .background(highlighted ? Color.green.opacity(0.46)
                    : selected ? Color.cyan.opacity(0.22)
                    : control.id != "DIAL_CLICK" && control.id.hasPrefix("DIAL") ? Color.black.opacity(0.46)
                    : Color.clear,
                    in: RoundedRectangle(cornerRadius: corner))
        .overlay(RoundedRectangle(cornerRadius: corner)
            .strokeBorder(selected ? Color.cyan : Color.clear, lineWidth: 2))
        .contentShape(RoundedRectangle(cornerRadius: corner))
        let name = Control.name(control.id)
        let detail = action?.detail ?? "Unassigned"
        return Group {
            if readOnly {
                face
            } else {
                Button {
                    model.selection = control.id
                    model.identify = false
                } label: { face }
                .buttonStyle(.plain)
            }
        }
        .accessibilityLabel(name)
        .accessibilityValue(detail)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help("\(name) · \(detail)")
    }
}
