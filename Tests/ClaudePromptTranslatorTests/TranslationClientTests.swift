import AppKit
import ApplicationServices
import XCTest
@testable import ClaudePromptTranslator

final class TranslationClientTests: XCTestCase {
    func testAppThemeExposesClaudeAndCyberpunkChoicesWithLegacyMigration() {
        XCTAssertTrue(AppTheme.allCases.contains(.claude))
        XCTAssertTrue(AppTheme.allCases.contains(.dark))
        XCTAssertTrue(AppTheme.allCases.contains(.cyberpunk))
        XCTAssertEqual(AppTheme(rawValue: "tokyoBlue"), .cyberpunk)
        XCTAssertEqual(AppTheme.claude.preferredColorScheme, .light)
        XCTAssertEqual(AppTheme.cyberpunk.preferredColorScheme, .dark)
        XCTAssertEqual(AppTheme.cyberpunk.displayName, "赛博霓虹")
    }

    func testAutomaticBrowserAIContextRequiresKnownHost() throws {
        XCTAssertTrue(
            ClaudeContextDetector.isKnownAIWebURL(
                try XCTUnwrap(URL(string: "https://chatgpt.com/c/example"))
            )
        )
        XCTAssertTrue(
            ClaudeContextDetector.isKnownAIWebURL(
                try XCTUnwrap(URL(string: "https://claude.ai/new"))
            )
        )
        XCTAssertFalse(
            ClaudeContextDetector.isKnownAIWebURL(
                try XCTUnwrap(URL(string: "https://example.com/article-about-openai"))
            )
        )
        XCTAssertFalse(
            ClaudeContextDetector.isKnownAIWebURL(
                try XCTUnwrap(URL(string: "https://chatgpt.com.example.org/"))
            )
        )
        XCTAssertFalse(
            ClaudeContextDetector.isKnownAIWebURL(
                try XCTUnwrap(URL(string: "https://platform.openai.com/docs"))
            )
        )
    }

    func testUniversalSelectionLanguageRoutingIsBidirectional() {
        let chinese = SelectionLanguageRouter.route(for: "这是一个跨应用选区翻译测试。")
        let english = SelectionLanguageRouter.route(
            for: "This selected sentence should be translated into Simplified Chinese."
        )
        let japanese = SelectionLanguageRouter.route(for: "選択した文章を中国語に翻訳します。")
        let korean = SelectionLanguageRouter.route(for: "선택한 문장을 중국어로 번역합니다.")

        XCTAssertTrue(chinese.sourceIdentifier.hasPrefix("zh"))
        XCTAssertEqual(chinese.targetLanguage, .english)
        XCTAssertEqual(english.sourceIdentifier, "en")
        XCTAssertEqual(english.targetLanguage, .simplifiedChinese)
        XCTAssertEqual(japanese.sourceIdentifier, "ja")
        XCTAssertEqual(japanese.targetLanguage, .simplifiedChinese)
        XCTAssertEqual(korean.sourceIdentifier, "ko")
        XCTAssertEqual(korean.targetLanguage, .simplifiedChinese)
    }

    func testUniversalSelectionLanguageRoutingRespectsManualTarget() {
        let route = SelectionLanguageRouter.route(
            for: "This text has an explicit target language.",
            manualTarget: .japanese
        )

        XCTAssertEqual(route.targetLanguage, .japanese)
    }

    func testTranslationPreferenceLearningWaitsForFullFourteenDays() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var profile = TranslationPreferenceProfile()
        for offset in 0..<8 {
            profile = TranslationPreferenceLearningPolicy.record(
                profile: profile,
                sourceIdentifier: "en-US",
                targetLanguage: .japanese,
                at: start.addingTimeInterval(TimeInterval(offset)),
                deliberateTargetWeight: 1
            )
        }

        let tooEarly = TranslationPreferenceLearningPolicy.evaluated(
            profile: profile,
            at: start.addingTimeInterval(13 * 24 * 60 * 60 + 86_399)
        )

