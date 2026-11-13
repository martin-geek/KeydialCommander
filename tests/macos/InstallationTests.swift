import Foundation

@main
struct InstallationTests {
    static func main() throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("Keydial-setup-test-\(UUID().uuidString)")
        defer { try? files.removeItem(at: root) }
        let installation = AppInstallation(directory: root)
        let previous = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let source = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let oldVersion = try installation.install(from: previous)
        precondition(installation.installedVersion == oldVersion)

        let version = try installation.install(from: source)
        precondition(version != oldVersion && installation.installedVersion == version)
        let reinstalledVersion = try installation.install(from: source)
        precondition(reinstalledVersion == version)

        do {
            try installation.install(from: previous)
            preconditionFailure("An older installer replaced a newer app")
        } catch is SetupError {}

        let damaged = root.appendingPathComponent("Damaged.app")
        try files.copyItem(at: source, to: damaged)
        try files.removeItem(at: damaged.appendingPathComponent(AppInstallation.enginePath))
        do {
            try installation.install(from: damaged)
            preconditionFailure("Setup accepted an app without the engine")
        } catch is SetupError {}
        precondition(installation.installedVersion == version)
        precondition(files.isExecutableFile(atPath:
            installation.target.appendingPathComponent(AppInstallation.enginePath).path))
        let trashed = try installation.uninstall()
        precondition(!installation.installed)
        if let trashed { try files.removeItem(at: trashed) }
        print("Verified upgrade, reinstall, downgrade rejection, damaged-bundle rejection, and uninstall.")
    }
}
