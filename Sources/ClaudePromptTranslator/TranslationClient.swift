import Foundation
import NaturalLanguage
#if canImport(Translation)
import Translation
#endif

enum TranslationError: LocalizedError {
    case invalidResponse
    case serverStatus(code: Int, retryAfter: TimeInterval?)
    case emptyTranslation
    case timeout
    case inputTooLong(limit: Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "The translation service returned an unexpected response."
        case .serverStatus(let code, _):
            return "The translation service returned HTTP \(code)."
        case .emptyTranslation:
            return "The translation service returned an empty translation."
        case .timeout:
            return "The translation service timed out. Please try again."
        case .inputTooLong(let limit):
            return "The selected text is longer than the supported \(limit) characters."
        }
    }
}

struct TranslationProviderOutput: Equatable, Sendable {
    let text: String
    let providerName: String
}

protocol TextTranslationProvider: Sendable {
    var providerName: String { get }

    func translateText(
        _ text: String,
        targetLanguageCode: String,
        maximumCharacters: Int
    ) async throws -> String
}

enum TranslationProviderUnavailableError: LocalizedError {
    case languageCouldNotBeDetermined
    case languagePairNotInstalled
    case unsupportedLanguagePair
    case localOnlyModeUnsupported

    var errorDescription: String? {
        switch self {
        case .languageCouldNotBeDetermined:
            return "无法确定本地翻译所需的源语言。"
        case .languagePairNotInstalled:
            return "Apple 本地翻译语言包尚未安装。"
        case .unsupportedLanguagePair:
            return "Apple 本地翻译暂不支持这个语言组合。"
        case .localOnlyModeUnsupported:
            return "当前处于仅本地翻译模式；Apple 不支持此语言组合，原文未发送到网络。"
        }
    }
}

#if canImport(Translation)
@available(macOS 26.0, *)
struct InstalledAppleTranslateClient: Sendable {
    func translateText(
        _ text: String,
        sourceLanguage: Locale.Language,
        targetLanguageCode: String,
        maximumCharacters: Int
    ) async throws -> String {
        guard text.count <= maximumCharacters else {
            throw TranslationError.inputTooLong(limit: maximumCharacters)
        }

        let target = Locale.Language(identifier: targetLanguageCode)
        let availability = LanguageAvailability()
        guard await availability.status(from: sourceLanguage, to: target) == .installed else {
            throw TranslationProviderUnavailableError.languagePairNotInstalled
        }

        let session = TranslationSession(installedSource: sourceLanguage, target: target)
        var isReady = await session.isReady
        // On a cold launch macOS can report the pair as installed a fraction
        // of a second before the headless session becomes ready. Keep this
        // bounded and local-only: a genuinely missing model still fails after
        // three short checks and is never routed to a network provider.
        for delay in [150_000_000, 350_000_000] where !isReady {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: UInt64(delay))
            isReady = await session.isReady
        }
        guard isReady else {
            throw TranslationProviderUnavailableError.languagePairNotInstalled
        }

        var translated = ""
        for chunk in TranslationChunker.chunks(for: text) {
            try Task.checkCancellation()
            if chunk.shouldTranslate {
                translated += try await session.translate(chunk.text).targetText
            } else {
                translated += chunk.text
            }
        }

        guard !translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TranslationError.emptyTranslation
        }
        return translated
    }
}
#endif

enum TranslationLimits {
    /// Accessibility and clipboard fallback limit for a prompt typed in an AI app.
    static let maxInputCharacters = 160_000

    /// Maximum amount of the latest AI reply collected for automatic translation.
    static let maxResponseCharacters = 96_000

    /// Explicitly selected OCR regions may contain dense documents, but remain bounded.
    static let maxOCRCharacters = 60_000

    /// Keep individual requests small enough for the query-based translation endpoint.
    static let maxRequestCharacters = 3_000
}

struct TranslationChunk: Equatable, Sendable {
    let text: String
    let shouldTranslate: Bool
}

