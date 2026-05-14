import Foundation

enum LanguagePreference: String, CaseIterable, Codable, Identifiable {
    case auto = "Auto-detect"
    case zh = "Chinese (中文)"
    case en = "English"
    case ja = "Japanese (日本語)"
    case ko = "Korean (한국어)"
    case yue = "Cantonese (粤语)"

    var id: String { rawValue }

    var sherpaCode: String {
        switch self {
        case .auto: return "auto"
        case .zh:   return "zh"
        case .en:   return "en"
        case .ja:   return "ja"
        case .ko:   return "ko"
        case .yue:  return "yue"
        }
    }

    var localeIdentifier: String? {
        switch self {
        case .auto: return nil
        case .zh:   return "zh-CN"
        case .en:   return "en-US"
        case .ja:   return "ja-JP"
        case .ko:   return "ko-KR"
        case .yue:  return "zh-HK"
        }
    }

    static var current: LanguagePreference {
        let raw = UserDefaults.standard.string(forKey: AppDefaults.Keys.languagePreference) ?? AppDefaults.Defaults.languagePreference
        return LanguagePreference(rawValue: raw) ?? .auto
    }
}
