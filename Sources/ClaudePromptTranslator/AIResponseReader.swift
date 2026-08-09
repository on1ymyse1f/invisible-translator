import AppKit
import ApplicationServices
import CryptoKit
import Foundation
import NaturalLanguage
import ScreenCaptureKit
import Vision

enum ResponseCaptureSource: String, Equatable, Sendable {
    case selectedText
    case chatGPTAccessibility
    case semanticAccessibility
    case genericAccessibility
    case opticalCharacterRecognition

    var displayName: String {
        switch self {
        case .selectedText:
            return "选中文字"
        case .chatGPTAccessibility:
            return "ChatGPT 结构化读取"
        case .semanticAccessibility:
            return "语义化辅助功能读取"
        case .genericAccessibility:
            return "通用辅助功能读取"
        case .opticalCharacterRecognition:
            return "OCR"
        }
    }
}

struct DetectedForeignResponse: Equatable, Sendable {
    let text: String
    let language: DetectedResponseLanguage
    let captureSource: ResponseCaptureSource
    let turnIdentifier: String?

    init(
        text: String,
        language: DetectedResponseLanguage,
        captureSource: ResponseCaptureSource = .selectedText,
        turnIdentifier: String? = nil
    ) {
        self.text = text
        self.language = language
        self.captureSource = captureSource
        self.turnIdentifier = turnIdentifier
    }

    func annotated(
        source: ResponseCaptureSource,
        applicationIdentifier: String,
        ordinal: Int? = nil
    ) -> DetectedForeignResponse {
        let normalizedPrefix = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .prefix(72)
        let turnComponent = ordinal.map(String.init) ?? String(normalizedPrefix)
        return DetectedForeignResponse(
            text: text,
            language: language,
            captureSource: source,
            turnIdentifier: "\(applicationIdentifier)|\(source.rawValue)|\(turnComponent)"
        )
    }
}

struct ResponseAdapterScan: Sendable {
    let isAuthoritative: Bool
    let response: DetectedForeignResponse?
}

protocol ResponseSourceAdapter: Sendable {
    var captureSource: ResponseCaptureSource { get }

    func scan(
        rawTexts: [String],
        reader: AIResponseReader
    ) -> ResponseAdapterScan
}

struct SemanticAccessibilityResponseAdapter: ResponseSourceAdapter {
    let captureSource = ResponseCaptureSource.semanticAccessibility

    func scan(
        rawTexts: [String],
        reader: AIResponseReader
    ) -> ResponseAdapterScan {
        let scan = AIResponseReader.speakerAttributedForeignResponse(from: rawTexts)
        return ResponseAdapterScan(
            isAuthoritative: scan.foundSpeakerMarkers,
            response: scan.response
        )
    }
}

struct GenericAccessibilityResponseAdapter: ResponseSourceAdapter {
    let captureSource = ResponseCaptureSource.genericAccessibility

    func scan(
        rawTexts: [String],
        reader: AIResponseReader
    ) -> ResponseAdapterScan {
        ResponseAdapterScan(
            isAuthoritative: false,
            response: reader.latestGenericForeignResponse(from: rawTexts)
        )
    }
}

struct ResponseTranslationCache: Sendable {
    private let capacity: Int
    private let timeToLive: TimeInterval
    private var entries: [(key: String, translation: String, expiresAt: Date)] = []

    init(capacity: Int = 32, timeToLive: TimeInterval = 300) {
        self.capacity = max(1, capacity)
        self.timeToLive = max(1, timeToLive)
    }

    mutating func translation(for source: String, now: Date = Date()) -> String? {
        removeExpiredEntries(now: now)
        let key = Self.key(for: source)
        guard let index = entries.firstIndex(where: { $0.key == key }) else {
            return nil
        }

        let entry = entries.remove(at: index)
        entries.append(entry)
        return entry.translation
    }

    mutating func insert(_ translation: String, for source: String, now: Date = Date()) {
        removeExpiredEntries(now: now)
        let key = Self.key(for: source)
        entries.removeAll { $0.key == key }
        entries.append((key: key, translation: translation, expiresAt: now.addingTimeInterval(timeToLive)))
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }

    mutating func translation(for response: DetectedForeignResponse, now: Date = Date()) -> String? {
        translation(forKey: Self.key(for: response), now: now)
    }

    mutating func insert(_ translation: String, for response: DetectedForeignResponse, now: Date = Date()) {
        insert(translation, forKey: Self.key(for: response), now: now)
    }

    mutating func removeAll() {
        entries.removeAll(keepingCapacity: false)
    }

    private mutating func translation(forKey key: String, now: Date) -> String? {
        removeExpiredEntries(now: now)
        guard let index = entries.firstIndex(where: { $0.key == key }) else {
            return nil
        }

        let entry = entries.remove(at: index)
        entries.append(entry)
        return entry.translation
    }

    private mutating func insert(_ translation: String, forKey key: String, now: Date) {
        removeExpiredEntries(now: now)
        entries.removeAll { $0.key == key }
        entries.append((key: key, translation: translation, expiresAt: now.addingTimeInterval(timeToLive)))
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }

    private static func key(for source: String) -> String {
        digest(
            source
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        )
    }

    private static func key(for response: DetectedForeignResponse) -> String {
        let normalizedText = response.text
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard let turnIdentifier = response.turnIdentifier else {
            return digest(normalizedText)
        }
        return digest("\(turnIdentifier)|\(normalizedText)")
    }

