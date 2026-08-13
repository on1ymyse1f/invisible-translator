import Foundation

/// Only evaluation timestamps, aggregate language identifiers, and counters are
/// persisted. Source text, translations, application names, and window titles
/// never enter this model.
struct TranslationPreferenceProfile: Codable, Equatable {
    var firstRecordedAt: Date?
    var lastRecordedAt: Date?
    var lastEvaluatedAt: Date?
    var totalSuccessfulTranslations: Int
    var targetEventCounts: [String: Int]
    var targetScores: [String: Int]
    var pairEventCounts: [String: Int]
    var pairScores: [String: Int]
    var learnedTargets: [String: String]
    var learnedDefaultTargetRawValue: String?

    init(
        firstRecordedAt: Date? = nil,
        lastRecordedAt: Date? = nil,
        lastEvaluatedAt: Date? = nil,
        totalSuccessfulTranslations: Int = 0,
        targetEventCounts: [String: Int] = [:],
        targetScores: [String: Int] = [:],
        pairEventCounts: [String: Int] = [:],
        pairScores: [String: Int] = [:],
        learnedTargets: [String: String] = [:],
        learnedDefaultTargetRawValue: String? = nil
    ) {
        self.firstRecordedAt = firstRecordedAt
        self.lastRecordedAt = lastRecordedAt
        self.lastEvaluatedAt = lastEvaluatedAt
        self.totalSuccessfulTranslations = totalSuccessfulTranslations
        self.targetEventCounts = targetEventCounts
        self.targetScores = targetScores
        self.pairEventCounts = pairEventCounts
        self.pairScores = pairScores
        self.learnedTargets = learnedTargets
        self.learnedDefaultTargetRawValue = learnedDefaultTargetRawValue
    }
}

enum TranslationPreferenceLearningPolicy {
    static let evaluationDelay: TimeInterval = 14 * 24 * 60 * 60
    static let minimumOverallEvents = 8
    static let minimumSourceEvents = 4
    static let minimumConfidencePercent = 67
    static let minimumScoreLead = 2

    private static let pairSeparator = ">"

    static func record(
        profile: TranslationPreferenceProfile,
        sourceIdentifier: String,
        targetLanguage: TargetLanguage,
        at date: Date,
        deliberateTargetWeight: Int
    ) -> TranslationPreferenceProfile {
        var updated = profile
        let weight = min(max(deliberateTargetWeight, 1), 3)
        let targetKey = targetLanguage.rawValue

        if updated.firstRecordedAt == nil {
            updated.firstRecordedAt = date
        }
        updated.lastRecordedAt = date
        updated.totalSuccessfulTranslations += 1
        updated.targetEventCounts[targetKey, default: 0] += 1
        updated.targetScores[targetKey, default: 0] += weight

        if let source = canonicalSourceIdentifier(sourceIdentifier),
           canonicalSourceIdentifier(targetKey) != source {
            let key = pairKey(source: source, target: targetKey)
            updated.pairEventCounts[key, default: 0] += 1
            updated.pairScores[key, default: 0] += weight
        }

        return evaluated(profile: updated, at: date)
    }

    static func evaluated(
        profile: TranslationPreferenceProfile,
        at date: Date
    ) -> TranslationPreferenceProfile {
        guard let firstRecordedAt = profile.firstRecordedAt else {
            return profile
        }
        let elapsed = date.timeIntervalSince(firstRecordedAt)
        guard elapsed >= evaluationDelay else {
            return profile
        }

        var updated = profile
        updated.lastEvaluatedAt = date

        guard profile.totalSuccessfulTranslations >= minimumOverallEvents else {
            updated.learnedDefaultTargetRawValue = nil
            updated.learnedTargets.removeAll()
            return updated
        }

        updated.learnedDefaultTargetRawValue = winner(
            eventCounts: profile.targetEventCounts,
            scores: profile.targetScores,
            minimumEvents: minimumOverallEvents
        )

        let sources = Set(
            profile.pairEventCounts.keys.compactMap(pairComponents).map(\.source)
                + profile.learnedTargets.keys
        )
        for source in sources {
            let eventCounts = targetCounts(for: source, from: profile.pairEventCounts)
            let scores = targetCounts(for: source, from: profile.pairScores)
            if let target = winner(
                eventCounts: eventCounts,
                scores: scores,
                minimumEvents: minimumSourceEvents
            ) {
                updated.learnedTargets[source] = target
            } else {
                updated.learnedTargets.removeValue(forKey: source)
            }
        }

        return updated
    }

    static func preferredTarget(
        for sourceIdentifier: String,
        profile: TranslationPreferenceProfile
    ) -> TargetLanguage? {
        guard let source = canonicalSourceIdentifier(sourceIdentifier),
              let rawValue = profile.learnedTargets[source] else {
            return nil
        }
        return TargetLanguage(rawValue: rawValue)
    }

