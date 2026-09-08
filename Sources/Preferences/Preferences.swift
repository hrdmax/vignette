import Foundation

/// Settings that outlive a launch.
@MainActor
enum Preferences {
    private static let defaults = UserDefaults.standard
    private static let hotkeyKey = "hotkey"

    static var hotkey: Hotkey? {
        get {
            guard let data = defaults.data(forKey: hotkeyKey) else { return nil }
            return try? JSONDecoder().decode(Hotkey.self, from: data)
        }
        set {
            guard let newValue else {
                defaults.removeObject(forKey: hotkeyKey)
                return
            }
            defaults.set(try? JSONEncoder().encode(newValue), forKey: hotkeyKey)
        }
    }
}