    private mutating func removeExpiredEntries(now: Date) {
        entries.removeAll { $0.expiresAt <= now }
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

enum BilingualResponseFormatter {
    static func sourcePreview(_ source: String, limit sourceLimit: Int = 800) -> String {
        let limit = max(1, sourceLimit)
        return source.count > limit
            ? String(source.prefix(limit)) + "…"
            : source
    }

    static func display(source: String, translation: String, sourceLimit: Int = 800) -> String {
        guard !translation.isEmpty else {
            return ""
        }
        guard !source.isEmpty else {
            return translation
        }

        let preview = sourcePreview(source, limit: sourceLimit)
        return "原文\n\(preview)\n\n译文\n\(translation)"
    }
}

struct DetectedResponseLanguage: Equatable, Hashable, Sendable {
    let identifier: String

    static let english = DetectedResponseLanguage(identifier: "en")
    static let japanese = DetectedResponseLanguage(identifier: "ja")
    static let latinScript = DetectedResponseLanguage(identifier: "und-Latn")

    var isChinese: Bool {
        let lowercased = identifier.lowercased()
        return lowercased == "zh"
            || lowercased.hasPrefix("zh-")
            || lowercased == "yue"
            || lowercased.hasPrefix("yue-")
    }

    var displayName: String {
        switch identifier.lowercased() {
        case "en":
            return "English"
        case "ja":
            return "Japanese"
        case "und-latn":
            return "拉丁文字"
        default:
            let baseLanguageCode = identifier.split(separator: "-").first.map(String.init)
                ?? identifier
            return Locale(identifier: "zh-Hans")
                .localizedString(forLanguageCode: baseLanguageCode)
                ?? identifier
        }
    }
}

struct AIResponseReader: Sendable {
    private enum ConversationSpeaker {
        case user
        case assistant
    }

    struct SpeakerAttributedScan: Equatable, Sendable {
        let foundSpeakerMarkers: Bool
        let response: DetectedForeignResponse?
    }

    struct ConversationStructureScan: Equatable, Sendable {
        let foundConversationStructure: Bool
        let response: DetectedForeignResponse?
    }

    private let maxDepth = 26
    private let maxNodes = 4_000
    private let maxCandidateLength = TranslationLimits.maxResponseCharacters

    func latestForeignResponse(
        in app: NSRunningApplication,
        allowOCR: Bool = true
    ) async -> DetectedForeignResponse? {
        guard AccessibilityPermission.isTrusted else {
            return nil
        }

        let root = rootElement(for: app)
        let applicationIdentifier = app.bundleIdentifier
            ?? app.localizedName
            ?? "pid-\(app.processIdentifier)"

        if app.bundleIdentifier == "com.openai.chat" {
            let structured = latestChatGPTClassicResponse(from: root)
            if structured.foundConversationStructure {
                return structured.response?.annotated(
                    source: .chatGPTAccessibility,
                    applicationIdentifier: applicationIdentifier
                )
            }
        }

        var nodeCount = 0
        var rawTexts: [String] = []
        collectTexts(from: root, depth: 0, nodeCount: &nodeCount, into: &rawTexts)
        rawTexts = Self.removingExactInterfaceChrome(
            from: rawTexts,
            labels: [
                app.localizedName,
                stringAttribute(kAXTitleAttribute, from: root)
            ].compactMap { $0 }
        ).compactMap(Self.removingStandaloneResourceLines(from:))

        let adapters: [any ResponseSourceAdapter] = [
            SemanticAccessibilityResponseAdapter(),
            GenericAccessibilityResponseAdapter()
        ]
        for adapter in adapters {
            let scan = adapter.scan(rawTexts: rawTexts, reader: self)
            if let response = scan.response {
                return response.annotated(
                    source: adapter.captureSource,
                    applicationIdentifier: applicationIdentifier
                )
            }
            if scan.isAuthoritative {
                return nil
            }
        }

        guard allowOCR else {
            return nil
        }

        return await latestForeignResponseFromOCR(in: app)?.annotated(
            source: .opticalCharacterRecognition,
            applicationIdentifier: applicationIdentifier
        )
    }

    func selectedForeignResponse(in app: NSRunningApplication) -> DetectedForeignResponse? {
        guard AccessibilityPermission.isTrusted else {
            return nil
        }

        let root = rootElement(for: app)
        let applicationIdentifier = app.bundleIdentifier
            ?? app.localizedName
            ?? "pid-\(app.processIdentifier)"
        var nodeCount = 0
        var selectedTexts: [String] = []
        collectSelectedTexts(from: root, depth: 0, nodeCount: &nodeCount, into: &selectedTexts)

        for text in selectedTexts.reversed() {
            if let response = Self.foreignSelection(from: text) {
                return response.annotated(
                    source: .selectedText,
                    applicationIdentifier: applicationIdentifier
                )
            }
        }
        return nil
    }

    static func speakerAttributedForeignResponse(from rawTexts: [String]) -> SpeakerAttributedScan {
        var foundSpeakerMarkers = false
        var currentSpeaker: ConversationSpeaker?
        var currentAssistantTexts: [String] = []
        var assistantGroups: [[String]] = []

        func flushAssistantGroup() {
            guard !currentAssistantTexts.isEmpty else { return }
            assistantGroups.append(currentAssistantTexts)
            currentAssistantTexts = []
        }

        for rawText in rawTexts {
            let text = compactConversationText(rawText)
            guard !text.isEmpty else { continue }

            if let marker = speakerMarker(in: text) {
                if currentSpeaker == .assistant {
                    flushAssistantGroup()
                }
                foundSpeakerMarkers = true
                currentSpeaker = marker.speaker
                if marker.speaker == .assistant,
                   let remainder = marker.remainder,
                   !remainder.isEmpty,
                   !isConversationChromeText(remainder) {
                    currentAssistantTexts.append(remainder)
                }
                continue
            }

            guard currentSpeaker == .assistant,
                  !isConversationChromeText(text) else {
                continue
            }
            currentAssistantTexts.append(text)
        }
        flushAssistantGroup()

        for group in assistantGroups.reversed() {
            let candidates = leafPreferredDeduplicated(group)
                .filter { !isConversationChromeText($0) }
            let combined = candidates
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if let response = foreignSelection(from: combined) {
                return SpeakerAttributedScan(
                    foundSpeakerMarkers: true,
                    response: response
                )
            }

            for candidate in candidates.reversed() {
                if let response = foreignSelection(from: candidate) {
                    return SpeakerAttributedScan(
                        foundSpeakerMarkers: true,
                        response: response
                    )
                }
            }
        }

        return SpeakerAttributedScan(
            foundSpeakerMarkers: foundSpeakerMarkers,
            response: nil
        )
    }

    static func assistantResponseFromAlternatingMessages(
        _ messages: [String]
    ) -> ConversationStructureScan {
        let normalized = messages
            .map(compactConversationText)
            .filter { !$0.isEmpty && !isConversationChromeText($0) }

        guard !normalized.isEmpty else {
            return ConversationStructureScan(
                foundConversationStructure: false,
                response: nil
            )
        }

        // ChatGPT Classic exposes each visible user/assistant turn as one
        // direct child group in chronological order, starting with the user.
        // An odd count means the newest item is a user prompt still awaiting a
        // reply; never fall back to translating that prompt.
        guard normalized.count.isMultiple(of: 2) else {
            return ConversationStructureScan(
                foundConversationStructure: true,
                response: nil
            )
        }

        return ConversationStructureScan(
            foundConversationStructure: true,
            response: foreignSelection(from: normalized.last)
        )
    }

    private func latestChatGPTClassicResponse(
        from root: AXUIElement
    ) -> ConversationStructureScan {
        var bestMessages: [String] = []
        var bestScore = 0
        var visited = 0

        func visit(_ element: AXUIElement, depth: Int) {
            guard depth <= maxDepth, visited < maxNodes else { return }
            visited += 1

            let role = stringAttribute(kAXRoleAttribute, from: element)
            if role == (kAXListRole as String),
               stringAttribute(kAXSubroleAttribute, from: element) == "AXSectionList",
               let directChildren = childrenAttribute(kAXChildrenAttribute, from: element) {
                let messages = directChildren.compactMap { child -> String? in
                    var childNodeCount = 0
                    var texts: [String] = []
                    collectTexts(
                        from: child,
                        depth: 0,
                        nodeCount: &childNodeCount,
                        into: &texts
                    )
                    let candidates = Self.leafPreferredDeduplicated(
                        texts.map(Self.compactConversationText).filter { !$0.isEmpty }
                    )
                    let combined = candidates
                        .filter { !Self.isConversationChromeText($0) }
                        .joined(separator: "\n")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard combined.count >= 2,
                          !ResponseLanguageDetector.isSkippableLiteral(combined) else {
                        return nil
                    }
                    return combined
                }
                let score = messages.reduce(0) { $0 + min($1.count, 2_000) }
                    + messages.count * 1_000
                if score > bestScore {
                    bestScore = score
                    bestMessages = messages
                }
            }

            guard let children = childrenAttribute(kAXChildrenAttribute, from: element) else {
                return
            }
            for child in children {
                visit(child, depth: depth + 1)
            }
        }

        visit(root, depth: 0)
        return Self.assistantResponseFromAlternatingMessages(bestMessages)
    }

    private static func speakerMarker(
        in text: String
    ) -> (speaker: ConversationSpeaker, remainder: String?)? {
        let markers: [(prefix: String, speaker: ConversationSpeaker)] = [
            ("chatgpt said:", .assistant),
            ("chatgpt says:", .assistant),
            ("chatgpt 说：", .assistant),
            ("chatgpt说：", .assistant),
            ("assistant said:", .assistant),
            ("assistant says:", .assistant),
            ("助手说：", .assistant),
            ("claude responded:", .assistant),
            ("claude said:", .assistant),
            ("claude 回复：", .assistant),
            ("claude回复：", .assistant),
            ("you said:", .user),
            ("user said:", .user),
            ("你说：", .user),
            ("用户说：", .user),
            ("あなた：", .user),
            ("あなた:", .user)
        ]

        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = normalized.lowercased()

        for marker in markers where lowercased.hasPrefix(marker.prefix.lowercased()) {
            let boundary = normalized.index(
                normalized.startIndex,
                offsetBy: marker.prefix.count,
                limitedBy: normalized.endIndex
            ) ?? normalized.endIndex
            let remainder = String(normalized[boundary...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (marker.speaker, remainder.isEmpty ? nil : remainder)
        }

        let heading = lowercased
            .replacingOccurrences(of: " ", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: ":："))
        switch heading {
        case "chatgptsaid", "chatgptsays", "chatgpt说", "assistantsaid", "assistantsays",
             "助手说", "clauderesponded", "claudesaid", "claude回复":
            return (.assistant, nil)
        case "yousaid", "usersaid", "你说", "用户说", "あなた":
            return (.user, nil)
        default:
            return nil
        }
    }

    private static func compactConversationText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: .newlines)
            .map { line in
                line.components(separatedBy: .whitespaces)
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func removingExactInterfaceChrome(
        from rawTexts: [String],
        labels: [String]
    ) -> [String] {
        let normalizedLabels = Set(
            labels
                .map(compactConversationText)
                .filter { $0.count >= 2 }
        )
        guard !normalizedLabels.isEmpty else {
            return rawTexts
        }

        return rawTexts.filter {
            !normalizedLabels.contains(compactConversationText($0))
        }
    }

    static func removingStandaloneResourceLines(from text: String) -> String? {
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !ResponseLanguageDetector.isSkippableLiteral($0) }
        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: "\n")
    }

    private static func isConversationChromeText(_ text: String) -> Bool {
        let lowercased = compactConversationText(text).lowercased()
        return [
            "chatgpt 也可能会犯错",
            "chatgpt can make mistakes",
            "reply actions",
            "回复操作",
            "your message actions",
            "save prompt",
            "copy message",
            "copy response",
            "share prompt",
            "edit message",
            "start dictation",
            "stop responding",
            "ask chatgpt",
            "询问 chatgpt",
            "问问 chatgpt",
            "信息栏容器",
            "信息栏",
            "google chrome 不是您的默认浏览器",
            "google chrome isn't your default browser",
            "google chrome is not your default browser"
        ].contains { lowercased.hasPrefix($0) }
    }

    static func foreignSelection(from text: String?) -> DetectedForeignResponse? {
        guard let text else {
            return nil
        }

        let normalized = text
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: .newlines)
            .map { line in
                line.components(separatedBy: .whitespaces)
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalized.isEmpty,
              normalized.count <= TranslationLimits.maxResponseCharacters,
              !ResponseLanguageDetector.isSkippableLiteral(normalized),
              let language = ResponseLanguageDetector.detectExplicitSelection(in: normalized) else {
            return nil
        }

        return DetectedForeignResponse(text: normalized, language: language)
    }

    fileprivate func latestGenericForeignResponse(from rawTexts: [String]) -> DetectedForeignResponse? {
        let texts = Self.leafPreferredDeduplicated(rawTexts.compactMap(normalizedText(_:)))
            .filter(isSubstantiveText(_:))

        guard !texts.isEmpty else {
            return nil
        }

        let lowerBound = max(0, texts.count - 96)
        for endIndex in stride(from: texts.count - 1, through: lowerBound, by: -1) {
            let combined = responseSuffix(endingAt: endIndex, lowerBound: lowerBound, texts: texts)

            if let prose = proseCandidate(from: combined),
               prose.count >= 60,
               let language = ResponseLanguageDetector.detect(in: prose) {
                return DetectedForeignResponse(text: prose, language: language)
            }
        }

        return nil
    }

    private func latestForeignResponseFromOCR(
        in app: NSRunningApplication
    ) async -> DetectedForeignResponse? {
        guard let image = await capturedConversationImage(for: app) else {
            return nil
        }

        let lines = recognizedTextLines(in: image)
        guard lines.count >= 2 else {
            return nil
        }

        return latestForeignOCRProse(from: lines)
    }

    private func latestForeignOCRProse(from lines: [String]) -> DetectedForeignResponse? {
        var groups: [[String]] = []
        var current: [String] = []

        func flush() {
            if !current.isEmpty {
                groups.append(current)
                current = []
            }
        }

        for rawLine in lines {
            guard let line = normalizedOCRLine(rawLine) else {
                flush()
                continue
            }

            if isOCRBoundaryLine(line) {
                flush()
                continue
            }

            if isOCRProseLine(line) {
                current.append(line)
            } else {
                flush()
            }
        }
        flush()

        for group in groups.reversed() {
            let prose = group.joined(separator: "\n")
            guard prose.count >= 40,
                  ResponseLanguageDetector.isLikelyTranslatableProse(prose),
                  let language = ResponseLanguageDetector.detect(in: prose) else {
                continue
            }

            return DetectedForeignResponse(text: prose, language: language)
        }

        return nil
    }

    private func responseSuffix(endingAt endIndex: Int, lowerBound: Int, texts: [String]) -> String {
        var selected: [String] = []
        var selectedLength = 0

        for index in stride(from: endIndex, through: lowerBound, by: -1) {
            let text = texts[index]

            if isResponseBoundary(text) {
                if selected.isEmpty {
                    continue
                } else {
                    break
                }
            }

            let projectedLength = selectedLength + text.count + (selected.isEmpty ? 0 : 2)
            if projectedLength > maxCandidateLength {
                break
            }

            selected.insert(text, at: 0)
            selectedLength = projectedLength
        }

        return selected.joined(separator: "\n\n")
    }

    private func rootElement(for app: NSRunningApplication) -> AXUIElement {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)

        if let focusedWindow = elementAttribute(kAXFocusedWindowAttribute, from: appElement) {
            return focusedWindow
        }

        if let mainWindow = elementAttribute(kAXMainWindowAttribute, from: appElement) {
            return mainWindow
        }

        return appElement
    }

