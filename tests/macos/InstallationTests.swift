import Foundation

@main
struct InstallationTests {
    static func main() throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("Keydial-setup-test-\(UUID().uuidString)")
        defer { try? files.removeItem(at: root) }
        let installation = AppInstallation(directory: root)
        let source = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try installation.install(from: source)
        precondition(installation.installed)
        try installation.install(from: source)
        precondition(installation.installed)
        let trashed = try installation.uninstall()
        precondition(!installation.installed)
        if let trashed { try files.removeItem(at: trashed) }
        print("Installed, reinstalled, and uninstalled the app in an isolated directory.")
    }
}
