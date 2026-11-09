import Foundation

/// The test host is NemoNoise.app itself (same bundle id), so
/// `UserDefaults.standard` inside tests is the user's real app settings.
/// Snapshot every key a test writes and put it back afterwards:
///
///     let savedDefaults = UserDefaultsSnapshot([AppDefaults.Keys.engineType])
///     defer { savedDefaults.restore() }
struct UserDefaultsSnapshot {
    private let values: [String: Any]
    private let absentKeys: [String]

    init(_ keys: [String]) {
        var values: [String: Any] = [:]
        var absentKeys: [String] = []
        for key in keys {
            if let value = UserDefaults.standard.object(forKey: key) {
                values[key] = value
            } else {
                absentKeys.append(key)
            }
        }
        self.values = values
        self.absentKeys = absentKeys
    }

    func restore() {
        for (key, value) in values {
            UserDefaults.standard.set(value, forKey: key)
        }
        for key in absentKeys {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