    private func capturedConversationImage(for app: NSRunningApplication) async -> CGImage? {
        guard ScreenRecordingPermission.isGranted,
              let windowID = frontmostWindowID(for: app) else {
            return nil
        }

        let image: CGImage
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                true,
                onScreenWindowsOnly: true
            )
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                return nil
            }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let configuration = SCStreamConfiguration()
            let scale = max(CGFloat(filter.pointPixelScale), 1)
            configuration.width = max(Int(window.frame.width * scale), 1)
            configuration.height = max(Int(window.frame.height * scale), 1)
            configuration.showsCursor = false
            configuration.ignoreShadowsSingleWindow = true
            image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
        } catch {
            return nil
        }

        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        guard width >= 420, height >= 320 else {
            return image
        }

        let appName = app.localizedName?.lowercased() ?? ""
        let leftRatio: CGFloat = {
            if appName.contains("claude") { return 0.30 }
            if appName.contains("chatgpt") || appName.contains("gemini") { return 0.18 }
            if appName.contains("deepseek") || appName.contains("kimi") || appName.contains("doubao") { return 0.16 }
            return 0.14
        }()
        let cropRect = CGRect(
            x: width * leftRatio,
            y: height * 0.07,
            width: width * (0.96 - leftRatio),
            height: height * 0.76
        ).integral

        return image.cropping(to: cropRect) ?? image
    }

    private struct OCRLine {
        let text: String
        let confidence: Float
        let boundingBox: CGRect
    }

    private struct OCRPass {
        let lines: [OCRLine]

        var averageConfidence: Float {
            guard !lines.isEmpty else { return 0 }
            return lines.reduce(0) { $0 + $1.confidence } / Float(lines.count)
        }
    }

    static func shouldRetryOCR(lineCount: Int, averageConfidence: Float) -> Bool {
        lineCount < 2 || averageConfidence < 0.72
    }

    private func recognizedTextLines(in image: CGImage) -> [String] {
        let automaticPass = performOCR(in: image, recognitionLanguages: nil)
        guard Self.shouldRetryOCR(
            lineCount: automaticPass.lines.count,
            averageConfidence: automaticPass.averageConfidence
        ) else {
            return automaticPass.lines.map(\.text)
        }

        let detectedLanguage = ResponseLanguageDetector.detectExplicitSelection(
            in: automaticPass.lines.map(\.text).joined(separator: "\n")
        )
        let secondPass = performOCR(
            in: image,
            recognitionLanguages: preferredOCRLanguages(for: detectedLanguage)
        )
        let automaticScore = automaticPass.averageConfidence
            + min(Float(automaticPass.lines.count), 12) * 0.012
        let secondPassScore = secondPass.averageConfidence
            + min(Float(secondPass.lines.count), 12) * 0.012
        return (secondPassScore > automaticScore ? secondPass : automaticPass)
            .lines
            .map(\.text)
    }

    private func performOCR(
        in image: CGImage,
        recognitionLanguages: [String]?
    ) -> OCRPass {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        if let recognitionLanguages {
            request.automaticallyDetectsLanguage = false
            request.recognitionLanguages = recognitionLanguages
        } else {
            request.automaticallyDetectsLanguage = true
        }

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return OCRPass(lines: [])
        }

        let lines = (request.results ?? [])
            .sorted { lhs, rhs in
                if abs(lhs.boundingBox.midY - rhs.boundingBox.midY) > 0.015 {
                    return lhs.boundingBox.maxY > rhs.boundingBox.maxY
                }
                return lhs.boundingBox.minX < rhs.boundingBox.minX
            }
            .compactMap { observation -> OCRLine? in
                guard let candidate = observation.topCandidates(1).first else {
                    return nil
                }
                let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                return OCRLine(
                    text: text,
                    confidence: candidate.confidence,
                    boundingBox: observation.boundingBox
                )
            }
        return OCRPass(lines: lines)
    }

    private func preferredOCRLanguages(for language: DetectedResponseLanguage?) -> [String] {
        switch language?.identifier.lowercased() {
        case "en": return ["en-US"]
        case "ja": return ["ja-JP"]
        case "ko": return ["ko-KR"]
        case "fr": return ["fr-FR"]
        case "de": return ["de-DE"]
        case "es": return ["es-ES"]
        case "it": return ["it-IT"]
        case "pt": return ["pt-BR", "pt-PT"]
        case "ru": return ["ru-RU"]
        default:
            return ["en-US", "ja-JP", "ko-KR", "fr-FR", "de-DE", "es-ES"]
        }
    }

    private func normalizedOCRLine(_ line: String) -> String? {
        let cleaned = Self.strippingOCRPrefixes(from: line)
            .replacingOccurrences(of: "—", with: "-")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard cleaned.count >= 2 else {
            return nil
        }

        return cleaned
    }

    private func isOCRBoundaryLine(_ line: String) -> Bool {
        let lowercased = line.lowercased()
        if lowercased.hasPrefix("write a message")
            || lowercased.hasPrefix("message ")
            || lowercased.hasPrefix("draft an email")
            || lowercased.hasPrefix("opus ")
            || lowercased == "+"
            || lowercased == "claude"
            || lowercased == "techspot"
            || lowercased.contains("›")
            || lowercased.contains(">")
            || lowercased.contains("claude is ai and can make mistakes") {
            return true
        }

        if lowercased.hasPrefix("disney attractions")
            || lowercased.hasPrefix("new chat")
            || lowercased.hasPrefix("projects")
            || lowercased.hasPrefix("recents") {
            return true
        }

        return false
    }

    private func isOCRProseLine(_ line: String) -> Bool {
        guard !ResponseLanguageDetector.isNonProseContentLine(line) else {
            return false
        }

        let letters = line.unicodeScalars.filter { scalar in
            CharacterSet.letters.contains(scalar)
        }.count
        guard letters >= 16 else {
            return false
        }

        let words = line.split { !$0.isLetter }.filter { $0.count >= 2 }
        return words.count >= 4
            || ResponseLanguageDetector.detectExplicitSelection(in: line) != nil
    }

    private func frontmostWindowID(for app: NSRunningApplication) -> CGWindowID? {
        EdgeOverlayGeometry.mainWindowID(for: app)
    }

    private func collectTexts(
        from element: AXUIElement,
        depth: Int,
        nodeCount: inout Int,
        into texts: inout [String]
    ) {
        guard depth <= maxDepth, nodeCount < maxNodes else {
            return
        }
        nodeCount += 1

        let role = stringAttribute(kAXRoleAttribute, from: element)
        let isEditableInput = Self.isEditableTextInput(element, role: role)
        let isInteractiveControl = Self.isInteractiveControl(role: role)

        if !isEditableInput, !isInteractiveControl {
            for attribute in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
                if let text = stringAttribute(attribute, from: element) {
                    texts.append(text)
                }
            }
        }

        guard !Self.shouldSkipChildren(role: role, isEditableInput: isEditableInput) else {
            return
        }

        guard let children = childrenAttribute(kAXChildrenAttribute, from: element) else {
            return
        }

        for child in children {
            collectTexts(from: child, depth: depth + 1, nodeCount: &nodeCount, into: &texts)
        }
    }

    private func collectSelectedTexts(
        from element: AXUIElement,
        depth: Int,
        nodeCount: inout Int,
        into texts: inout [String]
    ) {
        guard depth <= maxDepth, nodeCount < maxNodes else {
            return
        }
        nodeCount += 1

        let role = stringAttribute(kAXRoleAttribute, from: element)
        let isEditableInput = Self.isEditableTextInput(element, role: role)
        if !isEditableInput,
           let selectedText = AXSelectionTextReader.selectedText(from: element),
           !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            texts.append(selectedText)
        }

        guard !Self.shouldSkipChildren(role: role, isEditableInput: isEditableInput),
              let children = childrenAttribute(kAXChildrenAttribute, from: element) else {
            return
        }

        for child in children {
            collectSelectedTexts(from: child, depth: depth + 1, nodeCount: &nodeCount, into: &texts)
        }
    }

    private func normalizedText(_ text: String) -> String? {
        let lines = Self.strippingOCRPrefixes(from: text)
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .components(separatedBy: .newlines)
            .map { line in
                line.components(separatedBy: .whitespaces)
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter {
                !$0.isEmpty && !ResponseLanguageDetector.isSkippableLiteral($0)
            }

        let collapsed = lines
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard collapsed.count >= 24 else {
            return nil
        }

        return collapsed
    }

    private func isSubstantiveText(_ text: String) -> Bool {
        let lowercased = text.lowercased()
        let uiFragments = [
            "prompt translator",
            "translate & send",
            "copy last",
            "applications",
            "accessibility",
            "new chat",
            "attach",
            "upload",
            "settings",
            "english",
            "japanese",
            "view full image",
            "see full image",
            "open image",
            "claude is ai and can make mistakes"
        ]

        if uiFragments.contains(where: { lowercased.hasPrefix($0) }) {
            return false
        }

        if ResponseLanguageDetector.isMostlyCodeOrPaths(text) {
            return false
        }

        if text.count < 70, ResponseLanguageDetector.detect(in: text) == nil {
            return false
        }

        return true
    }

    private func proseCandidate(from text: String) -> String? {
        var keptLines: [String] = []
        var insideFence = false

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)

            if line.hasPrefix("```") {
                insideFence.toggle()
                continue
            }

            guard !insideFence else {
                continue
            }

            if ResponseLanguageDetector.isNonProseContentLine(line) {
                continue
            }

            keptLines.append(rawLine)
        }

        let normalized = keptLines
            .joined(separator: "\n")
            .components(separatedBy: .newlines)
            .map { line in
                line.components(separatedBy: .whitespaces)
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard normalized.count >= 56,
              ResponseLanguageDetector.isLikelyTranslatableProse(normalized) else {
            return nil
        }

        return normalized
    }

    private func isResponseBoundary(_ text: String) -> Bool {
        let lowercased = text.lowercased()
        if lowercased.hasPrefix("you said:")
            || lowercased.hasPrefix("user said:")
            || lowercased.hasPrefix("claude responded:")
            || lowercased.hasPrefix("chatgpt said:")
            || lowercased.hasPrefix("assistant said:") {
            return true
        }

        return [
            "results from the web",
            "write a message",
            "what do you want to figure out today",
            "claude is ai and can make mistakes",
            "new chat",
            "prompt categories"
        ].contains { lowercased.hasPrefix($0) }
    }

    private static func strippingOCRPrefixes(from text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = [
            "Claude responded:",
            "ChatGPT said:",
            "Assistant said:",
            "You said:",
            "User said:"
        ]

        var didStrip = true
        while didStrip {
            didStrip = false
            for prefix in prefixes where result.localizedCaseInsensitiveContains(prefix) {
                let range = result.range(of: prefix, options: [.caseInsensitive])
                guard let range, range.lowerBound == result.startIndex else {
                    continue
                }
                result = String(result[range.upperBound...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                didStrip = true
            }
        }

        return result
    }

    static func leafPreferredDeduplicated(_ texts: [String]) -> [String] {
        var result: [String] = []

        for text in texts {
            if result.contains(text) {
                continue
            }

            let nestedContainerIndexes = result.indices.filter { index in
                result[index].count > text.count
                    && text.count >= 24
                    && result[index].contains(text)
            }
            if !nestedContainerIndexes.isEmpty {
                for index in nestedContainerIndexes.reversed() {
                    result.remove(at: index)
                }
            } else if result.contains(where: { existing in
                text.count > existing.count
                    && existing.count >= 24
                    && text.contains(existing)
            }) {
                continue
            }

            result.append(text)
        }

        return result
    }

    private func stringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var reference: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &reference)
        guard result == .success else {
            return nil
        }
        return reference as? String
    }

    private func elementAttribute(_ attribute: String, from element: AXUIElement) -> AXUIElement? {
        var reference: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &reference)
        guard result == .success, let reference else {
            return nil
        }
        guard CFGetTypeID(reference) == AXUIElementGetTypeID() else {
            return nil
        }
        return (reference as! AXUIElement)
    }

    private func childrenAttribute(_ attribute: String, from element: AXUIElement) -> [AXUIElement]? {
        var reference: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &reference)
        guard result == .success else {
            return nil
        }
        return reference as? [AXUIElement]
    }

    private static func isEditableTextInput(_ element: AXUIElement, role: String?) -> Bool {
        let textInputRoles = [
            kAXTextFieldRole as String,
            kAXTextAreaRole as String,
            kAXComboBoxRole as String
        ]

        guard let role, textInputRoles.contains(role) else {
            return false
        }

        var settable = DarwinBoolean(false)
        let result = AXUIElementIsAttributeSettable(
            element,
            kAXValueAttribute as CFString,
            &settable
        )

        return result != .success || settable.boolValue
    }

    private static func shouldSkipChildren(role: String?, isEditableInput: Bool) -> Bool {
        if isEditableInput {
            return true
        }

        return isInteractiveControl(role: role)
    }

    private static func isInteractiveControl(role: String?) -> Bool {
        let skippedRoles = [
            kAXButtonRole as String,
            kAXMenuRole as String,
            kAXMenuItemRole as String,
            kAXPopUpButtonRole as String,
            kAXCheckBoxRole as String,
            kAXRadioButtonRole as String
        ]

        return role.map(skippedRoles.contains) ?? false
    }
}

