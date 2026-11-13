import Foundation

@main
struct PreferencesTests {
    @MainActor
    static func main() {
        let suite = "KeydialTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        precondition(preferences.appPresence == .both)
        preferences.appPresence = .menuBarOnly
        preferences.defaultProfile = "Everyday"
        preferences.assign(.init(bundleID: "com.example.art", name: "Art", profile: "Painting"))
        preferences.rotate()
        precondition(preferences.profile(for: "com.example.art", available: ["Everyday", "Painting"]) == "Painting")
        precondition(preferences.profile(for: "com.example.other", available: ["Everyday", "Painting"]) == "Everyday")

        let restored = Preferences(defaults: defaults)
        precondition(restored.appPresence == .menuBarOnly)
        precondition(restored.orientation == .upperRight)
        precondition(restored.appProfiles.first?.profile == "Painting")
        restored.renameProfile("Painting", to: "Illustration")
        precondition(restored.profile(for: "com.example.art", available: ["Everyday", "Illustration"]) == "Illustration")
        restored.automaticProfiles = false
        precondition(restored.profile(for: "com.example.art", available: ["Everyday", "Illustration"]) == "Everyday")
        restored.removeProfile("Illustration")
        precondition(restored.appProfiles.isEmpty)
        print("Rotation and app associations persist, resolve the fallback, and follow profile renames.")
    }
}
