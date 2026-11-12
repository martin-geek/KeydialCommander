import AppKit
import SwiftUI

enum Appearance: String, CaseIterable, Identifiable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"

    var id: Self { self }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    var native: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

struct AppProfile: Codable, Equatable, Identifiable {
    let bundleID: String
    let name: String
    var profile: String
    var id: String { bundleID }
}

@MainActor
final class Preferences: ObservableObject {
    @Published var orientation: Orientation {
        didSet { defaults.set(orientation.rawValue, forKey: "dialOrientation") }
    }
    @Published var appearance: Appearance {
        didSet {
            defaults.set(appearance.rawValue, forKey: "commanderAppearance")
            NSApp.appearance = appearance.native
        }
    }
    @Published private(set) var appProfiles: [AppProfile] {
        didSet {
            defaults.set(try? JSONEncoder().encode(appProfiles), forKey: "commanderAppProfiles")
        }
    }
    @Published var automaticProfiles: Bool {
        didSet { defaults.set(automaticProfiles, forKey: "automaticProfiles") }
    }
    @Published var defaultProfile: String? {
        didSet { defaults.set(defaultProfile, forKey: "defaultProfile") }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        orientation = defaults.string(forKey: "dialOrientation").flatMap(Orientation.init(rawValue:)) ?? .upperLeft
        appearance = defaults.string(forKey: "commanderAppearance").flatMap(Appearance.init(rawValue:)) ?? .system
        appProfiles = defaults.data(forKey: "commanderAppProfiles").flatMap {
            try? JSONDecoder().decode([AppProfile].self, from: $0)
        } ?? []
        automaticProfiles = defaults.object(forKey: "automaticProfiles") as? Bool ?? true
        defaultProfile = defaults.string(forKey: "defaultProfile")
    }

    func rotate() { orientation = orientation.clockwise }

    func assign(_ application: AppProfile) {
        var updated = appProfiles.filter { $0.bundleID != application.bundleID }
        updated.append(application)
        appProfiles = updated.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func remove(_ application: AppProfile) {
        appProfiles.removeAll { $0.bundleID == application.bundleID }
    }

    func renameProfile(_ original: String, to name: String) {
        appProfiles = appProfiles.map { app in
            app.profile == original ? AppProfile(bundleID: app.bundleID, name: app.name, profile: name) : app
        }
        if defaultProfile == original { defaultProfile = name }
    }

    func removeProfile(_ name: String) {
        appProfiles.removeAll { $0.profile == name }
        if defaultProfile == name { defaultProfile = nil }
    }

    func profile(for bundleID: String?, available: [String]) -> String? {
        if automaticProfiles,
           let associated = appProfiles.first(where: { $0.bundleID == bundleID })?.profile,
           available.contains(associated) {
            return associated
        }
        if let defaultProfile, available.contains(defaultProfile) { return defaultProfile }
        return nil
    }

    func hasProfile(for bundleID: String?) -> Bool {
        automaticProfiles && appProfiles.contains { $0.bundleID == bundleID }
    }
}