enum TranslationChunker {
    static func languageDetectionProjection(
        for text: String,
        maximumCharacters: Int = 4_000
    ) -> String {
        let prose = chunks(for: text)
            .filter(\.shouldTranslate)
            .map(\.text)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard maximumCharacters > 0 else { return "" }
        return String(prose.prefix(maximumCharacters))
    }

    static func chunks(
        for text: String,
        maxChunkLength: Int = TranslationLimits.maxRequestCharacters
    ) -> [TranslationChunk] {
        guard !text.isEmpty, maxChunkLength > 0 else {
            return text.isEmpty ? [] : [TranslationChunk(text: text, shouldTranslate: true)]
        }

        var sections: [TranslationChunk] = []
        var buffer = ""
        var insideFence = false
        var fenceMarker = ""
        let lines = text.components(separatedBy: "\n")

        func flushBuffer(shouldTranslate: Bool) {
            guard !buffer.isEmpty else { return }
            sections.append(TranslationChunk(text: buffer, shouldTranslate: shouldTranslate))
            buffer = ""
        }

        for (index, line) in lines.enumerated() {
            let renderedLine = line + (index == lines.count - 1 ? "" : "\n")
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let marker: String? = {
                if trimmed.hasPrefix("```") { return "```" }
                if trimmed.hasPrefix("~~~") { return "~~~" }
                if trimmed == "$$" { return "$$" }
                return nil
            }()

            if insideFence {
                buffer += renderedLine
                if marker == fenceMarker {
                    flushBuffer(shouldTranslate: false)
                    insideFence = false
                    fenceMarker = ""
                }
            } else if let marker {
                flushBuffer(shouldTranslate: true)
                insideFence = true
                fenceMarker = marker
                buffer = renderedLine
            } else if isMarkdownStructureOnlyLine(trimmed) {
                flushBuffer(shouldTranslate: true)
                sections.append(TranslationChunk(text: renderedLine, shouldTranslate: false))
            } else {
                buffer += renderedLine
            }
        }

        flushBuffer(shouldTranslate: !insideFence)

        return sections.flatMap { section in
            guard section.shouldTranslate else { return [section] }
            return splitTranslatable(section.text, maxChunkLength: maxChunkLength)
        }
    }

    private static func splitTranslatable(_ text: String, maxChunkLength: Int) -> [TranslationChunk] {
        splitProtectedInlineContent(text).flatMap { chunk in
            guard chunk.shouldTranslate else {
                return [chunk]
            }
            return splitByLength(chunk.text, maxChunkLength: maxChunkLength)
        }
    }

    private static func splitByLength(_ text: String, maxChunkLength: Int) -> [TranslationChunk] {
        var output: [TranslationChunk] = []
        var remainder = text[...]

        while remainder.count > maxChunkLength {
            let hardEnd = remainder.index(remainder.startIndex, offsetBy: maxChunkLength)
            let preferredEnd = preferredSplit(in: remainder, hardEnd: hardEnd, maxChunkLength: maxChunkLength)
            appendPreservingWhitespace(String(remainder[..<preferredEnd]), to: &output)
            remainder = remainder[preferredEnd...]
        }

        appendPreservingWhitespace(String(remainder), to: &output)
        return output
    }

    private static func splitProtectedInlineContent(_ text: String) -> [TranslationChunk] {
        var output: [TranslationChunk] = []
        var cursor = text.startIndex

        while cursor < text.endIndex {
            guard let protectedRange = nextProtectedInlineRange(in: text, from: cursor) else {
                output.append(TranslationChunk(text: String(text[cursor...]), shouldTranslate: true))
                break
            }

            if cursor < protectedRange.lowerBound {
                output.append(
                    TranslationChunk(
                        text: String(text[cursor..<protectedRange.lowerBound]),
                        shouldTranslate: true
                    )
                )
            }

            output.append(
                TranslationChunk(text: String(text[protectedRange]), shouldTranslate: false)
            )
            cursor = protectedRange.upperBound
        }

        return mergeAdjacentChunks(output)
    }

