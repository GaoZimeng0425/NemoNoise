import Sentry

enum SentryService {
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: AppDefaults.Keys.sentryEnabled) }
        set {
            UserDefaults.standard.set(newValue, forKey: AppDefaults.Keys.sentryEnabled)
            if newValue {
                initialize()
            } else {
                SentrySDK.close()
            }
        }
    }

    static func initialize() {
        guard isEnabled else { return }
        let dsn = SentryConfig.dsn
        guard !dsn.isEmpty else { return }

        SentrySDK.start { options in
            options.dsn = dsn
        }
    }

    static func capture(error: Error) {
        guard isEnabled else { return }
        SentrySDK.capture(error: error)
    }

    static func capture(message: String) {
        guard isEnabled else { return }
        SentrySDK.capture(message: message)
    }
}
