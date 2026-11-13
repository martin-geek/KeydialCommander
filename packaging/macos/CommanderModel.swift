import AppKit
import Combine
import Foundation

struct Action: Codable, Equatable {
    struct Step: Codable, Equatable {
        var keys: [String]?
        var delay_ms: Int?
    }
    var type = "keystroke"
    var keys: [String]? = []
    var sticky: Bool?
    var steps: [Step]?
    var argv: [String]?
    var profile: String?

    var title: String {
        switch type {
        case "keystroke", "keyboard": return (keys ?? []).map(shortKey).joined(separator: " ")
        case "macro": return "Macro"
        case "command":
            let arguments = argv ?? []
            return arguments.first == "/usr/bin/open"
                ? (arguments.last ?? "Open") : ((arguments.first ?? "") as NSString).lastPathComponent
        case "profile_switch": return profile == "next" ? "Next profile" : (profile ?? "Profile")
        case "settings_preview": return "Preview"
        default: return type
        }
    }

    var detail: String {
        switch type {
        case "macro":
            return (steps ?? []).map { step in
                if let delay = step.delay_ms { return "Wait \(delay) ms" }
                return (step.keys ?? []).map(shortKey).joined(separator: " + ")
            }.joined(separator: ", ")
        case "command":
            return (argv ?? []).joined(separator: " ")
        case "settings_preview":
            return "Show Settings Preview"
        default:
            return title
        }
    }
}

func shortKey(_ key: String) -> String {
    switch key {
    case "KEY_LEFTMETA", "KEY_RIGHTMETA": return "⌘"
    case "KEY_LEFTALT", "KEY_RIGHTALT": return "⌥"
    case "KEY_LEFTSHIFT", "KEY_RIGHTSHIFT": return "⇧"
    case "KEY_LEFTCTRL", "KEY_RIGHTCTRL": return "⌃"
    default: return key.replacingOccurrences(of: "KEY_", with: "")
    }
}

struct Status: Decodable {
    struct Device: Decodable {
        let connected: Bool
        let ready: Bool
        let state: String
        let transport: String?
        let product: String?
        let battery: Int?
        let charging: Bool?
        var canIdentify: Bool { ready || state == "monitoring" }
    }
    struct Output: Decodable { let available: Bool }
    let device: Device
    let output: Output
    let active_profile: String
}

struct KeyList: Decodable {
    let groups: [String: [String]]
    let capture: [String: String]
}

struct Profile: Decodable, Identifiable {
    let name: String
    var id: String { name }
}

private struct Bindings: Decodable { let bindings: [String: Action] }
private struct Event: Decodable {
    let type: String
    let action_id: String?
    let pressed: Bool?
}

enum ServiceError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let message): return message }
    }
}

@MainActor
final class CommanderModel: ObservableObject {
    @Published private(set) var status: Status?
    @Published private(set) var profiles: [Profile] = []
    @Published private(set) var bindings: [String: Action] = [:]
    @Published private(set) var keyList: KeyList?
    @Published private(set) var highlighted: String?
    @Published var selection = "BUTTON_1"
    @Published var identify = false
    @Published var error: String?
    @Published var showPermissionSetup = false
    @Published var confirmUSBRemapping = false
    @Published private(set) var starting = false
    @Published private(set) var busy = false
    @Published private(set) var bluetoothBattery: Int?

    let preferences: Preferences
    var showPreview: (() -> Void)?
    private let batteryReader = BatteryReader()
    private var activationObserver: AnyCancellable?
    private var externalApplication: String?
    private var pendingProfileCheck = false
    private var checkedLaunchPermissions = false
    private var usbTabletMode = false

    func enableUSBRemapping() {
        usbTabletMode = true
        stop()
        start()
    }

    private var process: Process?
    private var input: Pipe?
    private var port: Int?
    private var token = ""
    private var refreshTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var eventSocket: URLSessionWebSocketTask?
    private var loadedProfile: String?
    private var revision = 0
    private var pipeBuffer = Data()
    private var flashTask: Task<Void, Never>?
    private let session = URLSession(configuration: .ephemeral)

    var activeProfile: String? { status?.active_profile }
    var battery: Int? { status?.device.battery ?? bluetoothBattery }
    var canRequestBluetoothBattery: Bool {
        status?.device.transport == "bluetooth" && status?.device.product != nil && battery == nil
    }

    init(preferences: Preferences) {
        self.preferences = preferences
        batteryReader.onLevel = { [weak self] level in
            guard let self, self.bluetoothBattery != level else { return }
            self.bluetoothBattery = level
        }
        activationObserver = NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didActivateApplicationNotification)
            .sink { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                Task { @MainActor in self?.applicationActivated(app?.bundleIdentifier) }
            }
        applicationActivated(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
    }