    private static func nextProtectedInlineRange(
        in text: String,
        from start: String.Index
    ) -> Range<String.Index>? {
        [
            nextBacktickRange(in: text, from: start),
            nextURLRange(in: text, from: start),
            nextMarkdownDestinationRange(in: text, from: start),
            nextHTMLTagRange(in: text, from: start),
            nextDelimitedRange(in: text, from: start, opening: "$$", closing: "$$"),
            nextDelimitedRange(in: text, from: start, opening: "$", closing: "$"),
            nextDelimitedRange(in: text, from: start, opening: "\\(", closing: "\\)"),
            nextDelimitedRange(in: text, from: start, opening: "\\[", closing: "\\]")
        ]
        .compactMap { $0 }
        .min { $0.lowerBound < $1.lowerBound }
    }

    private static func nextBacktickRange(
        in text: String,
        from start: String.Index
    ) -> Range<String.Index>? {
        guard let opening = text.range(of: "`", range: start..<text.endIndex) else {
            return nil
        }

        var markerEnd = opening.lowerBound
        while markerEnd < text.endIndex, text[markerEnd] == "`" {
            markerEnd = text.index(after: markerEnd)
        }
        let marker = String(text[opening.lowerBound..<markerEnd])
        guard let closing = text.range(of: marker, range: markerEnd..<text.endIndex) else {
            return nil
        }
        return opening.lowerBound..<closing.upperBound
    }

    private static func nextURLRange(
        in text: String,
        from start: String.Index
    ) -> Range<String.Index>? {
        let searchRange = start..<text.endIndex
        let urlStart = [
            text.range(of: "https://", options: [.caseInsensitive], range: searchRange)?.lowerBound,
            text.range(of: "http://", options: [.caseInsensitive], range: searchRange)?.lowerBound
        ]
        .compactMap { $0 }
        .min()
        guard let urlStart else { return nil }

        var end = urlStart
        while end < text.endIndex,
              !text[end].isWhitespace,
              !"<>\"'".contains(text[end]) {
            end = text.index(after: end)
        }
        while end > urlStart {
            let previous = text.index(before: end)
            guard ".,;:!?)]}".contains(text[previous]) else { break }
            end = previous
        }
        return urlStart..<end
    }

    private static func nextMarkdownDestinationRange(
        in text: String,
        from start: String.Index
    ) -> Range<String.Index>? {
        guard let marker = text.range(of: "](", range: start..<text.endIndex) else {
            return nil
        }
        let opening = text.index(after: marker.lowerBound)
        var cursor = opening
        var depth = 0
        while cursor < text.endIndex {
            if text[cursor] == "(" {
                depth += 1
            } else if text[cursor] == ")" {
                depth -= 1
                if depth == 0 {
                    return opening..<text.index(after: cursor)
                }
            }
            cursor = text.index(after: cursor)
        }
        return nil
    }

    private static func nextHTMLTagRange(
        in text: String,
        from start: String.Index
    ) -> Range<String.Index>? {
        var searchStart = start
        while let opening = text.range(of: "<", range: searchStart..<text.endIndex) {
            let contentStart = opening.upperBound
            guard contentStart < text.endIndex else { return nil }
            let first = text[contentStart]
            let looksLikeTag = first.isLetter || "/!?".contains(first)
            if looksLikeTag,
               let closing = text.range(of: ">", range: contentStart..<text.endIndex),
               text.distance(from: contentStart, to: closing.lowerBound) <= 512 {
                return opening.lowerBound..<closing.upperBound
            }
            searchStart = contentStart
        }
        return nil
    }

    private static func nextDelimitedRange(
        in text: String,
        from start: String.Index,
        opening: String,
        closing: String
    ) -> Range<String.Index>? {
        guard let openingRange = text.range(of: opening, range: start..<text.endIndex),
              let closingRange = text.range(
                of: closing,
                range: openingRange.upperBound..<text.endIndex
              ),
              openingRange.upperBound < closingRange.lowerBound else {
            return nil
        }
        return openingRange.lowerBound..<closingRange.upperBound
    }

