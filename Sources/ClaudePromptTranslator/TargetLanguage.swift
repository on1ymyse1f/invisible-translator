import Foundation

enum TargetLanguage: String, CaseIterable, Identifiable, Sendable {
    case simplifiedChinese = "zh-CN"
    case english = "en"
    case japanese = "ja"

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .simplifiedChinese:
            return "简体中文"
        case .english:
            return "英语"
        case .japanese:
            return "日语"
        }
    }

    var shortChineseName: String {
        switch self {
        case .simplifiedChinese:
            return "中文"
        case .english:
            return "英文"
        case .japanese:
            return "日文"
        }
    }

    /// Apple Translation models use the script identifier for Simplified Chinese.
    var appleLanguageCode: String {
        switch self {
        case .simplifiedChinese:
            return "zh-Hans"
        case .english, .japanese:
            return rawValue
        }
    }
}