    static func preferredDefaultTarget(
        profile: TranslationPreferenceProfile
    ) -> TargetLanguage? {
        profile.learnedDefaultTargetRawValue.flatMap(TargetLanguage.init(rawValue:))
    }

    static func summary(
        profile: TranslationPreferenceProfile,
        enabled: Bool,
        now: Date
    ) -> String {
        guard enabled else {
            return "已关闭；现有本机统计不会继续增加"
        }
        guard let firstRecordedAt = profile.firstRecordedAt else {
            return "等待首次成功的主动翻译；不会保存原文或译文"
        }

        let elapsed = max(0, now.timeIntervalSince(firstRecordedAt))
        if elapsed < evaluationDelay {
            let currentDay = min(14, Int(elapsed / (24 * 60 * 60)) + 1)
            return "本机学习第 \(currentDay)/14 天 · \(profile.totalSuccessfulTranslations) 次主动翻译"
        }

        var learnedDescriptions = profile.learnedTargets
            .sorted { $0.key < $1.key }
            .compactMap { source, targetRawValue -> String? in
                guard let target = TargetLanguage(rawValue: targetRawValue) else { return nil }
                return "\(sourceDisplayName(source))→\(target.displayName)"
            }
        if learnedDescriptions.isEmpty,
           let target = preferredDefaultTarget(profile: profile) {
            learnedDescriptions.append("默认→\(target.displayName)")
        }
        guard !learnedDescriptions.isEmpty else {
            return "已满两周，样本或优势不足；继续本机学习（\(profile.totalSuccessfulTranslations) 次）"
        }
        return "已应用：\(learnedDescriptions.joined(separator: "、")) · \(profile.totalSuccessfulTranslations) 次主动翻译"
    }

    static func canonicalSourceIdentifier(_ identifier: String) -> String? {
        let normalized = identifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
        guard !normalized.isEmpty, normalized != "und" else { return nil }
        let base = normalized.split(separator: "-").first.map(String.init) ?? normalized
        guard base.count == 2 || base.count == 3 else { return nil }
        return base == "zh" ? "zh" : base
    }

    private static func winner(
        eventCounts: [String: Int],
        scores: [String: Int],
        minimumEvents: Int
    ) -> String? {
        let totalEvents = eventCounts.values.reduce(0, +)
        guard totalEvents >= minimumEvents else { return nil }

        let ranked = scores
            .filter { TargetLanguage(rawValue: $0.key) != nil && $0.value > 0 }
            .sorted {
                if $0.value == $1.value { return $0.key < $1.key }
                return $0.value > $1.value
            }
        guard let first = ranked.first else { return nil }
        let totalScore = ranked.reduce(0) { $0 + $1.value }
        let runnerUpScore = ranked.dropFirst().first?.value ?? 0
        guard totalScore > 0,
              first.value * 100 >= totalScore * minimumConfidencePercent,
              first.value - runnerUpScore >= minimumScoreLead else {
            return nil
        }
        return first.key
    }

    private static func pairKey(source: String, target: String) -> String {
        "\(source)\(pairSeparator)\(target)"
    }

    private static func pairComponents(_ key: String) -> (source: String, target: String)? {
        let components = key.split(separator: ">", maxSplits: 1).map(String.init)
        guard components.count == 2 else { return nil }
        return (components[0], components[1])
    }

    private static func targetCounts(
        for source: String,
        from values: [String: Int]
    ) -> [String: Int] {
        values.reduce(into: [:]) { result, entry in
            guard let components = pairComponents(entry.key), components.source == source else { return }
            result[components.target, default: 0] += entry.value
        }
    }

    private static func sourceDisplayName(_ source: String) -> String {
        switch source {
        case "zh": return "中文"
        case "en": return "英语"
        case "ja": return "日语"
        case "ko": return "韩语"
        case "fr": return "法语"
        case "de": return "德语"
        case "es": return "西班牙语"
        default: return source.uppercased()
        }
    }
}

enum TranslationPreferencePersistence {
    static let profileKey = "translationPreferenceProfile.v1"

    static func load(from defaults: UserDefaults = .standard) -> TranslationPreferenceProfile {
        guard let data = defaults.data(forKey: profileKey),
              let profile = try? JSONDecoder().decode(TranslationPreferenceProfile.self, from: data) else {
            return TranslationPreferenceProfile()
        }
        return profile
    }

    static func save(
        _ profile: TranslationPreferenceProfile,
        to defaults: UserDefaults = .standard
    ) {
        guard let data = try? JSONEncoder().encode(profile) else { return }
        defaults.set(data, forKey: profileKey)
    }

    static func reset(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: profileKey)
    }
}
