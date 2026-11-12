import AppKit
import CoreGraphics
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = CommanderModel()
    func applicationWillTerminate(_ notification: Notification) { model.stop() }
}

@main
struct CommanderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup("Keydial Commander") {
            CommanderWindow(model: delegate.model)
                .frame(minWidth: 820, minHeight: 565)
                .onAppear { delegate.model.start() }
        }
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}

struct CommanderWindow: View {
    @ObservedObject var model: CommanderModel
    @AppStorage("dialOrientation") private var orientation: Orientation = .upperLeft

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Label("Keydial Commander", systemImage: "rectangle.grid.3x2")
                    .font(.headline)
                Spacer()
                Picker("Profile", selection: Binding(
                    get: { model.activeProfile ?? "" }, set: model.activate)) {
                    if model.activeProfile == nil { Text("Loading…").tag("") }
                    ForEach(model.profiles) { profile in Text(profile.name).tag(profile.name) }
                }
                .fixedSize()
                .disabled(model.busy || model.activeProfile == nil)
                profileMenu
            }
            .padding(14)
            Divider()
            HSplitView {
                VStack(spacing: 12) {
                    HStack {
                        Picker("Dial position", selection: $orientation) {
                            ForEach(Orientation.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .fixedSize()
                        Spacer()
                        Toggle(isOn: $model.identify) {
                            Label(model.identify ? "Press a control…" : "Identify", systemImage: "scope")
                        }
                        .toggleStyle(.button)
                        .disabled(model.status?.device.ready != true)
                    }
                    DeviceBoard(model: model, orientation: orientation)
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
                if model.status?.output.available == false || model.status?.device.state == "input_permission_required" {
                    Button("Permissions…", action: openPermissions)
                }
                if model.status == nil && !model.starting {
                    Button("Restart Service", action: model.start)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
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
        case "capture_failed": return "Cannot access the keypad. Quit other remapping apps and reconnect it."
        default: return "Keydial Mini not connected"
        }
    }

    private var profileMenu: some View {
        Menu {
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
                    let panel = NSSavePanel()
                    panel.nameFieldStringValue = "\(profile).yaml"
                    if panel.runModal() == .OK, let url = panel.url { model.export(profile, to: url) }
                }
            }
            Button("Import Profile…") {
                let panel = NSOpenPanel()
                if panel.runModal() == .OK, let url = panel.url,
                   let name = prompt("Import Profile", initial: url.deletingPathExtension().lastPathComponent) {
                    model.importProfile(name, from: url)
                }
            }
        } label: { Label("Manage Profiles", systemImage: "ellipsis.circle") }
        .fixedSize().disabled(model.busy || model.activeProfile == nil)
    }

    private func prompt(_ title: String, initial: String = "") -> String? {
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

    private func openPermissions() {
        let accessibility = model.status?.output.available == false
        if accessibility {
            _ = CGRequestPostEventAccess()
        } else {
            _ = CGRequestListenEventAccess()
        }
        let pane = accessibility ? "Privacy_Accessibility" : "Privacy_ListenEvent"
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}

private struct DeviceBoard: View {
    @ObservedObject var model: CommanderModel
    let orientation: Orientation

    var body: some View {
        GeometryReader { proxy in
            let size = orientation.size
            let unit = max(1, min(proxy.size.width / size.width, proxy.size.height / size.height))
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 19)
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
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
        let selected = model.selection == control.id
        let highlighted = model.highlighted?.split(separator: "+").contains(Substring(control.id)) == true
        let corner: CGFloat = control.dialCenter ? min(width, height) / 2 : 9
        return Button {
            model.selection = control.id
            model.identify = false
        } label: {
            VStack(spacing: 3) {
                Text(control.label)
                    .font(.system(size: control.label.count == 1 && control.id.hasPrefix("DIAL") ? 18 : 13,
                                  weight: .semibold, design: .rounded))
                if let label = model.bindings[control.id]?.title, !label.isEmpty {
                    Text(label).font(.system(size: 10)).lineLimit(1).padding(.horizontal, 3)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: width, height: height)
            .background(highlighted ? Color.green.opacity(0.38)
                        : selected ? Color.accentColor.opacity(0.24)
                        : Color(nsColor: .controlBackgroundColor),
                        in: RoundedRectangle(cornerRadius: corner))
            .overlay(RoundedRectangle(cornerRadius: corner)
                .strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.24),
                              lineWidth: selected ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: corner))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Control.name(control.id))
        .accessibilityValue(model.bindings[control.id]?.title ?? "Unassigned")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(Control.name(control.id))
    }
}