    private static func isMarkdownStructureOnlyLine(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }

        let compact = text.filter { !$0.isWhitespace }
        if compact.count >= 3,
           let first = compact.first,
           "-*_".contains(first),
           compact.allSatisfy({ $0 == first }) {
            return true
        }

        guard text.contains("|") else { return false }
        let cells = text.split(separator: "|", omittingEmptySubsequences: true)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            let delimiter = cell.filter { !$0.isWhitespace && $0 != ":" }
            return delimiter.count >= 3 && delimiter.allSatisfy { $0 == "-" }
        }
    }

    private static func mergeAdjacentChunks(_ chunks: [TranslationChunk]) -> [TranslationChunk] {
        chunks.reduce(into: []) { result, chunk in
            guard !chunk.text.isEmpty else {
                return
            }
            if let last = result.last, last.shouldTranslate == chunk.shouldTranslate {
                result[result.count - 1] = TranslationChunk(
                    text: last.text + chunk.text,
                    shouldTranslate: chunk.shouldTranslate
                )
            } else {
                result.append(chunk)
            }
        }
    }

    private static func preferredSplit(
        in text: Substring,
        hardEnd: String.Index,
        maxChunkLength: Int
    ) -> String.Index {
        let minimumOffset = max(maxChunkLength / 2, 1)
        let minimum = text.index(text.startIndex, offsetBy: minimumOffset, limitedBy: hardEnd)
            ?? text.startIndex
        var index = hardEnd

        while index > minimum {
            let previous = text.index(before: index)
            let character = text[previous]
            if "\n。！？.!?；;".contains(character) {
                return index
            }
            if character.isWhitespace {
                return previous == text.startIndex ? index : previous
            }
            index = previous
        }

        return hardEnd
    }

    private static func appendPreservingWhitespace(
        _ text: String,
        to output: inout [TranslationChunk]
    ) {
        guard !text.isEmpty else { return }
        let leadingEnd = text.firstIndex { !$0.isWhitespace } ?? text.endIndex
        if leadingEnd == text.endIndex {
            output.append(TranslationChunk(text: text, shouldTranslate: false))
            return
        }
        let trailingStart = text[..<text.endIndex].lastIndex { !$0.isWhitespace }
            .map { text.index(after: $0) } ?? text.startIndex

        if leadingEnd > text.startIndex {
            output.append(TranslationChunk(text: String(text[..<leadingEnd]), shouldTranslate: false))
        }

        if leadingEnd < trailingStart {
            output.append(TranslationChunk(text: String(text[leadingEnd..<trailingStart]), shouldTranslate: true))
        }

        if trailingStart < text.endIndex {
            output.append(TranslationChunk(text: String(text[trailingStart...]), shouldTranslate: false))
        }
    }
}