        XCTAssertNil(
            TranslationPreferenceLearningPolicy.preferredTarget(
                for: "en",
                profile: tooEarly
            )
        )
        XCTAssertNil(tooEarly.lastEvaluatedAt)
    }

    func testTranslationPreferenceLearningAppliesConfidentPerSourceTargetsAfterTwoWeeks() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var profile = TranslationPreferenceProfile()
        for offset in 0..<4 {
            profile = TranslationPreferenceLearningPolicy.record(
                profile: profile,
                sourceIdentifier: "en-US",
                targetLanguage: .japanese,
                at: start.addingTimeInterval(TimeInterval(offset)),
                deliberateTargetWeight: 3
            )
            profile = TranslationPreferenceLearningPolicy.record(
                profile: profile,
                sourceIdentifier: "zh-Hans",
                targetLanguage: .english,
                at: start.addingTimeInterval(TimeInterval(10 + offset)),
                deliberateTargetWeight: 3
            )
        }

        profile = TranslationPreferenceLearningPolicy.evaluated(
            profile: profile,
            at: start.addingTimeInterval(14 * 24 * 60 * 60)
        )

        XCTAssertEqual(profile.totalSuccessfulTranslations, 8)
        XCTAssertEqual(
            TranslationPreferenceLearningPolicy.preferredTarget(for: "en-GB", profile: profile),
            .japanese
        )
        XCTAssertEqual(
            TranslationPreferenceLearningPolicy.preferredTarget(for: "zh-CN", profile: profile),
            .english
        )
        XCTAssertNil(TranslationPreferenceLearningPolicy.preferredDefaultTarget(profile: profile))
    }

    func testTranslationPreferenceLearningRejectsLowConfidenceAndSparseSamples() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var profile = TranslationPreferenceProfile()
        for offset in 0..<5 {
            profile = TranslationPreferenceLearningPolicy.record(
                profile: profile,
                sourceIdentifier: "en",
                targetLanguage: .simplifiedChinese,
                at: start.addingTimeInterval(TimeInterval(offset)),
                deliberateTargetWeight: 1
            )
        }
        for offset in 0..<3 {
            profile = TranslationPreferenceLearningPolicy.record(
                profile: profile,
                sourceIdentifier: "en",
                targetLanguage: .japanese,
                at: start.addingTimeInterval(TimeInterval(20 + offset)),
                deliberateTargetWeight: 1
            )
        }

        profile = TranslationPreferenceLearningPolicy.evaluated(
            profile: profile,
            at: start.addingTimeInterval(15 * 24 * 60 * 60)
        )

        XCTAssertNil(
            TranslationPreferenceLearningPolicy.preferredTarget(for: "en", profile: profile)
        )
        XCTAssertNil(TranslationPreferenceLearningPolicy.preferredDefaultTarget(profile: profile))
    }

    func testTranslationPreferenceLearningRequiresEightOverallEvents() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var profile = TranslationPreferenceProfile()
        for offset in 0..<4 {
            profile = TranslationPreferenceLearningPolicy.record(
                profile: profile,
                sourceIdentifier: "en",
                targetLanguage: .japanese,
                at: start.addingTimeInterval(TimeInterval(offset)),
                deliberateTargetWeight: 3
            )
        }

        profile = TranslationPreferenceLearningPolicy.evaluated(
            profile: profile,
            at: start.addingTimeInterval(14 * 24 * 60 * 60)
        )

        XCTAssertEqual(profile.totalSuccessfulTranslations, 4)
        XCTAssertNotNil(profile.lastEvaluatedAt)
        XCTAssertNil(
            TranslationPreferenceLearningPolicy.preferredTarget(for: "en", profile: profile)
        )
        XCTAssertNil(TranslationPreferenceLearningPolicy.preferredDefaultTarget(profile: profile))
    }

    func testTranslationPreferenceLearningRemovesAStalePreferenceWhenHabitsBecomeAmbiguous() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let evaluationDate = start.addingTimeInterval(14 * 24 * 60 * 60)
        var profile = TranslationPreferenceProfile()
        for offset in 0..<4 {
            profile = TranslationPreferenceLearningPolicy.record(
                profile: profile,
                sourceIdentifier: "en",
                targetLanguage: .japanese,
                at: start.addingTimeInterval(TimeInterval(offset)),
                deliberateTargetWeight: 3
            )
            profile = TranslationPreferenceLearningPolicy.record(
                profile: profile,
                sourceIdentifier: "zh",
                targetLanguage: .english,
                at: start.addingTimeInterval(TimeInterval(10 + offset)),
                deliberateTargetWeight: 3
            )
        }
        profile = TranslationPreferenceLearningPolicy.evaluated(
            profile: profile,
            at: evaluationDate
        )
        XCTAssertEqual(
            TranslationPreferenceLearningPolicy.preferredTarget(for: "en", profile: profile),
            .japanese
        )

        for offset in 0..<4 {
            profile = TranslationPreferenceLearningPolicy.record(
                profile: profile,
                sourceIdentifier: "en",
                targetLanguage: .simplifiedChinese,
                at: evaluationDate.addingTimeInterval(TimeInterval(offset + 1)),
                deliberateTargetWeight: 3
            )
        }

        XCTAssertNil(
            TranslationPreferenceLearningPolicy.preferredTarget(for: "en", profile: profile)
        )
        XCTAssertNil(TranslationPreferenceLearningPolicy.preferredDefaultTarget(profile: profile))
    }

    func testTranslationPreferencePersistenceStoresOnlyAggregateProfileAndResets() throws {
        let suiteName = "ClaudePromptTranslatorTests.preferences.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let profile = TranslationPreferenceProfile(
            firstRecordedAt: Date(timeIntervalSince1970: 1_700_000_000),
            totalSuccessfulTranslations: 4,
            targetEventCounts: [TargetLanguage.english.rawValue: 4],
            targetScores: [TargetLanguage.english.rawValue: 12],
            pairEventCounts: ["zh>en": 4],
            pairScores: ["zh>en": 12]
        )

        TranslationPreferencePersistence.save(profile, to: defaults)
        XCTAssertEqual(TranslationPreferencePersistence.load(from: defaults), profile)
        let storedData = try XCTUnwrap(
            defaults.data(forKey: TranslationPreferencePersistence.profileKey)
        )
        let storedJSON = try XCTUnwrap(String(data: storedData, encoding: .utf8))
        XCTAssertFalse(storedJSON.contains("sourceText"))
        XCTAssertFalse(storedJSON.contains("translationText"))
        XCTAssertFalse(storedJSON.contains("applicationName"))
        XCTAssertFalse(storedJSON.contains("windowTitle"))

        TranslationPreferencePersistence.reset(in: defaults)
        XCTAssertEqual(
            TranslationPreferencePersistence.load(from: defaults),
            TranslationPreferenceProfile()
        )
    }

    func testUniversalSelectionNormalizerRejectsEmptyPunctuationAndOversizedText() {
        XCTAssertNil(SelectionTextNormalizer.normalizedText(from: "  \n "))
        XCTAssertNil(SelectionTextNormalizer.normalizedText(from: "…!?"))
        XCTAssertNil(SelectionTextNormalizer.normalizedText(from: "abcdef", maximumCharacters: 5))
        XCTAssertEqual(
            SelectionTextNormalizer.normalizedText(from: "  Hello, 世界。 \n"),
            "Hello, 世界。"
        )
    }

    func testDragGeometryEstimatorRecoversAStaticTextSubstring() {
        let text = "Selection priority verification works correctly in a real ChatGPT response."
        let value = text as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13)
        ]
        let fullWidth = value.size(withAttributes: attributes).width
        let selectedLength = 47
        let selectedWidth = value.substring(to: selectedLength)
            .size(withAttributes: attributes).width

        let range = SelectionDragTextEstimator.estimatedUTF16Range(
            text: text,
            elementMinX: 100,
            elementWidth: fullWidth,
            dragStartX: 100,
            dragEndX: 100 + selectedWidth
        )

        XCTAssertEqual(range, NSRange(location: 0, length: selectedLength))
        XCTAssertEqual(
            range.map { value.substring(with: $0) },
            "Selection priority verification works correctly"
        )
    }

    func testPassiveSelectionFilterSkipsLiteralsAndKeepsNaturalText() {
        XCTAssertNil(PassiveTextEligibility.normalizedCandidate("12345"))
        XCTAssertNil(PassiveTextEligibility.normalizedCandidate("https://example.com/path"))
        XCTAssertNil(PassiveTextEligibility.normalizedCandidate("v2.0.28"))
        XCTAssertNil(
            PassiveTextEligibility.normalizedCandidate(
                "/Users/example/Documents/New project/private-file.pdf"
            )
        )
        XCTAssertNil(PassiveTextEligibility.normalizedCandidate("C:\\Users\\example\\private.txt"))
        XCTAssertNil(PassiveTextEligibility.normalizedCandidate("file:///Users/example/private.txt"))
        XCTAssertEqual(
            PassiveTextEligibility.normalizedCandidate("  Hover over this sentence.  "),
            "Hover over this sentence."
        )
    }

    func testAppPrivacyPolicyBlocksBuiltInAndUserSelectedApplications() {
        XCTAssertTrue(
            AppPrivacyPolicy.allowsCapture(
                bundleIdentifier: "com.openai.chat",
                userBlockedIdentifiers: []
            )
        )
        XCTAssertFalse(
            AppPrivacyPolicy.allowsCapture(
                bundleIdentifier: "com.1Password.1Password",
                userBlockedIdentifiers: []
            )
        )
        XCTAssertFalse(
            AppPrivacyPolicy.allowsCapture(
                bundleIdentifier: "com.example.PrivateNotes",
                userBlockedIdentifiers: ["COM.EXAMPLE.PRIVATENOTES"]
            )
        )
        XCTAssertFalse(
            AppPrivacyPolicy.allowsCapture(bundleIdentifier: nil, userBlockedIdentifiers: [])
        )
    }

    func testSelectionMonitorPrivacyPolicyNeverObservesBlockedApplication() {
        XCTAssertTrue(
            SelectionMonitorPrivacyPolicy.shouldObserve(
                isHelperApplication: false,
                isTerminated: false,
                accessibilityTrusted: true,
                applicationAllowed: true
            )
        )
        XCTAssertFalse(
            SelectionMonitorPrivacyPolicy.shouldObserve(
                isHelperApplication: false,
                isTerminated: false,
                accessibilityTrusted: true,
                applicationAllowed: false
            )
        )
    }

    func testXContentFilterKeepsPostBodyAndDropsInterfaceMetadata() throws {
        let source = """
        Example Author
        @example_user
        2h
        I like being home when I reply to thoughtful posts. This sentence is the actual content.
        1.2K views
        Re\u{200B}ply
        Share
        """

        let result = try XCTUnwrap(
            TranslationContentFilter.filter(
                source,
                level: .bodyFirst,
                intent: .hover,
                appName: "Safari",
                windowTitle: "Example Author on X: post / X"
            )
        )

        XCTAssertTrue(result.text.contains("I like being home when I reply"))
        XCTAssertTrue(result.text.contains("Example Author"))
        XCTAssertFalse(result.text.contains("@example_user"))
        XCTAssertFalse(result.text.contains("1.2K views"))
        XCTAssertFalse(result.text.contains("\nReply"))
        XCTAssertEqual(result.profileIdentifier, "x-twitter")
        XCTAssertEqual(result.removedLineCount, 5)
    }

    func testContentFilterDoesNotGuessAWebsiteOrOverrideExplicitSelection() throws {
        let mixed = "Home\nThis is important text.\nReply"
        let generic = try XCTUnwrap(
            TranslationContentFilter.filter(
                mixed,
                level: .bodyFirst,
                intent: .hover,
                appName: "Safari",
                windowTitle: "A normal documentation page"
            )
        )
        XCTAssertEqual(generic.text, mixed)

        let explicit = try XCTUnwrap(
            TranslationContentFilter.filter(
                "Reply",
                level: .strict,
                intent: .explicitSelection,
                appName: "X",
                windowTitle: "Home / X"
            )
        )
        XCTAssertEqual(explicit.text, "Reply")
        XCTAssertEqual(explicit.profileIdentifier, "explicit")
    }

    func testHoverSnippetPrefersParagraphAroundPointerLocation() {
        let first = String(repeating: "A", count: 300)
        let middle = "This is the paragraph under the pointer."
        let source = first + "\n" + middle + "\n" + String(repeating: "B", count: 300)
        let location = (first + "\n").utf16.count + 8

        XCTAssertEqual(
            HoverTextSnippet.around(utf16Location: location, in: source, maximumCharacters: 120),
            middle
        )
    }

    func testSubtitleSentenceFormattingAndStableFrameDeduplication() {
        XCTAssertEqual(
            SubtitleSentenceFormatter.normalizedCue(from: "Hello world\nfrom a video"),
            "Hello world from a video"
        )
        XCTAssertEqual(
            SubtitleSentenceFormatter.normalizedCue(from: "这是第一行\n这是第二行"),
            "这是第一行这是第二行"
        )

        var processor = SubtitleCueProcessor()
        XCTAssertNil(processor.observe("Hello world"))
        XCTAssertEqual(processor.observe("Hello world"), "Hello world")
        XCTAssertNil(processor.observe("Hello world"))
        XCTAssertNil(processor.observe("A new subtitle"))
        XCTAssertEqual(processor.observe("A new subtitle"), "A new subtitle")
    }

    func testScreenRegionConvertsAppKitCoordinatesToDisplaySourceCoordinates() {
        let region = ScreenRegionSelection(
            displayID: 7,
            screenFrame: CGRect(x: 100, y: 200, width: 1_200, height: 800),
            appKitRect: CGRect(x: 220, y: 260, width: 500, height: 140)
        )

        XCTAssertEqual(
            region.sourceRect,
            CGRect(x: 120, y: 600, width: 500, height: 140)
        )
    }

    func testScreenRegionCaptureMustIntersectSourceApplicationWindow() {
        let display = CGRect(x: 1_440, y: 0, width: 1_280, height: 800)
        let selected = CGRect(x: 100, y: 120, width: 320, height: 140)

        XCTAssertTrue(
            ScreenRegionSourceWindowPolicy.intersectsSourceWindow(
                sourceRect: selected,
                displayFrame: display,
                sourceWindowFrames: [CGRect(x: 1_500, y: 80, width: 900, height: 620)]
            )
        )
        XCTAssertFalse(
            ScreenRegionSourceWindowPolicy.intersectsSourceWindow(
                sourceRect: selected,
                displayFrame: display,
                sourceWindowFrames: [CGRect(x: 2_300, y: 500, width: 300, height: 220)]
            )
        )
    }

    func testReplyOCRCapturePlanUsesOnlyConversationRectangle() throws {
        let plan = try XCTUnwrap(
            AIConversationCapturePlan.make(
                windowFrame: CGRect(x: 100, y: 80, width: 1_000, height: 800),
                displayFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
                applicationName: "ChatGPT"
            )
        )

        XCTAssertEqual(plan.sourceRect, CGRect(x: 280, y: 136, width: 780, height: 608))
        XCTAssertLessThan(plan.sourceRect.width, 1_000)
        XCTAssertLessThan(plan.sourceRect.height, 800)
    }

    func testReplyOCRCapturePlanConvertsToSecondaryDisplayCoordinates() throws {
        let plan = try XCTUnwrap(
            AIConversationCapturePlan.make(
                windowFrame: CGRect(x: 1_500, y: 100, width: 800, height: 600),
                displayFrame: CGRect(x: 1_440, y: 0, width: 1_280, height: 800),
                applicationName: "Claude"
            )
        )

        XCTAssertEqual(plan.sourceRect, CGRect(x: 300, y: 142, width: 528, height: 456))
    }

    func testSubtitleCacheUsesDigestTTLAndExplicitClear() async {
        let cache = SubtitleTranslationCache(capacity: 2, timeToLive: 2)
        let source = "private subtitle source"
        let output = TranslationProviderOutput(text: "本地译文", providerName: "test")
        let start = Date(timeIntervalSince1970: 1_000)
        let key = SubtitleTranslationCache.cacheKey(text: source, target: .simplifiedChinese)

        XCTAssertEqual(key.count, 64)
        XCTAssertFalse(key.contains(source))
        await cache.insert(output, for: source, target: .simplifiedChinese, now: start)
        let freshValue = await cache.value(
            for: source,
            target: .simplifiedChinese,
            now: start.addingTimeInterval(1)
        )
        XCTAssertEqual(freshValue, output)
        let expiredValue = await cache.value(
            for: source,
            target: .simplifiedChinese,
            now: start.addingTimeInterval(3)
        )
        XCTAssertNil(expiredValue)
        await cache.insert(output, for: source, target: .simplifiedChinese, now: start)
        await cache.removeAll()
        let clearedValue = await cache.value(
            for: source,
            target: .simplifiedChinese,
            now: start
        )
        XCTAssertNil(clearedValue)
    }

    func testVisionOCRRecognizesSyntheticHighContrastText() throws {
        let size = NSSize(width: 900, height: 220)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        let text = "Synthetic subtitle translation test"
        text.draw(
            at: NSPoint(x: 32, y: 82),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 46, weight: .semibold),
                .foregroundColor: NSColor.black
            ]
        )
        image.unlockFocus()

        var proposedRect = NSRect(origin: .zero, size: size)
        let cgImage = try XCTUnwrap(
            image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil)
        )
        let result = try ScreenTextOCRRecognizer.recognize(in: cgImage)

        XCTAssertTrue(result.text.lowercased().contains("synthetic"))
        XCTAssertTrue(result.text.lowercased().contains("translation"))
        XCTAssertGreaterThan(result.averageConfidence, 0.5)
    }

    func testUniversalSelectionProtectionClassifierRejectsSecurePasswordAndProtectedContent() {
        XCTAssertTrue(
            SelectionProtectionClassifier.isProtected(
                role: "AXTextField",
                subrole: "AXSecureTextField",
                containsProtectedContent: false
            )
        )
        XCTAssertTrue(
            SelectionProtectionClassifier.isProtected(
                role: "AXPasswordField",
                subrole: nil,
                containsProtectedContent: false
            )
        )
        XCTAssertTrue(
            SelectionProtectionClassifier.isProtected(
                role: "AXGroup",
                subrole: nil,
                containsProtectedContent: true
            )
        )
        XCTAssertFalse(
            SelectionProtectionClassifier.isProtected(
                role: "AXTextArea",
                subrole: nil,
                containsProtectedContent: false
            )
        )
    }

    func testUniversalSelectionReplacementRequiresExactOriginalAndExactWriteVerification() {
        XCTAssertTrue(
            SelectionReplacementVerification.originalSelectionMatches(
                current: " selected text ",
                expected: " selected text "
            )
        )
        XCTAssertFalse(
            SelectionReplacementVerification.originalSelectionMatches(
                current: "selected text",
                expected: " selected text "
            )
        )

        XCTAssertTrue(
            SelectionReplacementVerification.writeWasVerified(
                expectedValue: "before translated after",
                currentValue: "before translated after",
                selectedTextAfterWrite: nil,
                renderedReplacement: "translated"
            )
        )
        XCTAssertTrue(
            SelectionReplacementVerification.writeWasVerified(
                expectedValue: nil,
                currentValue: nil,
                selectedTextAfterWrite: "translated",
                renderedReplacement: "translated"
            )
        )
        XCTAssertFalse(
            SelectionReplacementVerification.writeWasVerified(
                expectedValue: "before translated after",
                currentValue: "before unexpected after",
                selectedTextAfterWrite: "unexpected",
                renderedReplacement: "translated"
            )
        )
    }

    func testUniversalSelectionFingerprintDistinguishesElementAndRange() {
        let baseline = SelectionFingerprint.make(
            processIdentifier: 42,
            text: "相同文字",
            elementIdentity: 100,
            selectedRange: NSRange(location: 2, length: 4)
        )

        XCTAssertNotEqual(
            baseline,
            SelectionFingerprint.make(
                processIdentifier: 42,
                text: "相同文字",
                elementIdentity: 101,
                selectedRange: NSRange(location: 2, length: 4)
            )
        )
        XCTAssertNotEqual(
            baseline,
            SelectionFingerprint.make(
                processIdentifier: 42,
                text: "相同文字",
                elementIdentity: 100,
                selectedRange: NSRange(location: 20, length: 4)
            )
        )
        XCTAssertFalse(baseline.contains("相同文字"))
    }

    func testSelectionCaptureRetryPolicyIsBounded() {
        XCTAssertEqual(
            SelectionCaptureRetryPolicy.delaysAfterEmptyResult(for: .focusedPath),
            [120_000_000, 260_000_000]
        )
        XCTAssertEqual(
            SelectionCaptureRetryPolicy.delaysAfterEmptyResult(for: .boundedTree),
            [150_000_000]
        )
    }

    func testSelectionMonitorDoesNotReplaceSourceSelectionWithHelperClick() {
        let helperFrame = NSRect(x: 900, y: 100, width: 340, height: 440)

        XCTAssertTrue(
            SelectionMonitorEventPolicy.pointIsInsideHelperWindow(
                quartzPoint: CGPoint(x: 1_000, y: 800),
                helperWindowFrames: [helperFrame],
                screenMaxY: 1_200
            )
        )
        XCTAssertFalse(
            SelectionMonitorEventPolicy.pointIsInsideHelperWindow(
                quartzPoint: CGPoint(x: 500, y: 800),
                helperWindowFrames: [helperFrame],
                screenMaxY: 1_200
            )
        )
    }

    func testResponseSelectionSnapshotIsBoundToProcessAndShortLifetime() {
        let capturedAt = Date(timeIntervalSinceReferenceDate: 1_000)

        XCTAssertTrue(
            ResponseSelectionSnapshotPolicy.isFresh(
                snapshotProcessIdentifier: 42,
                targetProcessIdentifier: 42,
                capturedAt: capturedAt,
                now: capturedAt.addingTimeInterval(14.9),
                maximumAge: 15
            )
        )
        XCTAssertFalse(
            ResponseSelectionSnapshotPolicy.isFresh(
                snapshotProcessIdentifier: 42,
                targetProcessIdentifier: 43,
                capturedAt: capturedAt,
                now: capturedAt.addingTimeInterval(1),
                maximumAge: 15
            )
        )
        XCTAssertFalse(
            ResponseSelectionSnapshotPolicy.isFresh(
                snapshotProcessIdentifier: 42,
                targetProcessIdentifier: 42,
                capturedAt: capturedAt,
                now: capturedAt.addingTimeInterval(15.1),
                maximumAge: 15
            )
        )
    }

    func testCopyMenuMatcherAcceptsOnlyExactUnmodifiedCopyCommand() {
        XCTAssertTrue(
            CopyMenuItemMatcher.matches(
                role: kAXMenuItemRole as String,
                title: "复制",
                identifier: nil,
                commandCharacter: "C",
                commandModifiers: 0,
                isEnabled: true
            )
        )
        XCTAssertTrue(
            CopyMenuItemMatcher.matches(
                role: kAXMenuItemRole as String,
                title: nil,
                identifier: "copy:",
                commandCharacter: "c",
                commandModifiers: 0,
                isEnabled: true
            )
        )
        XCTAssertFalse(
            CopyMenuItemMatcher.matches(
                role: kAXMenuItemRole as String,
                title: "Copy Link",
                identifier: nil,
                commandCharacter: "c",
                commandModifiers: 0,
                isEnabled: true
            )
        )
        XCTAssertFalse(
            CopyMenuItemMatcher.matches(
                role: kAXMenuItemRole as String,
                title: "Copy",
                identifier: nil,
                commandCharacter: "c",
                commandModifiers: 1,
                isEnabled: true
            )
        )
        XCTAssertFalse(
            CopyMenuItemMatcher.matches(
                role: kAXMenuItemRole as String,
                title: "Copy",
                identifier: nil,
                commandCharacter: "c",
                commandModifiers: 0,
                isEnabled: false
            )
        )
    }

    func testSelectionReplacementContextRequiresFocusExactRangeAndUnprotectedContent() {
        let range = NSRange(location: 8, length: 5)
        XCTAssertTrue(
            SelectionReplacementContextSafety.canProceed(
                capturedRange: range,
                currentRange: range,
                capturedElementIsFocused: true,
                containsProtectedContent: false
            )
        )
        XCTAssertFalse(
            SelectionReplacementContextSafety.canProceed(
                capturedRange: range,
                currentRange: NSRange(location: 20, length: 5),
                capturedElementIsFocused: true,
                containsProtectedContent: false
            )
        )
        XCTAssertFalse(
            SelectionReplacementContextSafety.canProceed(
                capturedRange: range,
                currentRange: range,
                capturedElementIsFocused: false,
                containsProtectedContent: false
            )
        )
        XCTAssertFalse(
            SelectionReplacementContextSafety.canProceed(
                capturedRange: range,
                currentRange: range,
                capturedElementIsFocused: true,
                containsProtectedContent: true
            )
        )
    }

    func testTranslationOperationSafetyRejectsPausedAndStaleTasks() {
        XCTAssertTrue(
            TranslationOperationSafety.canContinue(
                expectedGeneration: 7,
                currentGeneration: 7,
                translatorEnabled: true
            )
        )
        XCTAssertFalse(
            TranslationOperationSafety.canContinue(
                expectedGeneration: 6,
                currentGeneration: 7,
                translatorEnabled: true
            )
        )
        XCTAssertFalse(
            TranslationOperationSafety.canContinue(
                expectedGeneration: 7,
                currentGeneration: 7,
                translatorEnabled: false
            )
        )
    }

    func testKeyboardInjectionSafetyRequiresSameFrontmostProcessAndFocusedElement() {
        XCTAssertTrue(
            KeyboardInjectionSafety.canInject(
                expectedProcessIdentifier: 42,
                frontmostProcessIdentifier: 42,
                expectedFocusIdentity: 1001,
                currentFocusIdentity: 1001
            )
        )
        XCTAssertFalse(
            KeyboardInjectionSafety.canInject(
                expectedProcessIdentifier: 42,
                frontmostProcessIdentifier: 99,
                expectedFocusIdentity: 1001,
                currentFocusIdentity: 1001
            )
        )
        XCTAssertFalse(
            KeyboardInjectionSafety.canInject(
                expectedProcessIdentifier: 42,
                frontmostProcessIdentifier: 42,
                expectedFocusIdentity: 1001,
                currentFocusIdentity: 2002
            )
        )
        XCTAssertFalse(
            KeyboardInjectionSafety.canInject(
                expectedProcessIdentifier: 42,
                frontmostProcessIdentifier: 42,
                expectedFocusIdentity: 1001,
                currentFocusIdentity: nil
            )
        )
    }

    func testPasteboardOwnershipSafetyPreservesAUsersNewCopy() {
        XCTAssertTrue(
            PasteboardOwnershipSafety.canRestore(
                expectedChangeCount: 12,
                currentChangeCount: 12
            )
        )
        XCTAssertFalse(
            PasteboardOwnershipSafety.canRestore(
                expectedChangeCount: 12,
                currentChangeCount: 13
            )
        )
    }

    func testClipboardCompatibilityCannotBypassPrivacyAcknowledgement() {
        XCTAssertFalse(
            PrivacyPreferenceGate.canEnable(
                savedEnabled: true,
                privacyAcknowledged: false
            )
        )
        XCTAssertFalse(
            PrivacyPreferenceGate.canEnable(
                savedEnabled: false,
                privacyAcknowledged: true
            )
        )
        XCTAssertTrue(
            PrivacyPreferenceGate.canEnable(
                savedEnabled: true,
                privacyAcknowledged: true
            )
        )
    }

    func testClipboardPasteRequiresStableInputContextAndSelection() {
        XCTAssertTrue(
            ClipboardPasteSafety.canProceed(
                initialInputEpoch: 7,
                currentInputEpoch: 7,
                contextIsCurrent: true,
                containsProtectedContent: false,
                selectionRangeMatches: true
            )
        )
        XCTAssertFalse(
            ClipboardPasteSafety.canProceed(
                initialInputEpoch: 7,
                currentInputEpoch: 8,
                contextIsCurrent: true,
                containsProtectedContent: false,
                selectionRangeMatches: true
            )
        )
        XCTAssertFalse(
            ClipboardPasteSafety.canProceed(
                initialInputEpoch: 7,
                currentInputEpoch: 7,
                contextIsCurrent: false,
                containsProtectedContent: false,
                selectionRangeMatches: true
            )
        )
        XCTAssertFalse(
            ClipboardPasteSafety.canProceed(
                initialInputEpoch: 7,
                currentInputEpoch: 7,
                contextIsCurrent: true,
                containsProtectedContent: true,
                selectionRangeMatches: true
            )
        )
        XCTAssertFalse(
            ClipboardPasteSafety.canProceed(
                initialInputEpoch: 7,
                currentInputEpoch: 7,
                contextIsCurrent: true,
                containsProtectedContent: false,
                selectionRangeMatches: false
            )
        )
    }

    func testClipboardFallbackAcceptsOnlyOneStableCopyFromTheOriginalContext() {
        XCTAssertTrue(
            ClipboardFallbackSafety.canAcceptCopy(
                baselineChangeCount: 20,
                observedChangeCount: 21,
                quietChangeCount: 21,
                initialInputEpoch: 4,
                currentInputEpoch: 4,
                contextIsCurrent: true,
                selectionRangeMatches: true
            )
        )
        XCTAssertFalse(
            ClipboardFallbackSafety.canAcceptCopy(
                baselineChangeCount: 20,
                observedChangeCount: 22,
                quietChangeCount: 22,
                initialInputEpoch: 4,
                currentInputEpoch: 4,
                contextIsCurrent: true,
                selectionRangeMatches: true
            )
        )
        XCTAssertFalse(
            ClipboardFallbackSafety.canAcceptCopy(
                baselineChangeCount: 20,
                observedChangeCount: 21,
                quietChangeCount: 22,
                initialInputEpoch: 4,
                currentInputEpoch: 4,
                contextIsCurrent: true,
                selectionRangeMatches: true
            )
        )
        XCTAssertFalse(
            ClipboardFallbackSafety.canAcceptCopy(
                baselineChangeCount: 20,
                observedChangeCount: 21,
                quietChangeCount: 21,
                initialInputEpoch: 4,
                currentInputEpoch: 5,
                contextIsCurrent: true,
                selectionRangeMatches: true
            )
        )
        XCTAssertFalse(
            ClipboardFallbackSafety.canAcceptCopy(
                baselineChangeCount: 20,
                observedChangeCount: 21,
                quietChangeCount: 21,
                initialInputEpoch: 4,
                currentInputEpoch: 4,
                contextIsCurrent: false,
                selectionRangeMatches: true
            )
        )
        XCTAssertFalse(
            ClipboardFallbackSafety.canAcceptCopy(
                baselineChangeCount: 20,
                observedChangeCount: 21,
                quietChangeCount: 21,
                initialInputEpoch: 4,
                currentInputEpoch: 4,
                contextIsCurrent: true,
                selectionRangeMatches: false
            )
        )
    }

    func testClipboardFallbackDoesNotRestoreAfterAnyAmbiguousChange() {
        XCTAssertTrue(
            ClipboardFallbackSafety.canRestore(
                acceptedChangeCount: 21,
                currentChangeCount: 21,
                initialInputEpoch: 4,
                currentInputEpoch: 4,
                contextIsCurrent: true,
                copiedValueStillMatches: true
            )
        )
        XCTAssertFalse(
            ClipboardFallbackSafety.canRestore(
                acceptedChangeCount: 21,
                currentChangeCount: 22,
                initialInputEpoch: 4,
                currentInputEpoch: 4,
                contextIsCurrent: true,
                copiedValueStillMatches: true
            )
        )
        XCTAssertFalse(
            ClipboardFallbackSafety.canRestore(
                acceptedChangeCount: 21,
                currentChangeCount: 21,
                initialInputEpoch: 4,
                currentInputEpoch: 5,
                contextIsCurrent: true,
                copiedValueStillMatches: true
            )
        )
        XCTAssertFalse(
            ClipboardFallbackSafety.canRestore(
                acceptedChangeCount: 21,
                currentChangeCount: 21,
                initialInputEpoch: 4,
                currentInputEpoch: 4,
                contextIsCurrent: false,
                copiedValueStillMatches: true
            )
        )
        XCTAssertFalse(
            ClipboardFallbackSafety.canRestore(
                acceptedChangeCount: 21,
                currentChangeCount: 21,
                initialInputEpoch: 4,
                currentInputEpoch: 4,
                contextIsCurrent: true,
                copiedValueStillMatches: false
            )
        )
    }

    @MainActor
    func testSimplifiedChineseTargetUsesProviderSpecificLanguageCodes() {
        XCTAssertEqual(TargetLanguage.simplifiedChinese.googleLanguageCode, "zh-CN")
        XCTAssertEqual(TargetLanguage.simplifiedChinese.appleLanguageCode, "zh-Hans")
        XCTAssertTrue(
            InputTarget.isTranslatableInputText(
                "Translate this focused input into Chinese.",
                to: .simplifiedChinese
            )
        )
    }

    func testParseTranslationJoinsSegments() throws {
        let json = #"""
        [[["Please summarize ","请总结",null,null,3],[ "the core point.","核心观点",null,null,3]],null,"zh-CN"]
        """#
        let data = try XCTUnwrap(json.data(using: .utf8))

        let translation = try GoogleTranslateClient.parseTranslation(from: data)

        XCTAssertEqual(translation, "Please summarize the core point.")
    }

    func testParseTranslationRejectsUnexpectedShape() {
        let data = Data(#"{"error":"bad"}"#.utf8)

        XCTAssertThrowsError(try GoogleTranslateClient.parseTranslation(from: data))
    }

    func testPromptTranslationPolisherAvoidsScenarioSpecificRewrite() {
        let polished = PromptTranslationPolisher.polish(
            "What is there to do in Japan? I like Disney.",
            source: "日本有什么好玩的，我喜欢迪斯尼",
            targetLanguage: .english
        )

        XCTAssertEqual(polished, "What is there to do in Japan? I like Disney.")
    }

    func testPromptTranslationPolisherRemovesHelpMeScaffolding() {
        let polished = PromptTranslationPolisher.polish(
            "Please help me design a translation plugin",
            source: "请帮我设计一个翻译插件",
            targetLanguage: .english
        )

        XCTAssertEqual(polished, "Please design a translation plugin.")
    }

    func testPromptTranslationPolisherPreservesMultilineLayout() {
        let source = """
        请完成以下任务：
        - 保留 Markdown
        - 不修改代码
        """
        let translation = """
        Complete the following tasks:
        - Keep Markdown
        - Do not modify code
        """

        let polished = PromptTranslationPolisher.polish(
            translation,
            source: source,
            targetLanguage: .english
        )

        XCTAssertEqual(polished, translation)
    }

    func testTranslationChunkerPreservesCodeFencesAndExpandsLongText() {
        let longParagraph = String(repeating: "请把这一段翻译得自然准确。", count: 180)
        let source = """
        \(longParagraph)

        ```swift
        let greeting = "你好"
        ```

        最后一段也需要翻译。
        """

        let chunks = TranslationChunker.chunks(for: source, maxChunkLength: 300)

        XCTAssertEqual(chunks.map(\.text).joined(), source)
        XCTAssertTrue(chunks.filter(\.shouldTranslate).allSatisfy { $0.text.count <= 300 })
        XCTAssertTrue(chunks.contains {
            !$0.shouldTranslate && $0.text.contains("let greeting = \"你好\"")
        })
        XCTAssertGreaterThan(chunks.filter(\.shouldTranslate).count, 1)
    }

    func testLanguageDetectionProjectionExcludesProtectedTechnicalContent() {
        let source = """
        ```swift
        \(String(repeating: "let englishIdentifier = performNetworkRequest()\n", count: 80))
        ```

        请只根据这句中文判断源语言。
        """

        let projection = TranslationChunker.languageDetectionProjection(for: source)

        XCTAssertFalse(projection.contains("performNetworkRequest"))
        XCTAssertTrue(projection.contains("请只根据这句中文判断源语言"))
        XCTAssertTrue(SelectionLanguageRouter.detectedLanguageIdentifier(in: source).hasPrefix("zh"))
    }

    func testExpandedTranslationLimits() {
        XCTAssertEqual(TranslationLimits.maxInputCharacters, 160_000)
        XCTAssertEqual(TranslationLimits.maxResponseCharacters, 96_000)
        XCTAssertEqual(TranslationLimits.maxOCRCharacters, 60_000)
        XCTAssertEqual(TranslationLimits.maxRequestCharacters, 3_000)
    }

    func testTranslationChunkerDoesNotDuplicateWhitespaceBetweenCodeBlocks() {
        let source = """
        ```swift
        let first = 1
        ```


        ```swift
        let second = 2
        ```
        """

        let chunks = TranslationChunker.chunks(for: source, maxChunkLength: 80)

        XCTAssertEqual(chunks.map(\.text).joined(), source)
    }

    func testTranslationChunkerProtectsInlineCodeAndURLs() {
        let source = "请解释 `let value = \"你好\"`，并参考 https://example.com/docs?q=翻译 。"

        let chunks = TranslationChunker.chunks(for: source, maxChunkLength: 18)

        XCTAssertEqual(chunks.map(\.text).joined(), source)
        XCTAssertTrue(chunks.contains {
            !$0.shouldTranslate && $0.text == "`let value = \"你好\"`"
        })
        XCTAssertTrue(chunks.contains {
            !$0.shouldTranslate && $0.text == "https://example.com/docs?q=翻译"
        })
        XCTAssertTrue(chunks.filter(\.shouldTranslate).allSatisfy { $0.text.count <= 18 })
    }

    func testTranslationChunkerProtectsTechnicalLongFormSyntax() {
        let source = #"""
        ---
        请阅读[安装文档](../guide/setup.md)，保留 <details open> 标签。
        行内公式为 $E = mc^2$，另一种写法是 \(a^2 + b^2 = c^2\)。

        | 项目 | 状态 |
        | :--- | ---: |
        | 长文本 | 正常 |
        """#

        let chunks = TranslationChunker.chunks(for: source, maxChunkLength: 80)

        XCTAssertEqual(chunks.map(\.text).joined(), source)
        XCTAssertTrue(chunks.contains { !$0.shouldTranslate && $0.text == "---\n" })
        XCTAssertTrue(chunks.contains { !$0.shouldTranslate && $0.text == "(../guide/setup.md)" })
        XCTAssertTrue(chunks.contains { !$0.shouldTranslate && $0.text == "<details open>" })
        XCTAssertTrue(chunks.contains { !$0.shouldTranslate && $0.text == "$E = mc^2$" })
        XCTAssertTrue(chunks.contains { !$0.shouldTranslate && $0.text == #"\(a^2 + b^2 = c^2\)"# })
        XCTAssertTrue(chunks.contains { !$0.shouldTranslate && $0.text == "| :--- | ---: |\n" })
    }

    func testPromptTranslationPolisherPreservesOuterWhitespaceForLongInputs() {
        let polished = PromptTranslationPolisher.polish(
            "\n  Keep the structure  \n",
            source: "\n  保留结构  \n",
            targetLanguage: .english
        )

        XCTAssertEqual(polished, "\n  Keep the structure.  \n")
    }

    func testPromptTranslationPolisherDoesNotRewriteInlineCodeSpacing() {
        let translation = "Please keep `items .map { $0 }` exactly as written , then explain it"

        let polished = PromptTranslationPolisher.polish(
            translation,
            source: "请原样保留行内代码，然后解释它",
            targetLanguage: .english
        )

        XCTAssertEqual(
            polished,
            "Please keep `items .map { $0 }` exactly as written, then explain it."
        )
    }

    func testResponseLanguageDetectorFindsEnglishAndJapanese() {
        let english = """
        This response explains how the application can keep a lightweight overlay near the chat window while avoiding important controls such as file attachments, model selectors, and permission banners.
        """
        let japanese = "これは日本語の回答です。アプリが出力内容を検出して、必要なときだけ中国語の翻訳を表示します。"

        XCTAssertEqual(ResponseLanguageDetector.detect(in: english), .english)
        XCTAssertEqual(ResponseLanguageDetector.detect(in: japanese), .japanese)
    }

    func testResponseLanguageDetectorSupportsLanguagesBeyondEnglishAndJapanese() {
        let french = """
        Cette réponse explique clairement pourquoi la traduction automatique doit identifier la langue avant de traiter le texte. Elle conserve le contexte, évite les faux positifs et présente un résultat lisible pour la personne qui utilise l'application.
        """
        let german = """
        Diese Antwort beschreibt ausführlich, wie die Anwendung fremdsprachige Nachrichten zuverlässig erkennt. Sie berücksichtigt vollständige Sätze, vermeidet Quellcode und übersetzt nur den eigentlichen Inhalt der Antwort.
        """
        let korean = "이 답변은 자동 번역 기능이 외국어 문장을 안정적으로 감지하고 중국어 번역을 표시하는 방법을 자세하고 자연스럽게 설명합니다."

        XCTAssertEqual(ResponseLanguageDetector.detect(in: french)?.identifier, "fr")
        XCTAssertEqual(ResponseLanguageDetector.detect(in: german)?.identifier, "de")
        XCTAssertEqual(ResponseLanguageDetector.detect(in: korean)?.identifier, "ko")
    }

    func testExplicitSelectionAcceptsShortNonEnglishLanguage() {
        let response = AIResponseReader.foreignSelection(from: "Hola, ¿cómo estás?")

        XCTAssertEqual(response?.text, "Hola, ¿cómo estás?")
        XCTAssertEqual(response?.language.identifier, "es")
    }

    func testResponseLanguageDetectorIgnoresChinese() {
        let chinese = "这是中文回复内容，应该不会被自动回复翻译器当成英文或日文处理，否则会产生重复翻译和无意义的浮层。"
        let mixedChinese = "这是中文回复，主要内容已经是中文，只包含 API response 和 cache key 等少量英文术语。"

        XCTAssertNil(ResponseLanguageDetector.detect(in: chinese))
        XCTAssertNil(ResponseLanguageDetector.detect(in: mixedChinese))
        XCTAssertNil(ResponseLanguageDetector.detectExplicitSelection(in: mixedChinese))
    }

    func testResponseLanguageDetectorIgnoresCodeAndFileListings() {
        let fileListing = """
        ClaudePromptTranslator/Sources/ClaudePromptTranslator/AppModel.swift
        ClaudePromptTranslator/Sources/ClaudePromptTranslator/PromptPanelController.swift
        ClaudePromptTranslator/Sources/ClaudePromptTranslator/PromptView.swift
        """
        let swiftSnippet = """
        import AppKit
        final class FloatingTriggerController: NSObject {
            private var timer: Timer?
            func start() {
                timer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: true) { _ in }
            }
        }
        """

        XCTAssertNil(ResponseLanguageDetector.detect(in: fileListing))
        XCTAssertNil(ResponseLanguageDetector.detect(in: swiftSnippet))
    }

    func testResponseLanguageDetectorKeepsNaturalEnglishSentences() {
        let english = """
        Let me explain why the latest response detection failed. The app was treating technical output as if it were ordinary prose, so the fix is to separate readable assistant text from build logs and source code.
        """

        XCTAssertEqual(ResponseLanguageDetector.detect(in: english), .english)
    }

    func testExplicitResponseSelectionAcceptsShortForeignText() {
        XCTAssertEqual(
            AIResponseReader.foreignSelection(from: "Please keep this concise."),
            DetectedForeignResponse(text: "Please keep this concise.", language: .english)
        )
        XCTAssertEqual(
            AIResponseReader.foreignSelection(from: "この部分だけ翻訳してください。")?.language,
            .japanese
        )
        XCTAssertNil(AIResponseReader.foreignSelection(from: "https://example.com/path/to/file"))
        XCTAssertNil(AIResponseReader.foreignSelection(from: "只翻译这一段中文"))
    }

    func testExplicitResponseSelectionSkipsIdentifiersAndPlaceholders() {
        XCTAssertNil(AIResponseReader.foreignSelection(from: "hello@example.com"))
        XCTAssertNil(AIResponseReader.foreignSelection(from: "550e8400-e29b-41d4-a716-446655440000"))
        XCTAssertNil(AIResponseReader.foreignSelection(from: "v2.0.28"))
        XCTAssertNil(AIResponseReader.foreignSelection(from: "{{accountName}}"))
        XCTAssertNil(AIResponseReader.foreignSelection(from: "document.pdf"))
    }

    func testResponseTranslationCacheIsBoundedAndRefreshesRecentEntries() {
        var cache = ResponseTranslationCache(capacity: 2)
        cache.insert("甲", for: "First response")
        cache.insert("乙", for: "Second response")
        XCTAssertEqual(cache.translation(for: "First   response"), "甲")

        cache.insert("丙", for: "Third response")
        XCTAssertNil(cache.translation(for: "Second response"))
        XCTAssertEqual(cache.translation(for: "First response"), "甲")
        XCTAssertEqual(cache.translation(for: "Third response"), "丙")
    }

    func testAutomaticResponseOCRIsNeverImplicitlyAuthorized() {
        XCTAssertFalse(
            ResponseCapturePrivacyPolicy.allowsOCR(
                trigger: .automatic,
                screenRecordingPermissionGranted: true
            )
        )
        XCTAssertTrue(
            ResponseCapturePrivacyPolicy.allowsOCR(
                trigger: .explicitOCRRetry,
                screenRecordingPermissionGranted: true
            )
        )
        XCTAssertFalse(
            ResponseCapturePrivacyPolicy.allowsOCR(
                trigger: .explicitOCRRetry,
                screenRecordingPermissionGranted: false
            )
        )
        XCTAssertFalse(
            ResponseCapturePrivacyPolicy.allowsOCR(
                trigger: .manualAccessibilityRead,
                screenRecordingPermissionGranted: true
            )
        )
    }

    func testResponseCaptureNeverAuthorizesClipboardAccess() {
        XCTAssertFalse(ResponseCapturePrivacyPolicy.allowsClipboard(trigger: .automatic))
        XCTAssertFalse(ResponseCapturePrivacyPolicy.allowsClipboard(trigger: .manualAccessibilityRead))
        XCTAssertFalse(ResponseCapturePrivacyPolicy.allowsClipboard(trigger: .explicitOCRRetry))
    }

    func testResponseSelectionSnapshotAcceptsOnlyAccessibilityCapture() {
        XCTAssertTrue(ResponseSelectionSnapshotCapturePolicy.allows(.accessibility))
        XCTAssertFalse(ResponseSelectionSnapshotCapturePolicy.allows(.menuCopyFallback))
        XCTAssertFalse(ResponseSelectionSnapshotCapturePolicy.allows(.clipboardFallback))
        XCTAssertFalse(ResponseSelectionSnapshotCapturePolicy.allows(.hoverAccessibility))
        XCTAssertFalse(ResponseSelectionSnapshotCapturePolicy.allows(.screenOCR))
    }

    func testStreamingResponseInvalidatesAnOlderPartialTranslation() {
        XCTAssertTrue(
            ResponseTranslationFreshness.shouldInvalidate(
                translatingSource: "Partial assistant reply",
                incomingSource: "Partial assistant reply with more text"
            )
        )
        XCTAssertFalse(
            ResponseTranslationFreshness.shouldInvalidate(
                translatingSource: "Stable assistant reply",
                incomingSource: "Stable assistant reply"
            )
        )
    }

    func testManualSelectedResponseTemporarilySuppressesAutomaticOverwrite() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(
            ManualResponsePresentationPolicy.suppressesAutomaticScan(
                until: now.addingTimeInterval(1),
                now: now
            )
        )
        XCTAssertFalse(
            ManualResponsePresentationPolicy.suppressesAutomaticScan(
                until: now,
                now: now
            )
        )
        XCTAssertLessThanOrEqual(ManualResponsePresentationPolicy.retention, 15)
    }

    func testSameResponseTextInDifferentTurnsHasDifferentIdentity() {
        let first = DetectedForeignResponse(
            text: "Sure.",
            language: .english,
            captureSource: .chatGPTAccessibility,
            turnIdentifier: "chatgpt|assistant|41"
        )
        let second = DetectedForeignResponse(
            text: "Sure.",
            language: .english,
            captureSource: .chatGPTAccessibility,
            turnIdentifier: "chatgpt|assistant|42"
        )

        XCTAssertNotEqual(
            ResponseTranslationIdentity.value(for: first),
            ResponseTranslationIdentity.value(for: second)
        )

        let stablePrefix = String(repeating: "A", count: 90)
        let partial = DetectedForeignResponse(
            text: stablePrefix + " partial",
            language: .english,
            captureSource: .chatGPTAccessibility,
            turnIdentifier: "chatgpt|assistant|same-marker"
        )
        let completed = DetectedForeignResponse(
            text: stablePrefix + " completed response",
            language: .english,
            captureSource: .chatGPTAccessibility,
            turnIdentifier: "chatgpt|assistant|same-marker"
        )
        XCTAssertNotEqual(
            ResponseTranslationIdentity.value(for: partial),
            ResponseTranslationIdentity.value(for: completed)
        )
    }

    func testResponseTranslationCacheUsesTurnIdentityWhenAvailable() {
        var cache = ResponseTranslationCache(capacity: 4)
        let firstTurn = DetectedForeignResponse(
            text: "The same visible text.",
            language: .english,
            captureSource: .semanticAccessibility,
            turnIdentifier: "chat|assistant|1"
        )
        let secondTurn = DetectedForeignResponse(
            text: "The same visible text.",
            language: .english,
            captureSource: .semanticAccessibility,
            turnIdentifier: "chat|assistant|2"
        )

        cache.insert("第一条", for: firstTurn)

        XCTAssertEqual(cache.translation(for: firstTurn), "第一条")
        XCTAssertNil(cache.translation(for: secondTurn))
    }

    func testResponseTranslationCacheExpiresAndClearsInMemoryContent() {
        let startedAt = Date(timeIntervalSince1970: 1_000)
        var cache = ResponseTranslationCache(capacity: 4, timeToLive: 10)
        cache.insert("短期译文", for: "Sensitive synthetic response", now: startedAt)

        XCTAssertEqual(
            cache.translation(for: "Sensitive synthetic response", now: startedAt.addingTimeInterval(9)),
            "短期译文"
        )
        XCTAssertNil(
            cache.translation(for: "Sensitive synthetic response", now: startedAt.addingTimeInterval(11))
        )

        cache.insert("另一条", for: "Another synthetic response", now: startedAt)
        cache.removeAll()
        XCTAssertNil(cache.translation(for: "Another synthetic response", now: startedAt))
    }

    func testResponseAnnotationKeepsStableSourceAndTurnIdentifier() {
        let response = DetectedForeignResponse(
            text: "This is a stable assistant reply that can continue streaming later.",
            language: .english
        ).annotated(
            source: .chatGPTAccessibility,
            applicationIdentifier: "com.openai.chat",
            ordinal: 4
        )

        XCTAssertEqual(response.captureSource, .chatGPTAccessibility)
        XCTAssertEqual(
            response.turnIdentifier,
            "com.openai.chat|chatGPTAccessibility|4"
        )
    }

    func testOCRRetriesOnlyForSparseOrLowConfidenceText() {
        XCTAssertTrue(AIResponseReader.shouldRetryOCR(lineCount: 1, averageConfidence: 0.95))
        XCTAssertTrue(AIResponseReader.shouldRetryOCR(lineCount: 5, averageConfidence: 0.60))
        XCTAssertFalse(AIResponseReader.shouldRetryOCR(lineCount: 5, averageConfidence: 0.88))
    }

    func testBilingualResponseFormatterKeepsTranslationAndLimitsSourcePreview() {
        XCTAssertEqual(
            BilingualResponseFormatter.display(
                source: "This is the source.",
                translation: "这是译文。"
            ),
            "原文\nThis is the source.\n\n译文\n这是译文。"
        )
        XCTAssertEqual(
            BilingualResponseFormatter.display(
                source: "abcdef",
                translation: "译文",
                sourceLimit: 3
            ),
            "原文\nabc…\n\n译文\n译文"
        )
    }

    func testResponseTextDeduplicationPrefersLeafParagraphs() {
        let first = "This is the first complete paragraph in the assistant response."
        let second = "This is the second complete paragraph with the final recommendation."
        let container = "\(first)\n\n\(second)"

        XCTAssertEqual(
            AIResponseReader.leafPreferredDeduplicated([container, first, second]),
            [first, second]
        )
    }

    func testSpeakerAttributedResponseChoosesChatGPTReplyInsteadOfUserPrompt() {
        let userPrompt = "Please answer in only one sentence in English: The input and output translation tests are normal."
        let assistantReply = "The input and output translation tests are functioning normally."

        let scan = AIResponseReader.speakerAttributedForeignResponse(from: [
            "你说：",
            userPrompt,
            "ChatGPT 说：",
            assistantReply,
            "ChatGPT 也可能会犯错。请核查重要信息。"
        ])

        XCTAssertTrue(scan.foundSpeakerMarkers)
        XCTAssertEqual(
            scan.response,
            DetectedForeignResponse(text: assistantReply, language: .english)
        )
    }

    func testSpeakerAttributedResponseUsesLatestAssistantTurn() {
        let latestReply = "The latest assistant response should be translated instead of the earlier conversation turn."
        let scan = AIResponseReader.speakerAttributedForeignResponse(from: [
            "You said:",
            "Please summarize the first topic in a concise and readable English paragraph.",
            "ChatGPT said:",
            "This is the first assistant response and it should no longer be selected.",
            "You said:",
            "Please explain the second topic with a clear recommendation and a short conclusion.",
            "ChatGPT said:",
            latestReply
        ])

        XCTAssertTrue(scan.foundSpeakerMarkers)
        XCTAssertEqual(scan.response?.text, latestReply)
        XCTAssertEqual(scan.response?.language, .english)
    }

    func testSpeakerAttributedResponseDropsChromeAndChatGPTInterfaceText() {
        let assistantReply = "The complete reply translation test is working normally."
        let scan = AIResponseReader.speakerAttributedForeignResponse(from: [
            "你说：",
            "Please reply with exactly one English sentence.",
            "ChatGPT 说：",
            assistantReply,
            "回复操作",
            "信息栏容器",
            "信息栏",
            "Google Chrome 不是您的默认浏览器"
        ])

        XCTAssertTrue(scan.foundSpeakerMarkers)
        XCTAssertEqual(
            scan.response,
            DetectedForeignResponse(text: assistantReply, language: .english)
        )
    }

    func testSpeakerAttributedResponseDropsExactApplicationAndWindowTitles() {
        let windowTitle = "ChatGPT Synthetic Response Test"
        let assistantReply = "The latest assistant reply should be translated without appending the window title."
        let rawTexts = [
            windowTitle,
            "You said:",
            "Please provide a short synthetic reply for this local regression test.",
            "ChatGPT said:",
            assistantReply,
            windowTitle
        ]

        let filtered = AIResponseReader.removingExactInterfaceChrome(
            from: rawTexts,
            labels: ["ChatGPT Synthetic Harness", windowTitle]
        )
        let scan = AIResponseReader.speakerAttributedForeignResponse(from: filtered)

        XCTAssertFalse(filtered.contains(windowTitle))
        XCTAssertTrue(scan.foundSpeakerMarkers)
        XCTAssertEqual(scan.response?.text, assistantReply)
        XCTAssertEqual(scan.response?.language, .english)
    }

    func testResponseReaderDropsAStandaloneAddressBarURL() {
        let reply = "Selection priority verification works correctly in a real ChatGPT response."
        let combined = "\(reply)\nchatgpt.com/?ref=mini"

        XCTAssertTrue(ResponseLanguageDetector.isSkippableLiteral("chatgpt.com/?ref=mini"))
        XCTAssertEqual(
            AIResponseReader.removingStandaloneResourceLines(from: combined),
            reply
        )
    }

    func testSpeakerMarkersPreventUserPromptFallbackBeforeAssistantReplies() {
        let scan = AIResponseReader.speakerAttributedForeignResponse(from: [
            "你说：",
            "Please translate this long user prompt, but there is no assistant reply available yet."
        ])

        XCTAssertTrue(scan.foundSpeakerMarkers)
        XCTAssertNil(scan.response)
    }

    func testChatGPTClassicStructureChoosesShortAssistantReply() {
        let prompt = "Please answer in only one sentence in English: The input and output translation tests are normal."
        let reply = "The input and output translation tests are functioning normally."

        let scan = AIResponseReader.assistantResponseFromAlternatingMessages([prompt, reply])

        XCTAssertTrue(scan.foundConversationStructure)
        XCTAssertEqual(
            scan.response,
            DetectedForeignResponse(text: reply, language: .english)
        )
    }

    func testChatGPTClassicStructureDoesNotTranslatePendingUserPrompt() {
        let scan = AIResponseReader.assistantResponseFromAlternatingMessages([
            "Please answer this pending user prompt in English."
        ])

        XCTAssertTrue(scan.foundConversationStructure)
        XCTAssertNil(scan.response)
    }

    func testChatGPTClassicStructureDoesNotFallBackWhenAssistantReplyIsChinese() {
        let scan = AIResponseReader.assistantResponseFromAlternatingMessages([
            "Please explain this in English.",
            "这是助手的中文回复，不应把前面的英文用户提示当作助手回复。"
        ])

        XCTAssertTrue(scan.foundConversationStructure)
        XCTAssertNil(scan.response)
    }

    func testResponseLanguageDetectorIgnoresBuildLogsAndPatches() {
        let buildLog = """
        Command line invocation:
            /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild -project ClaudePromptTranslator.xcodeproj build
        SwiftCompile normal arm64 Compiling AppDelegate.swift /Users/example/Projects/ClaudePromptTranslator/Sources/ClaudePromptTranslator/AppDelegate.swift
        CodeSign /tmp/ClaudePromptTranslatorXcodeDerivedData/Build/Products/Debug/ClaudePromptTranslator.app
        Test Suite 'All tests' passed at 2026-06-18.
        ** BUILD SUCCEEDED **
        """
        let patch = """
        *** Begin Patch
        *** Update File: Sources/ClaudePromptTranslator/AIResponseReader.swift
        @@
        -        if codeLinePrefixes.contains(where: { lowercased.hasPrefix($0) }) {
        +        if strictCodeLinePrefixes.contains(where: { lowercased.hasPrefix($0) }) {
        *** End Patch
        """

        XCTAssertNil(ResponseLanguageDetector.detect(in: buildLog))
        XCTAssertNil(ResponseLanguageDetector.detect(in: patch))
    }

    func testResponseLanguageDetectorSkipsNonProseContentLines() {
        let table = """
        | Name | Version | Status |
        | ClaudePromptTranslator | 1.0 | passing |
        | OutputTranslateButtonController.swift | changed | ok |
        """
        let json = """
        {
          "status": "ok",
          "path": "/Users/example/Projects/ClaudePromptTranslator/Sources/AppModel.swift"
        }
        """
        let prose = """
        This is a readable assistant reply with enough natural language to translate. It explains the behavior in full sentences, avoids code snippets, and keeps the content useful for a person reading the conversation.
        """

        XCTAssertFalse(ResponseLanguageDetector.isLikelyTranslatableProse(table))
        XCTAssertFalse(ResponseLanguageDetector.isLikelyTranslatableProse(json))
        XCTAssertTrue(ResponseLanguageDetector.isLikelyTranslatableProse(prose))
    }

    @MainActor
    func testInputTargetFiltersPlaceholdersAndDetectsCJKInput() {
        XCTAssertFalse(InputTarget.isMeaningfulInputText("Write a message…"))
        XCTAssertFalse(InputTarget.isTranslatableInputText("Message ChatGPT..."))
        XCTAssertFalse(InputTarget.isTranslatableInputText("问问 ChatGPT"))
        XCTAssertFalse(InputTarget.isTranslatableInputText("询问 ChatGPT…"))
        XCTAssertFalse(InputTarget.isTranslatableInputText("有问题，尽管问"))
        XCTAssertFalse(InputTarget.isTranslatableInputText("何でも聞いてください"))
        XCTAssertFalse(InputTarget.isTranslatableInputText("What is there to do in Japan?"))
        XCTAssertTrue(InputTarget.isTranslatableInputText("日本有什么好玩的，我喜欢迪斯尼"))
        XCTAssertTrue(InputTarget.isTranslatableInputText("東京ディズニーについて教えて"))
        XCTAssertFalse(InputTarget.isTranslatableInputText("Explain the Swift string \"中\"."))
        XCTAssertTrue(InputTarget.isTranslatableInputText("请把这段内容翻译成日文", to: .japanese))
        XCTAssertFalse(InputTarget.isTranslatableInputText("東京について教えて", to: .japanese))
        XCTAssertEqual(
            InputTarget.normalizedInputText("日本有什么好玩的，日本有什么好玩的，"),
            "日本有什么好玩的，"
        )
    }

    @MainActor
    func testInputTargetRecognizesChatComposerMetadataAndRejectsEditorFields() {
        XCTAssertTrue(InputTarget.hasChatComposerHint("Write your prompt to Claude"))
        XCTAssertTrue(InputTarget.hasChatComposerHint("Message ChatGPT"))
        XCTAssertTrue(InputTarget.hasChatComposerHint("prompt-textarea"))
        XCTAssertTrue(InputTarget.hasChatComposerHint("请输入消息"))

        XCTAssertTrue(InputTarget.hasExcludedInputHint("Search conversations"))
        XCTAssertTrue(InputTarget.hasExcludedInputHint("搜索聊天记录"))
        XCTAssertTrue(InputTarget.hasExcludedInputHint("Source Editor"))
        XCTAssertTrue(InputTarget.hasExcludedInputHint("Terminal input"))
        XCTAssertFalse(InputTarget.hasExcludedInputHint("Write a message"))
        XCTAssertTrue(InputTarget.accessibilityValueProvesInputIsEmpty(""))
        XCTAssertTrue(InputTarget.accessibilityValueProvesInputIsEmpty("  \n"))
        XCTAssertFalse(InputTarget.accessibilityValueProvesInputIsEmpty(nil))
        XCTAssertFalse(InputTarget.accessibilityValueProvesInputIsEmpty("请翻译这段"))
    }

    @MainActor
    func testInputCandidateScoringPrefersComposerSemanticsAndRejectsDistractors() throws {
        let window = NSRect(x: 100, y: 100, width: 1_000, height: 800)
        let bottomComposer = NSRect(x: 290, y: 145, width: 650, height: 48)
        let topField = NSRect(x: 290, y: 700, width: 650, height: 48)

        let genericScore = try XCTUnwrap(
            InputTarget.chatInputCandidateScore(
                metadata: "editable text area",
                rect: bottomComposer,
                windowRect: window
            )
        )
        let semanticScore = try XCTUnwrap(
            InputTarget.chatInputCandidateScore(
                metadata: "prompt-textarea Message ChatGPT",
                rect: bottomComposer,
                windowRect: window
            )
        )

        XCTAssertGreaterThan(semanticScore, genericScore)
        XCTAssertNil(
            InputTarget.chatInputCandidateScore(
                metadata: "Search conversations",
                rect: bottomComposer,
                windowRect: window,
                isFocused: true
            )
        )
        XCTAssertNil(
            InputTarget.chatInputCandidateScore(
                metadata: "editable text area",
                rect: topField,
                windowRect: window
            )
        )
    }

    func testCodexDesktopIsNotTreatedAsAIChatWindow() {
        XCTAssertTrue(
            ClaudeContextDetector.isExcludedAIApp(bundleIdentifier: "com.openai.codex")
        )
        XCTAssertFalse(
            ClaudeContextDetector.isExcludedAIApp(bundleIdentifier: "com.anthropic.claudefordesktop")
        )
    }

    @MainActor
    func testInputTargetPrefersSelectedTextAndKeepsReplacementRange() {
        let value = "开头内容 中间只翻译这一段 结尾内容"
        let range = (value as NSString).range(of: "中间只翻译这一段")

        let source = InputTarget.preferredTranslationSource(
            value: value,
            selectedText: "中间只翻译这一段",
            selectedRange: range
        )

        XCTAssertEqual(
            source,
            InputTranslationSource(
                text: "中间只翻译这一段",
                replacementScope: .selection(range: range, expectedText: "中间只翻译这一段")
            )
        )
        XCTAssertEqual(source?.usesSelection, true)
    }

    @MainActor
    func testInputSelectionTrimsWhitespaceWithoutReplacingIt() {
        let value = "开头  中间只翻译这一段  结尾"
        let selected = "  中间只翻译这一段  "
        let selectedRange = (value as NSString).range(of: selected)
        let translatedRange = (value as NSString).range(of: "中间只翻译这一段")

        let source = InputTarget.preferredTranslationSource(
            value: value,
            selectedText: selected,
            selectedRange: selectedRange
        )

        XCTAssertEqual(
            source?.replacementScope,
            .selection(range: translatedRange, expectedText: "中间只翻译这一段")
        )
    }

    @MainActor
    func testInputSelectionUsesRangeWhenAccessibilitySelectedTextIsWrong() {
        let value = "保留这部分，只翻译中间这一段，尾部保留"
        let range = (value as NSString).range(of: "只翻译中间这一段")

        let source = InputTarget.preferredTranslationSource(
            value: value,
            selectedText: value,
            selectedRange: range
        )

        XCTAssertEqual(source?.text, "只翻译中间这一段")
        XCTAssertEqual(
            source?.replacementScope,
            .selection(range: range, expectedText: "只翻译中间这一段")
        )
    }

    @MainActor
    func testWholeValueAccessibilitySelectionFallsBackToWholeInput() {
        let value = "请翻译完整输入"
        let source = InputTarget.preferredTranslationSource(
            value: value,
            selectedText: value,
            selectedRange: NSRange(location: 0, length: (value as NSString).length)
        )

        XCTAssertEqual(
            source,
            InputTranslationSource(
                text: value,
                replacementScope: .all(expectedValue: value)
            )
        )
    }

    @MainActor
    func testInputTargetFallsBackToWholeInputWithoutSelection() {
        let source = InputTarget.preferredTranslationSource(
            value: "  请翻译完整输入  ",
            selectedText: "",
            selectedRange: NSRange(location: 0, length: 0)
        )

        XCTAssertEqual(
            source,
            InputTranslationSource(
                text: "请翻译完整输入",
                replacementScope: .all(expectedValue: "  请翻译完整输入  ")
            )
        )
        XCTAssertEqual(source?.usesSelection, false)
    }

    func testTranslationRejectsOversizedInputBeforeNetworkRequest() async {
        let source = String(repeating: "中", count: TranslationLimits.maxInputCharacters + 1)

        do {
            _ = try await GoogleTranslateClient().translate(source, to: .english)
            XCTFail("Expected oversized input to be rejected")
        } catch let error as TranslationError {
            guard case .inputTooLong(let limit) = error else {
                return XCTFail("Unexpected translation error: \(error)")
            }
            XCTAssertEqual(limit, TranslationLimits.maxInputCharacters)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testTranslationUsesPOSTWithoutPuttingSourceTextInURL() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TranslationRequestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let source = "请总结这段内容"

        TranslationRequestURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertFalse(request.url?.absoluteString.contains(source) == true)
            let body = String(
                data: TranslationRequestURLProtocol.bodyData(for: request),
                encoding: .utf8
            ) ?? ""
            XCTAssertTrue(body.contains("q="))
            XCTAssertTrue(body.contains("tl=en"))

            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: request.url ?? URL(string: "https://translate.googleapis.com")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
            )
            let data = Data(#"[[["Please summarize this content.",null,null,null]],null,"zh-CN"]"#.utf8)
            return (response, data)
        }
        defer { TranslationRequestURLProtocol.handler = nil }

        let translation = try await GoogleTranslateClient(session: session).translate(source, to: .english)

        XCTAssertEqual(translation, "Please summarize this content.")
    }

    func testGoogleRateLimitFailsFastWithoutInteractiveRetries() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TranslationRequestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let recorder = TranslationRequestRecorder()

        TranslationRequestURLProtocol.handler = { request in
            recorder.record("request")
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: request.url ?? URL(string: "https://translate.googleapis.com")!,
                    statusCode: 429,
                    httpVersion: nil,
                    headerFields: ["Retry-After": "30"]
                )
            )
            return (response, Data())
        }
        defer { TranslationRequestURLProtocol.handler = nil }

        do {
            _ = try await GoogleTranslateClient(session: session)
                .translate("不应在交互点击中连续重试。", to: .english)
            XCTFail("Expected the rate limit to be surfaced")
        } catch let error as TranslationError {
            guard case .serverStatus(let code, _) = error else {
                return XCTFail("Unexpected translation error: \(error)")
            }
            XCTAssertEqual(code, 429)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(recorder.recordedValues.count, 1)
    }

    func testLongStructuredTranslationSplitsRequestsAndReassemblesExactly() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TranslationRequestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let recorder = TranslationRequestRecorder()
        let prose = (0..<900).map {
            "第\($0)段需要保持顺序，并兼容长文本翻译。"
        }.joined(separator: "\n")
        let source = """

          \(prose)

        ```swift
        let protectedValue = "代码不得翻译"
        ```

        最后一段必须保持在代码块之后。

        """
        XCTAssertGreaterThan(source.count, 16_000)
        XCTAssertLessThan(source.count, TranslationLimits.maxInputCharacters)

        TranslationRequestURLProtocol.handler = { request in
            let body = String(
                data: TranslationRequestURLProtocol.bodyData(for: request),
                encoding: .utf8
            ) ?? ""
            var components = URLComponents()
            components.percentEncodedQuery = body
            let query = try XCTUnwrap(
                components.queryItems?.first(where: { $0.name == "q" })?.value
            )
            recorder.record(query)

            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: request.url ?? URL(string: "https://translate.googleapis.com")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
            )
            let payload: [Any] = [[[query, NSNull(), NSNull(), NSNull()]], NSNull(), "zh-CN"]
            let data = try JSONSerialization.data(withJSONObject: payload)
            return (response, data)
        }
        defer { TranslationRequestURLProtocol.handler = nil }

        let translation = try await GoogleTranslateClient(session: session)
            .translate(source, to: .english)
        let requests = recorder.recordedValues
        let expectedRequestCount = TranslationChunker.chunks(for: source)
            .filter(\.shouldTranslate)
            .count

        XCTAssertEqual(translation, source)
        XCTAssertEqual(requests.count, expectedRequestCount)
        XCTAssertTrue(requests.allSatisfy { $0.count <= TranslationLimits.maxRequestCharacters })
        XCTAssertFalse(requests.contains { $0.contains("let protectedValue") })
    }

    func testTranslationRequestGateBoundsGlobalConcurrency() async throws {
        let gate = TranslationRequestGate(limit: 3)
        let tracker = RequestConcurrencyTracker()

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    try await gate.acquire()
                    tracker.begin()
                    try await Task.sleep(nanoseconds: 60_000_000)
                    tracker.end()
                    await gate.release()
                }
            }
            try await group.waitForAll()
        }

        XCTAssertLessThanOrEqual(tracker.maximum, 3)
        XCTAssertEqual(tracker.maximum, 3)
    }
}

private final class RequestConcurrencyTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private var maximumActive = 0

    var maximum: Int {
        lock.withLock { maximumActive }
    }

    func begin() {
        lock.withLock {
            active += 1
            maximumActive = max(maximumActive, active)
        }
    }

    func end() {
        lock.withLock {
            active -= 1
        }
    }
}

private final class TranslationRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    var recordedValues: [String] {
        lock.withLock { values }
    }

    func record(_ value: String) {
        lock.withLock {
            values.append(value)
        }
    }
}

private final class TranslationRequestURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: TranslationError.invalidResponse)
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    static func bodyData(for request: URLRequest) -> Data {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            return Data()
        }

        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
