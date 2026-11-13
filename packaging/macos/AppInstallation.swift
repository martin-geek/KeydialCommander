import Foundation

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

    func install(from source: URL) throws {
        guard isCommander(source) else {
            throw SetupError.message("Open Setup from the disk image so it can find Keydial Commander.")
        }
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        if files.fileExists(atPath: target.path) && !installed {
            throw SetupError.message("A different item already uses that name in \(directory.path).")
        }
        let staging = directory.appendingPathComponent(".keydial-\(UUID().uuidString)", isDirectory: true)
        defer { try? files.removeItem(at: staging) }
        try files.copyItem(at: source, to: staging)
        if installed {
            _ = try files.replaceItemAt(target, withItemAt: staging, backupItemName: nil,
                                        options: .usingNewMetadataOnly)
        } else {
            try files.moveItem(at: staging, to: target)
        }
    }

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
        return Bundle(url: url)?.bundleIdentifier == Self.identifier
    }
}

enum SetupError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let message): return message }
    }
}
