import AppKit
import ApplicationServices

enum AppPrivacyPolicy {
    private static let builtInProtectedBundleIdentifiers: Set<String> = [
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.apple.keychainaccess",
        "com.apple.passwords",
        "com.bitwarden.desktop",
        "com.dashlane.dashlanephonefinal",
        "com.lastpass.lastpassmacdesktop",
        "org.keepassxc.keepassxc"
    ]

    static func normalizedIdentifier(_ identifier: String?) -> String? {
        guard let normalized = identifier?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              !normalized.isEmpty else {
            return nil
        }
        return normalized
    }

    static func isBuiltInProtected(_ identifier: String?) -> Bool {
        guard let identifier = normalizedIdentifier(identifier) else { return false }
        return builtInProtectedBundleIdentifiers.contains(identifier)
    }

    static func allowsCapture(
        bundleIdentifier: String?,
        userBlockedIdentifiers: Set<String>
    ) -> Bool {
        guard let identifier = normalizedIdentifier(bundleIdentifier),
              !builtInProtectedBundleIdentifiers.contains(identifier) else {
            return false
        }
        let normalizedBlocked = Set(userBlockedIdentifiers.compactMap(normalizedIdentifier))
        return !normalizedBlocked.contains(identifier)
    }
}

enum ContentFilterLevel: String, CaseIterable, Sendable {
    case off
    case bodyFirst
    case strict

    var displayName: String {
        switch self {
        case .off: return "关闭"
        case .bodyFirst: return "正文优先"
        case .strict: return "严格"
        }
    }
}

enum ContentFilterIntent: Sendable {
    case passiveSelection
    case hover
    case explicitSelection
    case explicitOCR
}

struct TranslationContentFilterResult: Equatable, Sendable {
    let text: String
    let profileIdentifier: String
    let removedLineCount: Int
}

enum TranslationContentFilter {
    private static let socialInterfaceLines: Set<String> = [
        "home", "explore", "notifications", "messages", "grok", "bookmarks",
        "communities", "premium", "profile", "more", "post", "reply", "repost",
        "like", "bookmark", "share", "follow", "following", "show more",
        "translate post", "what is happening?!", "who to follow", "trending",
        "主页", "探索", "通知", "消息", "书签", "社区", "个人资料", "更多",
        "发布", "回复", "转发", "喜欢", "分享", "关注", "显示更多", "翻译帖子",
        "ホーム", "話題を検索", "通知", "メッセージ", "ブックマーク", "プロフィール",
        "もっと見る", "ポストする", "返信", "リポスト", "いいね", "共有"
    ]

    static func filter(
        _ rawText: String,
        level: ContentFilterLevel,
        intent: ContentFilterIntent,
        appName: String?,
        windowTitle: String?
    ) -> TranslationContentFilterResult? {
        guard let normalized = SelectionTextNormalizer.normalizedText(from: rawText) else {
            return nil
        }

        // A deliberate selection or OCR rectangle expresses user intent. Never
        // second-guess it with site-specific relevance scoring.
        if level == .off || intent == .explicitSelection || intent == .explicitOCR {
            return TranslationContentFilterResult(
                text: normalized,
                profileIdentifier: "explicit",
                removedLineCount: 0
            )
        }

        guard isSocialFeedContext(appName: appName, windowTitle: windowTitle) else {
            return TranslationContentFilterResult(
                text: normalized,
                profileIdentifier: "generic",
                removedLineCount: 0
            )
        }

        let socialNormalized = normalized
            .precomposedStringWithCompatibilityMapping
            .replacingOccurrences(of: "\u{200B}", with: "")
            .replacingOccurrences(of: "\u{200C}", with: "")
            .replacingOccurrences(of: "\u{200D}", with: "")
            .replacingOccurrences(of: "\u{2060}", with: "")
            .replacingOccurrences(of: "\u{FEFF}", with: "")
        let lines = socialNormalized.components(separatedBy: .newlines)
        var kept: [String] = []
        var removed = 0
        for rawLine in lines {
            let line = rawLine
                .replacingOccurrences(of: "\u{00A0}", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if shouldDropSocialLine(line, level: level) {
                removed += 1
            } else {
                kept.append(line)
            }
        }

        let filtered = kept.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard PassiveTextEligibility.normalizedCandidate(
            filtered,
            maximumCharacters: TranslationLimits.maxInputCharacters
        ) != nil else {
            return nil
        }
        return TranslationContentFilterResult(
            text: filtered,
            profileIdentifier: "x-twitter",
            removedLineCount: removed
        )
    }

    static func isSocialFeedContext(appName: String?, windowTitle: String?) -> Bool {
        let app = appName?.lowercased() ?? ""
        if app == "x" || app.contains("twitter") {
            return true
        }
        let title = windowTitle?.lowercased() ?? ""
        return title.contains("twitter")
            || title.hasSuffix(" / x")
            || title.contains(" on x:")
            || title.contains(" — x")
            || title.contains(" - x.com")
    }

    private static func shouldDropSocialLine(
        _ line: String,
        level: ContentFilterLevel
    ) -> Bool {
        let lower = line.lowercased()
        if socialInterfaceLines.contains(lower) { return true }
        if lower == "promoted" || lower == "ad" || lower == "广告" || lower == "プロモーション" {
            return true
        }
        if ResponseLanguageDetector.isSkippableLiteral(line) { return true }
        if matches(#"^@[A-Za-z0-9_]{1,15}$"#, line) { return true }
        if matches(#"^(\d+[smhdwy]|\d+\s*(秒|分钟|小時|小时|天|周|週|月|年)前)$"#, lower) {
            return true
        }
        if matches(#"^\d+(?:[.,]\d+)?[kmb万千]?$"#, lower) { return true }
        if matches(
            #"^\d+(?:[.,]\d+)?[kmb万千]?\s*(replies?|reposts?|likes?|views?|bookmarks?|回复|转发|喜欢|浏览)$"#,
            lower
        ) {
            return true
        }
        if level == .strict,
           line.count <= 3,
           !line.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }) {
            return true
        }
        return false
    }

    private static func matches(_ pattern: String, _ value: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }
}

@MainActor
enum AppWindowContext {
    static func title(for app: NSRunningApplication) -> String? {
        let applicationElement = AXUIElementCreateApplication(app.processIdentifier)
        let window = elementAttribute(kAXFocusedWindowAttribute, from: applicationElement)
            ?? elementAttribute(kAXMainWindowAttribute, from: applicationElement)
        guard let window else { return nil }
        return stringAttribute(kAXTitleAttribute, from: window)
    }

    private static func elementAttribute(
        _ attribute: String,
        from element: AXUIElement
    ) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement)
    }

    private static func stringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }
}