    func requestBluetoothBattery() {
        guard canRequestBluetoothBattery else { return }
        batteryReader.update(product: status?.device.product, requestPermission: true)
    }

    private func applicationActivated(_ bundleID: String?) {
        guard let bundleID, bundleID != Bundle.main.bundleIdentifier,
              externalApplication != bundleID else { return }
        externalApplication = bundleID
        reconsiderProfile()
    }

    func reconsiderProfile() {
        if busy { pendingProfileCheck = true; return }
        guard let activeProfile, preferences.automaticProfiles else { return }
        let available = profiles.map(\.name)
        if !available.contains(preferences.defaultProfile ?? "") { preferences.defaultProfile = activeProfile }
        guard let target = preferences.profile(for: externalApplication, available: available),
              target != activeProfile else { return }
        activate(target, manually: false)
    }

    func start() {
        guard process == nil else { return }
        starting = true
        error = nil
        pipeBuffer = Data()
        token = UUID().uuidString + UUID().uuidString
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/keydial-engine/keydial-engine")
        process.environment = ProcessInfo.processInfo.environment.merging(
            ["KEYDIAL_NATIVE_TOKEN": token, "KEYDIAL_USB_TABLET_MODE": usbTabletMode ? "1" : "0"], uniquingKeysWith: { _, value in value })
        process.standardInput = input
        process.standardOutput = output
        process.terminationHandler = { [weak self] ended in
            DispatchQueue.main.async {
                guard let self, self.process === ended else { return }
                self.stopSession()
                self.error = "The remapping service stopped (exit \(ended.terminationStatus))."
            }
        }
        output.fileHandleForReading.readabilityHandler = { [weak self, weak process] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            DispatchQueue.main.async {
                guard let self, self.process === process, self.port == nil else { return }
                self.pipeBuffer.append(data)
                if let newline = self.pipeBuffer.firstIndex(of: 10) {
                    handle.readabilityHandler = nil
                    self.connect(Data(self.pipeBuffer[..<newline]))
                }
            }
        }
        do {
            try process.run()
            self.input = input
            self.process = process
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            starting = false
            self.error = error.localizedDescription
        }
    }

