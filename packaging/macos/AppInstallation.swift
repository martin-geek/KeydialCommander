import Foundation
import Security

struct AppInstallation {
    static let name = "Keydial Commander.app"
    static let identifier = "io.github.martin-geek.keydial-commander"

    static let standard = AppInstallation(directory: URL(fileURLWithPath: "/Applications", isDirectory: true))
    static let legacy = AppInstallation(directory: FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Applications", isDirectory: true))

    let directory: URL
    private let files = FileManager.default

    var target: URL { directory.appendingPathComponent(Self.name, isDirectory: true) }
    var installed: Bool { isCommander(target) }
    var installedVersion: String? { Self.version(at: target) }

    static func version(at url: URL) -> String? {
        let plist = url.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = (try? PropertyListSerialization.propertyList(from: data, format: nil))
                as? [String: Any],
              info["CFBundleIdentifier"] as? String == identifier else { return nil }
        return info["CFBundleShortVersionString"] as? String
    }

    @discardableResult
    func install(from source: URL) throws -> String {
        guard isCommander(source), let version = Self.version(at: source) else {
            throw SetupError.message("Open Setup from the disk image so it can find Keydial Commander.")
        }
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        if files.fileExists(atPath: target.path) && !installed {
            throw SetupError.message("A different item already uses that name in \(directory.path).")
        }
        if let current = installedVersion, current.compare(version, options: .numeric) == .orderedDescending {
            throw SetupError.message("Version \(current) is already installed. Use Setup for that version or a newer one.")
        }
        let staging = directory.appendingPathComponent(".keydial-\(UUID().uuidString)", isDirectory: true)
        defer { try? files.removeItem(at: staging) }
        try files.copyItem(at: source, to: staging)
        try verify(staging)
        if installed {
            _ = try files.replaceItemAt(target, withItemAt: staging, backupItemName: nil,
                                        options: .usingNewMetadataOnly)
        } else {
            try files.moveItem(at: staging, to: target)
        }
        guard installedVersion == version else {
            throw SetupError.message("Setup could not confirm version \(version) in \(directory.path).")
        }
        return version
    }

    private func verify(_ app: URL) throws {
        var code: SecStaticCode?
        let flags = SecCSFlags(rawValue: UInt32(kSecCSCheckAllArchitectures | kSecCSCheckNestedCode))
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess,
              let code, SecStaticCodeCheckValidity(code, flags, nil) == errSecSuccess,
              files.isExecutableFile(atPath: app.appendingPathComponent("Contents/MacOS/Commander").path),
              files.isExecutableFile(atPath: app.appendingPathComponent(Self.enginePath).path) else {
            throw SetupError.message("The app or its bundled service is incomplete or damaged. Download a fresh disk image.")
        }
    }

    static let enginePath = "Contents/Resources/keydial-engine/keydial-engine"

    @discardableResult
    func uninstall() throws -> URL? {
        guard installed else {
            throw SetupError.message("Keydial Commander was not found in \(directory.path).")
        }
        var trashed: NSURL?
        try files.trashItem(at: target, resultingItemURL: &trashed)
        return trashed as URL?
    }

    private func isCommander(_ url: URL) -> Bool {
        guard files.fileExists(atPath: url.path),
              (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false else {
            return false
        }
        return Self.version(at: url) != nil
    }
}

enum SetupError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let message): return message }
    }
}