#if DEBUG
// The legacy network compatibility provider is retained only for request-
// construction unit tests. It is deliberately excluded from Release builds,
// so the production app has no code path that can upload translation text.
actor TranslationRequestGate {
    static let shared = TranslationRequestGate(limit: 3)

    private let limit: Int
    private var activeRequests = 0

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    func acquire() async throws {
        while activeRequests >= limit {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        try Task.checkCancellation()
        activeRequests += 1
    }

    func release() {
        activeRequests = max(0, activeRequests - 1)
    }
}

struct GoogleTranslateClient: Sendable {
    private static let sharedSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpCookieStorage = nil
        return URLSession(configuration: config)
    }()

    private static let maxRetries = 3
    private static let retryBaseDelay: UInt64 = 800_000_000 // 0.8s
    private static let maxConcurrentRequests = 3

    private let session: URLSession

    init(session: URLSession = Self.sharedSession) {
        self.session = session
    }

    func translate(_ text: String, to targetLanguage: TargetLanguage) async throws -> String {
        guard text.count <= TranslationLimits.maxInputCharacters else {
            throw TranslationError.inputTooLong(limit: TranslationLimits.maxInputCharacters)
        }
        let rawTranslation = try await translatePreservingStructure(
            text,
            toLanguageCode: targetLanguage.googleLanguageCode
        )
        return PromptTranslationPolisher.polish(
            rawTranslation,
            source: text,
            targetLanguage: targetLanguage
        )
    }

    func translateToChinese(_ text: String) async throws -> String {
        guard text.count <= TranslationLimits.maxResponseCharacters else {
            throw TranslationError.inputTooLong(limit: TranslationLimits.maxResponseCharacters)
        }
        return try await translatePreservingStructure(text, toLanguageCode: "zh-CN")
    }

    private func translatePreservingStructure(
        _ text: String,
        toLanguageCode languageCode: String
    ) async throws -> String {
        let chunks = TranslationChunker.chunks(for: text)
        var translatedChunks = Array<String?>(repeating: nil, count: chunks.count)
        let translatableIndexes = chunks.indices.filter { chunks[$0].shouldTranslate }

        try await withThrowingTaskGroup(of: (Int, String).self) { group in
            var nextPosition = 0
            let initialCount = min(Self.maxConcurrentRequests, translatableIndexes.count)

            for _ in 0..<initialCount {
                let index = translatableIndexes[nextPosition]
                nextPosition += 1
                let chunkText = chunks[index].text
                group.addTask {
                    (index, try await translateWithRetry(chunkText, toLanguageCode: languageCode))
                }
            }

            while let (index, translation) = try await group.next() {
                translatedChunks[index] = translation

                if nextPosition < translatableIndexes.count {
                    let nextIndex = translatableIndexes[nextPosition]
                    nextPosition += 1
                    let chunkText = chunks[nextIndex].text
                    group.addTask {
                        (nextIndex, try await translateWithRetry(chunkText, toLanguageCode: languageCode))
                    }
                }
            }
        }

        let translated = chunks.enumerated().map { index, chunk in
            chunk.shouldTranslate ? (translatedChunks[index] ?? "") : chunk.text
        }.joined()

        guard !translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TranslationError.emptyTranslation
        }
        return translated
    }

    private func translateWithRetry(_ text: String, toLanguageCode languageCode: String) async throws -> String {
        var lastError: Error?

        for attempt in 0..<Self.maxRetries {
            try Task.checkCancellation()
            do {
                return try await translate(text, toLanguageCode: languageCode)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                guard attempt < Self.maxRetries - 1, Self.isRetryable(error) else {
                    throw error
                }

                let exponentialDelay = Self.retryBaseDelay * UInt64(1 << attempt)
                let retryAfter = Self.retryAfterNanoseconds(from: error)
                let jitter = UInt64.random(in: 0...250_000_000)
                try await Task.sleep(nanoseconds: max(exponentialDelay, retryAfter) + jitter)
            }
        }

        throw lastError ?? TranslationError.invalidResponse
    }

    private func translate(_ text: String, toLanguageCode languageCode: String) async throws -> String {
        guard let url = URL(string: "https://translate.googleapis.com/translate_a/single") else {
            throw TranslationError.invalidResponse
        }

        let formItems = [
            URLQueryItem(name: "client", value: "gtx"),
            URLQueryItem(name: "sl", value: "auto"),
            URLQueryItem(name: "tl", value: languageCode),
            URLQueryItem(name: "dt", value: "t"),
            URLQueryItem(name: "q", value: text)
        ]
        var formComponents = URLComponents()
        formComponents.queryItems = formItems
        guard let body = formComponents.percentEncodedQuery?.data(using: .utf8) else {
            throw TranslationError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        try await TranslationRequestGate.shared.acquire()
        do {
            (data, response) = try await session.data(for: request)
            await TranslationRequestGate.shared.release()
        } catch let error as URLError where error.code == .timedOut {
            await TranslationRequestGate.shared.release()
            throw TranslationError.timeout
        } catch {
            await TranslationRequestGate.shared.release()
            if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            throw error
        }
        if let httpResponse = response as? HTTPURLResponse, !(200..<300).contains(httpResponse.statusCode) {
            throw TranslationError.serverStatus(
                code: httpResponse.statusCode,
                retryAfter: Self.retryAfter(from: httpResponse)
            )
        }

        return try Self.parseTranslation(from: data)
    }

    private static func isRetryable(_ error: Error) -> Bool {
        if let error = error as? TranslationError {
            switch error {
            case .timeout:
                return true
            case .serverStatus(let code, _):
                // A rate limit is not likely to recover within an interactive
                // click. Fail fast so the UI does not appear stuck retrying.
                return code == 408 || (500...599).contains(code)
            default:
                return false
            }
        }

        if let error = error as? URLError {
            return [
                .timedOut,
                .cannotConnectToHost,
                .networkConnectionLost,
                .notConnectedToInternet,
                .dnsLookupFailed
            ].contains(error.code)
        }

        return false
    }

    private static func retryAfter(from response: HTTPURLResponse) -> TimeInterval? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After") else {
            return nil
        }
        if let seconds = TimeInterval(value) {
            return max(0, min(seconds, 30))
        }
        return nil
    }

    private static func retryAfterNanoseconds(from error: Error) -> UInt64 {
        guard case .serverStatus(_, let retryAfter) = error as? TranslationError,
              let retryAfter else {
            return 0
        }
        return UInt64(retryAfter * 1_000_000_000)
    }

    static func parseTranslation(from data: Data) throws -> String {
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [Any],
            let segments = root.first as? [Any]
        else {
            throw TranslationError.invalidResponse
        }

        let translated = segments.compactMap { segment -> String? in
            guard let segmentArray = segment as? [Any] else {
                return nil
            }
            return segmentArray.first as? String
        }
        .joined()
        .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !translated.isEmpty else {
            throw TranslationError.emptyTranslation
        }

        return translated
    }
}