    private func connect(_ data: Data) {
        guard let reply = try? JSONDecoder().decode([String: Int].self, from: data),
              let port = reply["port"], (1...65535).contains(port) else {
            error = "The remapping service did not report an address."
            stop()
            return
        }
        self.port = port
        starting = false
        refreshTask = Task { [weak self] in
            guard let self else { return }
            do {
                self.keyList = try await self.read("/api/keys")
                try await self.reload()
                while !Task.isCancelled {
                    try await Task.sleep(nanoseconds: 750_000_000)
                    if !self.busy { try await self.reload() }
                }
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
        eventTask = Task { [weak self] in await self?.listen() }
    }

    func stop() {
        let process = process
        stopSession()
        if let process, process.isRunning {
            // EOF asks the helper to release any held output before exiting.
            process.waitUntilExit()
        }
    }

    private func stopSession() {
        try? input?.fileHandleForWriting.close()
        input = nil
        process = nil
        port = nil
        starting = false
        status = nil
        flashTask?.cancel()
        highlighted = nil
        batteryReader.update(product: nil)
        loadedProfile = nil
        revision += 1
        refreshTask?.cancel()
        eventTask?.cancel()
        eventSocket?.cancel(with: .goingAway, reason: nil)
        eventSocket = nil
    }

    private func request(_ path: String, method: String = "GET", body: Data? = nil,
                         websocket: Bool = false) throws -> URLRequest {
        guard let port, let url = URL(string: "\(websocket ? "ws" : "http")://127.0.0.1:\(port)\(path)") else {
            throw ServiceError.message("The remapping service is unavailable.")
        }
        var request = URLRequest(url: url, timeoutInterval: 6)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpMethod = method
        request.httpBody = body
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return request
    }

    private func send(_ path: String, method: String = "GET", body: Data? = nil) async throws -> Data {
        let (data, response) = try await session.data(for: request(path, method: method, body: body))
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            let details = try? JSONDecoder().decode([String: [String: String]].self, from: data)
            throw ServiceError.message(details?["error"]?["message"] ?? "Commander could not complete the request.")
        }
        return data
    }

    private func read<T: Decodable>(_ path: String) async throws -> T {
        try JSONDecoder().decode(T.self, from: await send(path))
    }

    private func reload(force: Bool = false) async throws {
        let revision = self.revision
        let firstStatus = status == nil
        let newStatus: Status = try await read("/api/status")
        guard revision == self.revision else { return }
        if newStatus.active_profile != loadedProfile || force {
            let name = newStatus.active_profile
            let profileBindings: Bindings = try await read("/api/profiles/\(segment(name))/bindings")
            let newProfiles: [Profile] = try await read("/api/profiles")
            guard revision == self.revision else { return }
            bindings = profileBindings.bindings
            profiles = newProfiles
            loadedProfile = name
        }
        status = newStatus
        batteryReader.update(product: newStatus.device.transport == "bluetooth" && newStatus.device.battery == nil
                             ? newStatus.device.product : nil)
        if firstStatus { reconsiderProfile() }
        if !checkedLaunchPermissions {
            checkedLaunchPermissions = true
            showPermissionSetup = !newStatus.output.available
                || newStatus.device.state == "input_permission_required"
        }
    }

    private func listen() async {
        while !Task.isCancelled {
            guard let request = try? request("/api/events", websocket: true) else { return }
            let socket = session.webSocketTask(with: request)
            eventSocket = socket
            socket.resume()
            do {
                while !Task.isCancelled {
                    let message = try await socket.receive()
                    guard case let .string(text) = message,
                          let event = try? JSONDecoder().decode(Event.self, from: Data(text.utf8))
                    else { continue }
                    if event.type == "settings_preview" { showPreview?() }
                    if event.type == "physical_press", let id = event.action_id {
                        highlighted = id
                        if identify { selection = id; identify = false }
                        flashTask?.cancel()
                        flashTask = Task {
                            try? await Task.sleep(nanoseconds: 360_000_000)
                            if !Task.isCancelled { highlighted = nil }
                        }
                    }
                }
            } catch {
                socket.cancel()
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    private func segment(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? text
    }

    private func perform(_ work: @escaping () async throws -> Void) {
        guard !busy, port != nil else { return }
        busy = true
        revision += 1
        Task {
            defer {
                busy = false
                if pendingProfileCheck {
                    pendingProfileCheck = false
                    reconsiderProfile()
                }
            }
            do { try await work() }
            catch { self.error = error.localizedDescription }
        }
    }

    func save(_ action: Action, id: String, profile: String) {
        perform {
            _ = try await self.send(self.bindingPath(id, profile), method: "PUT",
                                    body: JSONEncoder().encode(action))
            try await self.reload(force: true)
        }
    }

    func clear(_ id: String, profile: String) {
        perform {
            _ = try await self.send(self.bindingPath(id, profile), method: "DELETE")
            try await self.reload(force: true)
        }
    }

    private func bindingPath(_ id: String, _ profile: String) -> String {
        "/api/profiles/\(segment(profile))/bindings/\(segment(id))"
    }

    func test(_ action: Action) {
        perform {
            _ = try await self.send("/api/test-fire", method: "POST", body: JSONEncoder().encode(action))
        }
    }

    func activate(_ profile: String, manually: Bool = true) {
        changeProfile("/api/profiles/\(segment(profile))/activate", method: "POST") {
            if manually && !self.preferences.hasProfile(for: self.externalApplication) {
                self.preferences.defaultProfile = profile
            }
        }
    }

    func create(_ name: String, clone: Bool) {
        var values = ["name": name]
        if clone { values["clone_from"] = activeProfile }
        changeProfile("/api/profiles", method: "POST", values: values)
    }

    func rename(_ profile: String, to name: String) {
        changeProfile("/api/profiles/\(segment(profile))", method: "PUT", values: ["new_name": name]) {
            self.preferences.renameProfile(profile, to: name)
        }
    }

    func delete(_ profile: String) {
        changeProfile("/api/profiles/\(segment(profile))", method: "DELETE") {
            self.preferences.removeProfile(profile)
        }
    }

    func export(_ profile: String, to url: URL) {
        perform {
            let data = try await self.send("/api/profiles/\(self.segment(profile))/export")
            try data.write(to: url, options: .atomic)
        }
    }

    func importProfile(_ name: String, from url: URL) {
        do {
            let yaml = try String(contentsOf: url, encoding: .utf8)
            changeProfile("/api/profiles/import", method: "POST", values: ["name": name, "yaml": yaml])
        } catch { self.error = error.localizedDescription }
    }

    private func changeProfile(_ path: String, method: String, values: [String: String]? = nil,
                               afterChange: (() -> Void)? = nil) {
        perform {
            let body = try values.map { try JSONEncoder().encode($0) }
            _ = try await self.send(path, method: method, body: body)
            afterChange?()
            try await self.reload(force: true)
        }
    }
}
