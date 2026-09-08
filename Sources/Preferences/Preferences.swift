import Foundation
import CoreGraphics

/// Settings that outlive a launch.
@MainActor
enum Preferences {
    private static let defaults = UserDefaults.standard
    private static let hotkeyKey = "hotkey"
    private static let enabledKey = "isDimmingEnabled"
    private static let dimmingKey = "dimming"

    static var isDimmingEnabled: Bool {
        get { defaults.bool(forKey: enabledKey) }
        set { defaults.set(newValue, forKey: enabledKey) }
    }

    /// 0 is a legitimate value ("Blur only"), so absence has to be checked
    /// explicitly — `double(forKey:)` returns 0 for a key that was never set.
    static var dimming: CGFloat {
        get {
            guard defaults.object(forKey: dimmingKey) != nil else { return 0.25 }
            return CGFloat(defaults.double(forKey: dimmingKey))
        }
        set { defaults.set(Double(newValue), forKey: dimmingKey) }
    }

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