extension GoogleTranslateClient: TextTranslationProvider {
    var providerName: String { "Google 翻译" }

    func translateText(
        _ text: String,
        targetLanguageCode: String,
        maximumCharacters: Int
    ) async throws -> String {
        guard text.count <= maximumCharacters else {
            throw TranslationError.inputTooLong(limit: maximumCharacters)
        }
        return try await translatePreservingStructure(
            text,
            toLanguageCode: targetLanguageCode
        )
    }
}
#endif

struct AutomaticTranslationClient: Sendable {
    func translate(
        _ text: String,
        to targetLanguage: TargetLanguage
    ) async throws -> TranslationProviderOutput {
#if canImport(Translation)
        if #available(macOS 15.0, *) {
            do {
                let translated = try await AppleTranslationCoordinator.shared.translateText(
                    text,
                    targetLanguageCode: targetLanguage.appleLanguageCode,
                    maximumCharacters: TranslationLimits.maxInputCharacters
                )
                return TranslationProviderOutput(
                    text: PromptTranslationPolisher.polish(
                        translated,
                        source: text,
                        targetLanguage: targetLanguage
                    ),
                    providerName: "Apple 本地翻译"
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as TranslationProviderUnavailableError {
                guard case .unsupportedLanguagePair = error else {
                    throw error
                }
            } catch {
                // A supported Apple pairing should not silently upload the
                // selection to another service if setup or translation fails.
                throw error
            }
        }
#endif

        throw TranslationProviderUnavailableError.localOnlyModeUnsupported
    }

    func translateToChinese(_ text: String) async throws -> TranslationProviderOutput {
#if canImport(Translation)
        if #available(macOS 15.0, *) {
            do {
                let translated = try await AppleTranslationCoordinator.shared.translateText(
                    text,
                    targetLanguageCode: "zh-Hans",
                    maximumCharacters: TranslationLimits.maxResponseCharacters
                )
                return TranslationProviderOutput(
                    text: translated,
                    providerName: "Apple 本地翻译"
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as TranslationProviderUnavailableError {
                guard case .unsupportedLanguagePair = error else {
                    throw error
                }
            } catch {
                throw error
            }
        }
#endif

        throw TranslationProviderUnavailableError.localOnlyModeUnsupported
    }
}

enum PromptTranslationPolisher {
    static func polish(_ translation: String, source: String, targetLanguage: TargetLanguage) -> String {
        let translationParts = edgeWhitespaceParts(in: translation)
        let sourceCore = edgeWhitespaceParts(in: source).core
        let normalized = normalizeSpacingPreservingLayout(in: translationParts.core)

        let polishedCore: String
        switch targetLanguage {
        case .simplifiedChinese:
            polishedCore = normalized
        case .english:
            polishedCore = polishEnglish(normalized, source: sourceCore)
        case .japanese:
            polishedCore = polishJapanese(normalized)
        }
        return translationParts.leading + polishedCore + translationParts.trailing
    }

    private static func polishEnglish(_ translation: String, source: String) -> String {
        var result = translation

        let replacements = [
            ("Please help me ", "Please "),
            ("please help me ", "please "),
            ("Can you help me ", "Could you "),
            ("can you help me ", "could you "),
            ("Could you help me ", "Could you "),
            ("could you help me ", "could you "),
            ("Help me ", "Please "),
            ("help me ", "please ")
        ]

        for (awkward, natural) in replacements {
            if result.hasPrefix(awkward) {
                result = natural + result.dropFirst(awkward.count)
            }
        }

        result = normalizeSpacingPreservingLayout(in: result)
        return shouldAddSentenceEnding(to: result, source: source)
            ? ensureSentenceEnding(result)
            : result
    }

    private static func polishJapanese(_ translation: String) -> String {
        var result = translation
        let replacements = [
            ("私を助けて", ""),
            ("手伝ってください、", ""),
            ("手伝ってください。", "")
        ]

        for (awkward, natural) in replacements {
            if result.hasPrefix(awkward) {
                result = natural + result.dropFirst(awkward.count)
            }
        }

        result = normalizeSpacingPreservingLayout(in: result)
        return result.contains("\n") ? result : ensureSentenceEnding(result)
    }

    private static func normalizeSpacingPreservingLayout(in text: String) -> String {
        let normalizedNewlines = text.replacingOccurrences(of: "\r\n", with: "\n")
        let chunks = TranslationChunker.chunks(
            for: normalizedNewlines,
            maxChunkLength: max(normalizedNewlines.count, 1)
        )
        return chunks.map { chunk in
            guard chunk.shouldTranslate else {
                return chunk.text
            }
            return chunk.text.replacingOccurrences(
                of: "[ \\t]+([,.?!])",
                with: "$1",
                options: .regularExpression
            )
        }
        .joined()
    }

    private static func edgeWhitespaceParts(
        in text: String
    ) -> (leading: String, core: String, trailing: String) {
        let coreStart = text.firstIndex { !$0.isWhitespace } ?? text.endIndex
        guard coreStart < text.endIndex else {
            return (text, "", "")
        }
        let coreEnd = text.lastIndex { !$0.isWhitespace }
            .map { text.index(after: $0) } ?? coreStart
        return (
            String(text[..<coreStart]),
            String(text[coreStart..<coreEnd]),
            String(text[coreEnd...])
        )
    }

    private static func shouldAddSentenceEnding(to translation: String, source: String) -> Bool {
        guard !translation.contains("\n"), !source.contains("\n") else {
            return false
        }
        let trimmed = translation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, let last = trimmed.last else {
            return false
        }
        if "#*-+>|{[".contains(first) || "}])`".contains(last) {
            return false
        }
        return true
    }

    private static func ensureSentenceEnding(_ text: String) -> String {
        guard let last = text.last else {
            return text
        }

        if ".?!。！？".contains(last) {
            return text
        }

        return text + "."
    }

}