actor AIResponseScanWorker {
    private let reader = AIResponseReader()

    func latestForeignResponse(
        processIdentifier: pid_t,
        allowOCR: Bool
    ) async -> DetectedForeignResponse? {
        guard let app = NSRunningApplication(processIdentifier: processIdentifier) else {
            return nil
        }

        return await reader.latestForeignResponse(in: app, allowOCR: allowOCR)
    }

    func selectedForeignResponse(processIdentifier: pid_t) -> DetectedForeignResponse? {
        guard let app = NSRunningApplication(processIdentifier: processIdentifier) else {
            return nil
        }

        return reader.selectedForeignResponse(in: app)
    }
}

enum ResponseLanguageDetector {
    static func isSkippableLiteral(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: { $0.isWhitespace }) else {
            return false
        }

        let patterns = [
            #"^(?:(?:https?|ftp|file)://|www\.)\S+$"#,
            #"^(?:[A-Za-z0-9-]+\.)+[A-Za-z]{2,}(?::\d+)?(?:[/?#]\S*)?$"#,
            #"^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$"#,
            #"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"#,
            #"^v?\d+(?:\.\d+){1,3}$"#,
            #"^\d{4}-\d{2}-\d{2}(?:T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})?)?$"#,
            #"^(?:\{\{[^}]+\}\}|\$\{[^}]+\}|__\w+__|%\w+)$"#,
            #"^(?:#[A-Fa-f0-9]{3}|#[A-Fa-f0-9]{6}|[.#][A-Za-z_][\w-]*)$"#,
            #"^@[\w.-]+$"#,
            #"^&\w+;$"#,
            #"^\[\d+\]$"#,
            #"^\d{1,2}:\d{2}(?::\d{2})?$"#,
            #"^[^\\/:]+\.[A-Za-z0-9]{2,5}$"#
        ]

        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        return patterns.contains { pattern in
            guard let expression = try? NSRegularExpression(pattern: pattern) else {
                return false
            }
            return expression.firstMatch(in: trimmed, range: range) != nil
        }
    }

    static func detect(in text: String) -> DetectedResponseLanguage? {
        guard !isMostlyCodeOrPaths(text), !isMostlyTechnicalOutput(text) else {
            return nil
        }

        let signals = languageSignals(in: text)
        guard signals.letterCount >= 12 else {
            return nil
        }

        if signals.kanaCharacters >= 2 {
            return .japanese
        }

        if signals.cjkCharacters >= 4,
           signals.cjkCharacters * 2 >= max(signals.latinLetters, 1) {
            return nil
        }

        if let hypothesis = naturalLanguageHypotheses(in: text).first {
            let language = DetectedResponseLanguage(identifier: hypothesis.language.rawValue)
            if language.isChinese {
                return nil
            }

            let requiredConfidence = text.count >= 80 ? 0.28 : 0.42
            if hypothesis.confidence >= requiredConfidence {
                if language == .english {
                    let words = text.split { !$0.isLetter }.filter { $0.count >= 2 }
                    guard signals.latinLetters >= 18,
                          signals.latinLetters > signals.cjkCharacters * 2,
                          (hasNaturalEnglishShape(text) || words.count >= 6) else {
                        return nil
                    }
                }
                return language
            }
        }

        let latinRatio = Double(signals.latinLetters) / Double(max(signals.letterCount, 1))
        if signals.latinLetters >= 28,
           latinRatio >= 0.70,
           signals.latinLetters > signals.cjkCharacters * 3,
           hasNaturalEnglishShape(text) {
            return .english
        }

        return nil
    }

    static func detectExplicitSelection(in text: String) -> DetectedResponseLanguage? {
        guard !isMostlyCodeOrPaths(text), !isMostlyTechnicalOutput(text) else {
            return nil
        }

        let signals = languageSignals(in: text)
        guard signals.letterCount >= 2 else {
            return nil
        }

        if signals.kanaCharacters >= 1 {
            return .japanese
        }

        if signals.cjkCharacters >= 4,
           signals.cjkCharacters * 2 >= max(signals.latinLetters, 1) {
            return nil
        }

        if let hypothesis = naturalLanguageHypotheses(in: text).first,
           hypothesis.confidence >= 0.12 {
            let language = DetectedResponseLanguage(identifier: hypothesis.language.rawValue)
            if language.isChinese {
                guard signals.latinLetters > signals.cjkCharacters * 3 else {
                    return nil
                }
            } else {
                return language
            }
        }

        let latinRatio = Double(signals.latinLetters) / Double(max(signals.letterCount, 1))
        if signals.latinLetters >= 2,
           latinRatio >= 0.70,
           signals.latinLetters > signals.cjkCharacters * 3 {
            return .latinScript
        }

        return nil
    }

    private struct LanguageSignals {
        var latinLetters = 0
        var kanaCharacters = 0
        var cjkCharacters = 0
        var letterCount = 0
    }

    private static func languageSignals(in text: String) -> LanguageSignals {
        var signals = LanguageSignals()
        for scalar in text.unicodeScalars {
            let value = scalar.value
            if (65...90).contains(value) || (97...122).contains(value) {
                signals.latinLetters += 1
                signals.letterCount += 1
            } else if (0x3040...0x30ff).contains(value) || (0xff66...0xff9f).contains(value) {
                signals.kanaCharacters += 1
                signals.letterCount += 1
            } else if (0x4e00...0x9fff).contains(value) {
                signals.cjkCharacters += 1
                signals.letterCount += 1
            } else if CharacterSet.letters.contains(scalar) {
                signals.letterCount += 1
            }
        }
        return signals
    }

    private static func naturalLanguageHypotheses(
        in text: String,
        maximum: Int = 4
    ) -> [(language: NLLanguage, confidence: Double)] {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.languageHypotheses(withMaximum: maximum)
            .filter { $0.key != .undetermined }
            .map { (language: $0.key, confidence: $0.value) }
            .sorted { lhs, rhs in lhs.confidence > rhs.confidence }
    }

    static func isMostlyCodeOrPaths(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return false
        }

        let lowercased = trimmed.lowercased()
        let lines = trimmed
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if lines.count == 1 {
            return isCodeOrPathLine(lines[0])
        }

        let codeLineCount = lines.filter(isCodeOrPathLine(_:)).count
        if codeLineCount >= 2, Double(codeLineCount) / Double(lines.count) >= 0.42 {
            return true
        }

        let extensionHits = codeFileExtensions.filter { lowercased.contains($0) }.count
        let slashCount = lowercased.reduce(0) { count, character in
            count + (character == "/" || character == "\\" ? 1 : 0)
        }
        if extensionHits >= 2, slashCount >= 2 {
            return true
        }

        let compact = trimmed.filter { !$0.isWhitespace }
        guard !compact.isEmpty else {
            return false
        }

        let symbolCount = compact.reduce(0) { count, character in
            count + (codeSymbols.contains(character) ? 1 : 0)
        }
        return compact.count >= 120 && Double(symbolCount) / Double(compact.count) >= 0.24
    }

    static func isMostlyTechnicalOutput(_ text: String) -> Bool {
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !lines.isEmpty else {
            return false
        }

        if lines.count == 1 {
            return isTechnicalOutputLine(lines[0])
        }

        let technicalCount = lines.filter(isTechnicalOutputLine(_:)).count
        if technicalCount >= 3, Double(technicalCount) / Double(lines.count) >= 0.35 {
            return true
        }

        let buildLogTerms = [
            "swiftcompile",
            "swiftdriver",
            "codesign",
            "xcodebuild",
            "build succeeded",
            "test suite",
            "test case",
            "clang-stat-cache",
            "appintentsmetadataprocessor"
        ]
        let lowercased = text.lowercased()
        let buildLogHits = buildLogTerms.filter { lowercased.contains($0) }.count
        return buildLogHits >= 3
    }

    static func isLikelyTranslatableProse(_ text: String) -> Bool {
        guard !isMostlyCodeOrPaths(text), !isMostlyTechnicalOutput(text) else {
            return false
        }

        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !lines.isEmpty else {
            return false
        }

        let proseLines = lines.filter { !isNonProseContentLine($0) && hasReadableLetters($0) }
        if lines.count >= 3,
           Double(proseLines.count) / Double(lines.count) < 0.56 {
            return false
        }

        let compact = text.filter { !$0.isWhitespace }
        guard compact.count >= 40 else {
            return false
        }

        let symbolCount = compact.reduce(0) { count, character in
            count + (codeSymbols.contains(character) ? 1 : 0)
        }
        return Double(symbolCount) / Double(compact.count) < 0.20
    }

    static func isNonProseContentLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return true
        }

        if isCodeOrPathLine(trimmed) || isTechnicalOutputLine(trimmed) {
            return true
        }

        if trimmed.hasPrefix("|") || trimmed.contains(" | ") || trimmed.contains("\t") {
            return true
        }

        if trimmed.hasPrefix("![") || trimmed.hasPrefix("<") || trimmed.hasPrefix("{") {
            return true
        }

        if trimmed.range(of: #"^[-*+]\s+\[[ xX]\]"#, options: .regularExpression) != nil {
            return true
        }

        let compact = trimmed.filter { !$0.isWhitespace }
        guard compact.count >= 16 else {
            return false
        }

        let symbolCount = compact.reduce(0) { count, character in
            count + (codeSymbols.contains(character) ? 1 : 0)
        }
        let hasSentencePunctuation = trimmed.contains(". ") || trimmed.contains("。") || trimmed.contains("! ") || trimmed.contains("? ")
        return Double(symbolCount) / Double(compact.count) >= 0.26 && !hasSentencePunctuation
    }

    static func isCodeOrPathLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return false
        }

        let lowercased = trimmed.lowercased()
        if lowercased.hasPrefix("```") {
            return true
        }

        if strictCodeLinePrefixes.contains(where: { lowercased.hasPrefix($0) }) {
            return true
        }

        if declarationCodePrefixes.contains(where: { lowercased.hasPrefix($0) }),
           hasCodeSyntax(trimmed) {
            return true
        }

        if codeFileExtensions.contains(where: { lowercased.contains($0) }) {
            if lowercased.contains("/") || lowercased.contains("\\") || lowercased.contains("sources/") {
                return true
            }
            if lowercased.split(separator: " ").count <= 3 {
                return true
            }
        }

        let slashCount = lowercased.reduce(0) { count, character in
            count + (character == "/" || character == "\\" ? 1 : 0)
        }
        if slashCount >= 2, !lowercased.contains(" ") {
            return true
        }

        let symbolCount = trimmed.reduce(0) { count, character in
            count + (codeSymbols.contains(character) ? 1 : 0)
        }
        if trimmed.count >= 24, symbolCount >= 5, !trimmed.contains(". ") {
            return true
        }

        return false
    }

    private static func isTechnicalOutputLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return false
        }

        let lowercased = trimmed.lowercased()
        if isCodeOrPathLine(trimmed) {
            return true
        }

        if technicalLinePrefixes.contains(where: { lowercased.hasPrefix($0) }) {
            return true
        }

        if lowercased.hasPrefix("["),
           lowercased.contains("/"),
           lowercased.contains("]") {
            return true
        }

        if lowercased.contains(" in target '")
            || lowercased.contains(" from project '")
            || lowercased.contains(" objects-normal/")
            || lowercased.contains("deriveddata/")
            || lowercased.contains(".build/")
            || lowercased.contains("contents/macos/")
            || lowercased.contains("process exited with code") {
            return true
        }

        if trimmed.hasPrefix("*** ") || trimmed.hasPrefix("@@") || trimmed.hasPrefix("+") || trimmed.hasPrefix("-") {
            return true
        }

        return false
    }

    private static func hasNaturalEnglishShape(_ text: String) -> Bool {
        let words = text
            .lowercased()
            .split { !$0.isLetter }
            .map(String.init)
            .filter { $0.count >= 2 }

        guard words.count >= 14 else {
            return false
        }

        let commonWordHits = words.filter(commonEnglishWords.contains(_:)).count
        if commonWordHits >= 5 {
            return true
        }

        let sentenceEnders = text.filter { ".!?".contains($0) }.count
        return sentenceEnders >= 2 && words.count >= 24
    }

    private static func hasReadableLetters(_ text: String) -> Bool {
        let letters = text.unicodeScalars.filter { scalar in
            CharacterSet.letters.contains(scalar)
        }.count
        return letters >= 12
    }

    private static func hasCodeSyntax(_ text: String) -> Bool {
        text.contains("=")
            || text.contains("{")
            || text.contains("}")
            || text.contains("(")
            || text.contains(")")
            || text.contains(":")
            || text.contains("->")
            || text.contains("?")
    }

    private static let codeFileExtensions = [
        ".swift", ".m", ".mm", ".h", ".ts", ".tsx", ".js", ".jsx",
        ".py", ".rb", ".go", ".rs", ".java", ".kt", ".cpp", ".c",
        ".cs", ".php", ".html", ".css", ".json", ".yaml", ".yml",
        ".toml", ".plist", ".md"
    ]

    private static let strictCodeLinePrefixes = [
        "import ", "#include", "@main", "@objc", "func ", "def ",
        "final class ", "final struct ", "final actor "
    ]

    private static let declarationCodePrefixes = [
        "let ", "var ", "class ", "struct ", "enum ", "extension ",
        "private ", "public ", "internal ", "static ", "return ", "guard ",
        "@main", "@objc", "#include", "def ", "const ", "export "
    ]

    private static let technicalLinePrefixes = [
        "command line invocation:",
        "building for ",
        "build complete",
        "test suite ",
        "test case ",
        "swiftcompile ",
        "swiftdriver ",
        "swiftemitmodule ",
        "ld ",
        "codesign ",
        "copy ",
        "copyswiftlibs ",
        "processinfoplistfile ",
        "extractappintentsmetadata ",
        "clangstatcache ",
        "writeauxiliaryfile ",
        "executeexternaltool ",
        "registerwithlaunchservices ",
        "validate ",
        "note:",
        "warning:",
        "error:",
        "hdiutil:",
        "pgrep ",
        "osascript ",
        "xcodebuild ",
        "swift test",
        "swift build",
        "git ",
        "rg ",
        "sed ",
        "cd ",
        "/users/",
        "/applications/",
        "/usr/bin/",
        "/bin/",
        "** build succeeded **"
    ]

    private static let commonEnglishWords: Set<String> = [
        "the", "and", "you", "that", "this", "with", "for", "from",
        "your", "are", "can", "will", "would", "should", "have", "has",
        "not", "but", "when", "what", "how", "into", "there", "their",
        "about", "because", "response", "translation", "content", "output"
    ]

    private static let codeSymbols = Set<Character>("{}[]();=<>/\\|`")
}
