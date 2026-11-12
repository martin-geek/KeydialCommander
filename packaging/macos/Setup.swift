import AppKit
import SwiftUI

@main
struct KeydialSetup: App {
    var body: some Scene {
        WindowGroup("Keydial Commander Setup") {
            SetupView()
                .frame(width: 455, height: 245)
        }
        .windowResizability(.contentSize)
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}

private final class SetupState: ObservableObject {
    @Published var installed = false
    @Published var confirmRemoval = false
    @Published var message = ""
    @Published var showError = false
}

private struct SetupView: View {
    @StateObject private var state = SetupState()

    private let installation = AppInstallation(
        directory: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true))

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Label("Keydial Commander", systemImage: "rectangle.grid.3x2")
                .font(.title2.weight(.semibold))
            Text("Install for your macOS account or move the installed app to the Trash.")
                .foregroundStyle(.secondary)
            Text(state.installed ? "Installed in ~/Applications" : "Install location: ~/Applications")
                .font(.callout)
            Spacer()
            HStack {
                Button("Uninstall…", role: .destructive) { state.confirmRemoval = true }
                    .disabled(!state.installed)
                Spacer()
                if state.installed {
                    Button("Open App") { open() }
                }
                Button(state.installed ? "Reinstall" : "Install") { apply(install) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .onAppear(perform: refresh)
        .alert("Move Keydial Commander to the Trash?", isPresented: $state.confirmRemoval) {
            Button("Move to Trash", role: .destructive) { apply(uninstall) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your saved profiles and settings will be kept.")
        }
        .alert("Keydial Commander Setup", isPresented: $state.showError) {
            Button("OK", role: .cancel) {}
        } message: { Text(state.message) }
    }

    private func refresh() { state.installed = installation.installed }

    private func apply(_ action: () throws -> Void) {
        do { try action() }
        catch { state.message = error.localizedDescription; state.showError = true }
        refresh()
    }

    private func requireClosed() throws {
        if !NSRunningApplication.runningApplications(withBundleIdentifier: AppInstallation.identifier).isEmpty {
            throw SetupError.message("Quit Keydial Commander, then try again.")
        }
    }

    private func install() throws {
        try requireClosed()
        let source = Bundle.main.bundleURL.deletingLastPathComponent()
            .appendingPathComponent(AppInstallation.name, isDirectory: true)
        try installation.install(from: source)
    }

    private func uninstall() throws {
        try requireClosed()
        try installation.uninstall()
    }

    private func open() {
        NSWorkspace.shared.openApplication(at: installation.target, configuration: .init()) { _, error in
            if let error {
                DispatchQueue.main.async { state.message = error.localizedDescription; state.showError = true }
            }
        }
    }
}
