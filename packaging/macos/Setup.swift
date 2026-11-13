import AppKit
import SwiftUI

@main
struct KeydialSetup: App {
    var body: some Scene {
        WindowGroup("Keydial Commander Setup") {
            SetupView()
                .frame(width: 490, height: 265)
        }
        .windowResizability(.contentSize)
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}

private final class SetupState: ObservableObject {
    @Published var installedVersion: String?
    @Published var legacyInstalled = false
    @Published var confirmRemoval = false
    @Published var message = ""
    @Published var showResult = false
    @Published var resultTitle = ""
}

private struct SetupView: View {
    @StateObject private var state = SetupState()

    private let installation = AppInstallation.standard
    private let legacy = AppInstallation.legacy

    private var installed: Bool { state.installedVersion != nil }
    private var source: URL {
        Bundle.main.bundleURL.deletingLastPathComponent()
            .appendingPathComponent(AppInstallation.name, isDirectory: true)
    }
    private var installerVersion: String? { AppInstallation.version(at: source) }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Label("Keydial Commander", systemImage: "rectangle.grid.3x2")
                .font(.title2.weight(.semibold))
            Text("Install in Applications or move the installed app to the Trash.")
                .foregroundStyle(.secondary)
            Text(state.installedVersion.map { "Installed in /Applications · Version \($0)" }
                 ?? "Install location: /Applications")
                .font(.callout)
            if let installerVersion {
                Text("Installer version \(installerVersion)").font(.callout).foregroundStyle(.secondary)
            }
            if state.legacyInstalled {
                Text("An earlier copy is in your home Applications folder.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            HStack {
                Button("Uninstall…", role: .destructive) { state.confirmRemoval = true }
                    .disabled(!installed && !state.legacyInstalled)
                Spacer()
                if installed {
                    Button("Open App") { open() }
                }
                Button(installed ? "Reinstall" : "Install") { apply(install) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .onAppear(perform: refresh)
        .alert("Move Keydial Commander to the Trash?", isPresented: $state.confirmRemoval) {
            Button("Move to Trash", role: .destructive) { apply(uninstall) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(installed && state.legacyInstalled
                ? "Both installed copies will be moved to the Trash. Your saved profiles and settings will be kept."
                : "Your saved profiles and settings will be kept.")
        }
        .alert(state.resultTitle, isPresented: $state.showResult) {
            Button("OK", role: .cancel) {}
        } message: { Text(state.message) }
    }

    private func refresh() {
        state.installedVersion = installation.installedVersion
        state.legacyInstalled = legacy.installed
    }

    private func apply(_ action: () throws -> Void) {
        do { try action() }
        catch { showResult("Setup couldn’t complete the operation", error.localizedDescription) }
        refresh()
    }

    private func requireClosed() throws {
        if !NSRunningApplication.runningApplications(withBundleIdentifier: AppInstallation.identifier).isEmpty {
            throw SetupError.message("Quit Keydial Commander, then try again.")
        }
    }

    private func install() throws {
        try requireClosed()
        let updating = installation.installed
        let version = try installation.install(from: source)
        showResult(updating ? "Reinstall complete" : "Installation complete",
                   "Keydial Commander \(version) is installed in /Applications.")
    }

    private func uninstall() throws {
        try requireClosed()
        if installation.installed { try installation.uninstall() }
        if legacy.installed { try legacy.uninstall() }
        showResult("Uninstall complete", "Keydial Commander was moved to the Trash.")
    }

    private func showResult(_ title: String, _ message: String) {
        state.resultTitle = title
        state.message = message
        state.showResult = true
    }

    private func open() {
        NSWorkspace.shared.openApplication(at: installation.target, configuration: .init()) { _, error in
            if let error {
                DispatchQueue.main.async { showResult("Couldn’t open Commander", error.localizedDescription) }
            }
        }
    }
}
