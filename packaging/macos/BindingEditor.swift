import AppKit
import SwiftUI

private final class BindingDraft: ObservableObject {
    @Published var action = Action()
}

struct BindingEditor: View {
    @ObservedObject var model: CommanderModel
    let profile: String
    let control: String
    let saved: Action?
    @StateObject private var editor = BindingDraft()
    private var draft: Action {
        get { editor.action }
        nonmutating set { editor.action = newValue }
    }

    private let types = [("keystroke", "Keyboard shortcut"), ("macro", "Macro"),
                         ("command", "App, URL, or command"), ("profile_switch", "Switch profile"),
                         ("settings_preview", "Show Settings Preview")]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(Control.name(control)).font(.title2.weight(.semibold))
            Picker("Action", selection: Binding(get: { draft.type }, set: setType)) {
                ForEach(types, id: \.0) { type in Text(type.1).tag(type.0) }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch draft.type {
                    case "keystroke":
                        KeyEditor(keys: Binding(get: { draft.keys ?? [] }, set: { draft.keys = $0 }),
                                  keyList: model.keyList)
                        Toggle("Hold while pressed", isOn: Binding(
                            get: { draft.sticky ?? false }, set: { draft.sticky = $0 }))
                            .disabled(control == "DIAL_CW" || control == "DIAL_CCW")
                    case "macro": macroEditor
                    case "command": commandEditor
                    case "profile_switch":
                        Picker("Switch to", selection: Binding(
                            get: { draft.profile ?? "next" }, set: { draft.profile = $0 })) {
                            Text("Next profile").tag("next")
                            ForEach(model.profiles) { Text($0.name).tag($0.name) }
                        }
                    case "settings_preview":
                        Text("Show the active profile’s key mappings in a separate window.")
                            .foregroundStyle(.secondary)
                    default: Text("Choose an action to edit this binding.")
                    }
                }
                .padding(.vertical, 2)
            }
            Spacer(minLength: 0)
            Divider()
            HStack {
                Button("Clear") { model.clear(control, profile: profile) }
                    .disabled(saved == nil)
                Spacer()
                Button("Test") {
                    if draft.type == "settings_preview" { model.showPreview?() }
                    else { model.test(draft) }
                }
                .disabled(!valid || (draft.type != "settings_preview" && model.status?.output.available != true))
                Button("Save") { model.save(draft, id: control, profile: profile) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!valid || draft == saved)
            }
            .disabled(model.busy)
        }
        .padding(16)
        .onAppear(perform: load)
        .onChange(of: saved) { load() }
    }

    private func load() {
        draft = saved ?? Action()
        if draft.type == "keyboard" { draft.type = "keystroke" }
    }

    private func setType(_ type: String) {
        switch type {
        case "macro": draft = Action(type: type, keys: nil, steps: [.init(keys: [])])
        case "command": draft = Action(type: type, keys: nil, argv: ["/usr/bin/open", "-a", ""])
        case "profile_switch": draft = Action(type: type, keys: nil, profile: "next")
        case "settings_preview": draft = Action(type: type, keys: nil)
        default: draft = Action()
        }
    }

    private var valid: Bool {
        switch draft.type {
        case "keystroke": return !(draft.keys ?? []).isEmpty
        case "macro":
            guard let steps = draft.steps, !steps.isEmpty else { return false }
            return steps.allSatisfy { step in
                if let delay = step.delay_ms { return (0...10_000).contains(delay) }
                return !(step.keys ?? []).isEmpty
            } && steps.reduce(0, { $0 + ($1.delay_ms ?? 0) }) <= 10_000
        case "command":
            guard let argv = draft.argv, let program = argv.first, !program.isEmpty else { return false }
            return program != "/usr/bin/open" || (argv.count > 1 && !(argv.last ?? "").isEmpty)
        case "profile_switch": return draft.profile != nil
        case "settings_preview": return true
        default: return false
        }
    }

    private var macroEditor: some View {
        let steps = draft.steps ?? []
        return VStack(alignment: .leading, spacing: 12) {
            ForEach(steps.indices, id: \.self) { index in
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text(steps[index].delay_ms == nil ? "Shortcut" : "Delay").font(.subheadline.weight(.medium))
                        Spacer()
                        Button(role: .destructive) { draft.steps?.remove(at: index) } label: {
                            Image(systemName: "minus.circle")
                        }.buttonStyle(.borderless).accessibilityLabel("Remove macro step")
                    }
                    if steps[index].delay_ms != nil {
                        TextField("Milliseconds", value: Binding(
                            get: { draft.steps?[safe: index]?.delay_ms ?? 0 },
                            set: { if draft.steps?.indices.contains(index) == true { draft.steps?[index].delay_ms = $0 } }),
                                  format: .number)
                    } else {
                        KeyEditor(keys: Binding(
                            get: { draft.steps?[safe: index]?.keys ?? [] },
                            set: { if draft.steps?.indices.contains(index) == true { draft.steps?[index].keys = $0 } }),
                                  keyList: model.keyList)
                    }
                }
                .padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }
            HStack {
                Button("Add Shortcut") { draft.steps?.append(.init(keys: [])) }
                Button("Add Delay") { draft.steps?.append(.init(delay_ms: 100)) }
            }.disabled(steps.count >= 32)
        }
    }

    private var commandEditor: some View {
        let argv = draft.argv ?? []
        return VStack(alignment: .leading, spacing: 8) {
            Menu("Use Template") {
                Button("Launch Application") { draft.argv = ["/usr/bin/open", "-a", ""] }
                Button("Open URL") { draft.argv = ["/usr/bin/open", ""] }
                Button("Run Command") { draft.argv = [""] }
            }
            ForEach(argv.indices, id: \.self) { index in
                HStack {
                    TextField(index == 0 ? "Program" : "Argument \(index)", text: Binding(
                        get: { draft.argv?[safe: index] ?? "" },
                        set: { if draft.argv?.indices.contains(index) == true { draft.argv?[index] = $0 } }))
                    Button(role: .destructive) { draft.argv?.remove(at: index) } label: {
                        Image(systemName: "minus.circle")
                    }.buttonStyle(.borderless).accessibilityLabel("Remove argument")
                }
            }
            Button("Add Argument") { draft.argv?.append("") }
            if argv.first == "/usr/bin/open" {
                Text(argv[safe: 1] == "-a" ? "Enter the application name in the last field."
                     : "Enter the URL in the last field.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

private final class ShortcutRecording: ObservableObject {
    @Published var monitor: Any?
    var modifiers: [String] = []
}

private struct KeyEditor: View {
    @Binding var keys: [String]
    let keyList: KeyList?
    @StateObject private var recorder = ShortcutRecording()
    private var monitor: Any? {
        get { recorder.monitor }
        nonmutating set { recorder.monitor = newValue }
    }
    private var modifiers: [String] {
        get { recorder.modifiers }
        nonmutating set { recorder.modifiers = newValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(keys.isEmpty ? "No shortcut assigned" : keys.map(shortKey).joined(separator: " + "))
                .font(.system(.body, design: .monospaced))
                .frame(maxWidth: .infinity, minHeight: 27, alignment: .leading)
                .padding(6).background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            HStack {
                Button(monitor == nil ? "Record Shortcut" : "Cancel Recording") {
                    if monitor == nil { record() } else { stopRecording() }
                }.disabled(keyList == nil)
                Menu("Add Key") {
                    ForEach((keyList?.groups.keys.sorted() ?? []), id: \.self) { group in
                        Menu(group) {
                            ForEach(keyList?.groups[group] ?? [], id: \.self) { key in
                                Button(key.replacingOccurrences(of: "KEY_", with: "")) {
                                    if !keys.contains(key) { keys.append(key) }
                                }
                            }
                        }
                    }
                }.fixedSize().disabled(monitor != nil || keyList == nil)
                if !keys.isEmpty && monitor == nil {
                    Button { keys = [] } label: { Image(systemName: "xmark.circle") }
                        .buttonStyle(.borderless).accessibilityLabel("Remove shortcut keys")
                }
            }
            if monitor != nil {
                Text("Press a shortcut or release a modifier to record it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onDisappear(perform: stopRecording)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            stopRecording()
        }
    }

    private func record() {
        guard let capture = keyList?.capture else { return }
        modifiers = []
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { event in
            guard let key = capture[String(event.keyCode)] else { return nil }
            if event.type == .flagsChanged, let flag = modifierFlag(key) {
                if event.modifierFlags.contains(flag) && !modifiers.contains(key) {
                    modifiers.append(key)
                } else if modifiers.contains(key) {
                    keys = modifiers
                    stopRecording()
                }
            } else if event.type == .keyDown && !event.isARepeat {
                let defaults: [(NSEvent.ModifierFlags, String, String)] = [
                    (.command, "KEY_LEFTMETA", "KEY_RIGHTMETA"),
                    (.option, "KEY_LEFTALT", "KEY_RIGHTALT"),
                    (.control, "KEY_LEFTCTRL", "KEY_RIGHTCTRL"),
                    (.shift, "KEY_LEFTSHIFT", "KEY_RIGHTSHIFT"),
                ]
                var held = modifiers
                for (flag, left, right) in defaults where event.modifierFlags.contains(flag) {
                    if !held.contains(left) && !held.contains(right) { held.append(left) }
                }
                keys = held + [key]
                stopRecording()
            }
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        modifiers = []
    }

    private func modifierFlag(_ key: String) -> NSEvent.ModifierFlags? {
        switch key {
        case "KEY_LEFTMETA", "KEY_RIGHTMETA": return .command
        case "KEY_LEFTALT", "KEY_RIGHTALT": return .option
        case "KEY_LEFTCTRL", "KEY_RIGHTCTRL": return .control
        case "KEY_LEFTSHIFT", "KEY_RIGHTSHIFT": return .shift
        default: return nil
        }
    }
}
