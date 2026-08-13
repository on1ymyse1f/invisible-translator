import CoreGraphics
import CoreVideo
import XCTest
@testable import ClaudePromptTranslator

final class LiveSubtitlePipelineTests: XCTestCase {
    func testGeneralOCRTilePlannerCoversLargeAreaWithinTwoMegapixels() {
        let source = CGRect(x: 10, y: 20, width: 3_840, height: 2_160)
        let budget = VisionTextRecognitionProfile.generalOCR.configuration.pixelBudget
        let tiles = OCRTilePlanner.tiles(
            in: source,
            pixelScale: 2,
            pixelBudget: budget
        )
        XCTAssertGreaterThan(tiles.count, 1)
        for tile in tiles {
            let pixels = Int(ceil(tile.width * 2)) * Int(ceil(tile.height * 2))
            XCTAssertLessThanOrEqual(pixels, budget)
            XCTAssertTrue(source.insetBy(dx: -0.5, dy: -0.5).contains(tile))
        }
        let union = tiles.reduce(CGRect.null) { $0.union($1) }
        XCTAssertEqual(union.minX, source.minX, accuracy: 0.5)
        XCTAssertEqual(union.minY, source.minY, accuracy: 0.5)
        XCTAssertEqual(union.maxX, source.maxX, accuracy: 0.5)
        XCTAssertEqual(union.maxY, source.maxY, accuracy: 0.5)
    }

    func testVisionProfilesBoundCapturePixelsAndAccurateRetryDecision() {
        let configuration = VisionTextRecognitionProfile.liveSubtitle.configuration
        XCTAssertEqual(configuration.pixelBudget, 786_432)

        let fitted = configuration.fittedPixelSize(width: 6_000, height: 4_000)
        XCTAssertLessThanOrEqual(fitted.width * fitted.height, configuration.pixelBudget)
        XCTAssertEqual(Double(fitted.width) / Double(fitted.height), 1.5, accuracy: 0.01)
        XCTAssertEqual(
            configuration.fittedPixelSize(width: 640, height: 360).width,
            640
        )

        XCTAssertTrue(
            configuration.shouldRunAccuratePass(
                lineCount: 0,
                recognizedCharacterCount: 0,
                averageConfidence: 0
            )
        )
        XCTAssertTrue(
            configuration.shouldRunAccuratePass(
                lineCount: 1,
                recognizedCharacterCount: 40,
                averageConfidence: 0.4
            )
        )
        XCTAssertFalse(
            configuration.shouldRunAccuratePass(
                lineCount: 2,
                recognizedCharacterCount: 40,
                averageConfidence: 0.9
            )
        )
    }

    func testProductionSubtitleFrameCarriesPixelBufferWithoutCGImage() throws {
        let pixelBuffer = try makePixelBuffer(width: 64, height: 36)
        let frame = LiveSubtitleFrame(sequence: 1, pixelBuffer: pixelBuffer)

        XCTAssertNotNil(frame.pixelBuffer)
        XCTAssertNil(frame.testImage)
        XCTAssertEqual(CVPixelBufferGetWidth(try XCTUnwrap(frame.pixelBuffer)), 64)
        XCTAssertEqual(CVPixelBufferGetHeight(try XCTUnwrap(frame.pixelBuffer)), 36)
    }

    func testLatestPixelBufferSlotRetainsOnlyOneAndRejectsFramesAfterStop() throws {
        let slot = SubtitleLatestPixelBufferSlot()
        let first = try makePixelBuffer(width: 32, height: 18)
        let second = try makePixelBuffer(width: 64, height: 36)

        XCTAssertTrue(slot.offer(first))
        XCTAssertTrue(slot.offer(second))
        let latest = try XCTUnwrap(slot.take())
        XCTAssertEqual(CVPixelBufferGetWidth(latest), 64)
        XCTAssertNil(slot.take())

        XCTAssertTrue(slot.offer(first))
        slot.stopAndDiscard()
        XCTAssertNil(slot.take())
        XCTAssertFalse(slot.offer(second))
    }

    func testSubtitleSimilarityStabilizesMinorOCRJitterWithoutDuplicateEmission() {
        XCTAssertGreaterThan(
            SubtitleTextSimilarity.score(
                "Welcome to the translation demo",
                "Welcome to the transIation demo"
            ),
            0.92
        )

        var processor = SubtitleCueProcessor()
        XCTAssertNil(processor.observe("Welcome to the translation demo"))
        XCTAssertEqual(
            processor.observe("Welcome to the translation demo."),
            "Welcome to the translation demo."
        )
        XCTAssertNil(processor.observe("Welcome to the translation demo"))
        XCTAssertNil(processor.observe("A materially different subtitle"))
        XCTAssertEqual(
            processor.observe("A materially different subtitle"),
            "A materially different subtitle"
        )
    }

    func testCadenceMovesFromDynamicFourFPSIntoStaticTwoFPSAndBack() {
        var policy = LiveSubtitleCadencePolicy(unchangedFramesBeforeStatic: 3)
        XCTAssertEqual(policy.recommendedInterval, 0.25)
        XCTAssertEqual(policy.observe(hasVisualChange: false), 0.25)
        XCTAssertEqual(policy.observe(hasVisualChange: false), 0.25)
        XCTAssertEqual(policy.observe(hasVisualChange: false), 0.5)
        XCTAssertEqual(policy.observe(hasVisualChange: true), 0.25)
    }

    func testSubtitleCacheIsCountTTLAndByteBounded() async {
        let cache = SubtitleTranslationCache(
            capacity: 10,
            timeToLive: 180,
            maximumBytes: 150
        )
        let now = Date(timeIntervalSince1970: 1_000)
        for index in 0..<3 {
            await cache.insert(
                TranslationProviderOutput(
                    text: String(repeating: Character(String(index)), count: 30),
                    providerName: "test"
                ),
                for: "subtitle-\(index)",
                target: .simplifiedChinese,
                now: now
            )
        }
        let statistics = await cache.statistics(now: now)
        XCTAssertLessThanOrEqual(statistics.byteCount, 150)
        XCTAssertEqual(statistics.entryCount, 1)

        await cache.insert(
            TranslationProviderOutput(
                text: String(repeating: "x", count: 200),
                providerName: "test"
            ),
            for: "oversized",
            target: .simplifiedChinese,
            now: now
        )
        let oversizedValue = await cache.value(
            for: "oversized",
            target: .simplifiedChinese,
            now: now
        )
        XCTAssertNil(oversizedValue)

        let defaults = SubtitleTranslationCache()
        for index in 0..<65 {
            await defaults.insert(
                TranslationProviderOutput(text: "v", providerName: "t"),
                for: "cue-\(index)",
                target: .english,
                now: now
            )
        }
        let defaultStatistics = await defaults.statistics(now: now)
        XCTAssertEqual(defaultStatistics.entryCount, 64)
        let expiredValue = await defaults.value(
            for: "cue-64",
            target: .english,
            now: now.addingTimeInterval(181)
        )
        XCTAssertNil(expiredValue)
    }

    func testLatestFrameQueueReplacesPendingFrame() async throws {
        let image = try makeImage()
        let gate = RecognitionGate()
        let pipeline = LiveSubtitlePipeline(
            recognizer: { frame in await gate.recognize(frame) },
            targetResolver: { _ in .simplifiedChinese },
            translator: { text, _ in
                TranslationProviderOutput(text: text, providerName: "test")
            }
        )
        let session = await pipeline.start()

        _ = await pipeline.submitFrame(
            LiveSubtitleFrame(sequence: 1, image: image),
            generation: session.generation
        )
        let firstStarted = await eventually { await gate.sequences().contains(1) }
        XCTAssertTrue(firstStarted)
        _ = await pipeline.submitFrame(
            LiveSubtitleFrame(sequence: 2, image: image),
            generation: session.generation
        )
        let third = await pipeline.submitFrame(
            LiveSubtitleFrame(sequence: 3, image: image),
            generation: session.generation
        )
        XCTAssertTrue(third.accepted)
        XCTAssertTrue(third.replacedPendingFrame)

        await gate.releaseFirstRecognition()
        let thirdProcessed = await eventually { await gate.sequences().contains(3) }
        XCTAssertTrue(thirdProcessed)
        let processedSequences = await gate.sequences()
        XCTAssertFalse(processedSequences.contains(2))
        await pipeline.stop()
    }

    func testTranslationDoesNotBlockOCRAndCueQueueKeepsOnlyLatest() async throws {
        let image = try makeImage()
        let recognition = RecognitionProbe()
        let translation = TranslationGate()
        let recorder = EventRecorder()
        let pipeline = LiveSubtitlePipeline(
            recognizer: { frame in await recognition.recognize(frame) },
            targetResolver: { _ in .simplifiedChinese },
            translator: { text, _ in await translation.translate(text) }
        )
        let session = await pipeline.start()
        let eventTask = Task {
            for await event in session.events {
                await recorder.append(event)
            }
        }

        for sequence in 1...6 {
            _ = await pipeline.submitFrame(
                LiveSubtitleFrame(sequence: UInt64(sequence), image: image),
                generation: session.generation
            )
            let recognized = await eventually {
                await recognition.sequences().contains(UInt64(sequence))
            }
            XCTAssertTrue(recognized)
            if sequence == 2 {
                let translationStarted = await eventually {
                    await translation.started().count == 1
                }
                XCTAssertTrue(translationStarted)
            }
        }

        let recognizedSequences = await recognition.sequences()
        let startedTranslations = await translation.started()
        XCTAssertEqual(recognizedSequences.count, 6)
        XCTAssertEqual(startedTranslations, ["First stable subtitle"])
        await translation.releaseFirstTranslation()
        let translationsCompleted = await eventually {
            await translation.completed().count == 2
        }
        XCTAssertTrue(translationsCompleted)
        let completedTranslations = await translation.completed()
        XCTAssertEqual(
            completedTranslations,
            ["First stable subtitle", "Third stable subtitle"]
        )
        let latestDelivered = await eventually {
            await recorder.events().contains { event in
                guard case let .translated(_, sequence, sourceText, output, cacheHit) = event
                else { return false }
                return sequence == 6
                    && sourceText == "Third stable subtitle"
                    && output.text == "translated: Third stable subtitle"
                    && !cacheHit
            }
        }
        XCTAssertTrue(latestDelivered)
        await pipeline.stop()
        await eventTask.value

        let events = await recorder.events()
        let startedEvents = events.compactMap { event -> String? in
            guard case let .translationStarted(_, sequence, text) = event else { return nil }
            return "\(sequence):\(text)"
        }
        XCTAssertEqual(
            startedEvents,
            [
                "2:First stable subtitle",
                "6:Third stable subtitle",
            ]
        )

        let translatedEvents = events.compactMap {
            event -> String? in
            guard case let .translated(_, sequence, sourceText, output, cacheHit) = event
            else { return nil }
            return "\(sequence):\(sourceText):\(output.text):\(cacheHit)"
        }
        XCTAssertEqual(
            translatedEvents,
            ["6:Third stable subtitle:translated: Third stable subtitle:false"]
        )
        XCTAssertFalse(events.contains { event in
            if case .translationFailed = event { return true }
            return false
        })
    }

    func testOnDeviceSpeechTextUsesTheSharedStableTranslationPipeline() async {
        let translation = TranslationGate()
        let pipeline = LiveSubtitlePipeline(
            targetResolver: { _ in .simplifiedChinese },
            translator: { text, _ in await translation.translate(text) }
        )
        let session = await pipeline.start()

        let accepted = await pipeline.submitRecognizedText(
            "A spoken subtitle",
            sequence: 1,
            generation: session.generation,
            isFinal: true
        )
        XCTAssertTrue(accepted)
        let started = await eventually { await translation.started().count == 1 }
        XCTAssertTrue(started)
        let startedTexts = await translation.started()
        XCTAssertEqual(startedTexts, ["A spoken subtitle"])

        await translation.releaseFirstTranslation()
        await pipeline.stop()
    }

    func testStopAndGenerationDiscardLateTranslationAndStaleFrames() async throws {
        let image = try makeImage()
        let translation = TranslationGate()
        let recorder = EventRecorder()
        let pipeline = LiveSubtitlePipeline(
            recognizer: { _ in
                ScreenTextOCRResult(
                    text: "Stable subtitle before stop",
                    lineCount: 1,
                    averageConfidence: 0.9
                )
            },
            targetResolver: { _ in .simplifiedChinese },
            translator: { text, _ in await translation.translate(text) }
        )
        let session = await pipeline.start()
        let eventTask = Task {
            for await event in session.events {
                await recorder.append(event)
            }
        }

        for sequence in 1...2 {
            _ = await pipeline.submitFrame(
                LiveSubtitleFrame(sequence: UInt64(sequence), image: image),
                generation: session.generation
            )
            try await Task.sleep(for: .milliseconds(20))
        }
        let translationStarted = await eventually {
            await translation.started().count == 1
        }
        XCTAssertTrue(translationStarted)
        await pipeline.stop()
        await translation.releaseFirstTranslation()
        await eventTask.value

        let recordedEvents = await recorder.events()
        let containsLateTranslation = recordedEvents.contains { event in
            if case .translated = event { return true }
            return false
        }
        XCTAssertFalse(containsLateTranslation)

        let nextSession = await pipeline.start()
        let staleSubmission = await pipeline.submitFrame(
            LiveSubtitleFrame(sequence: 3, image: image),
            generation: session.generation
        )
        XCTAssertFalse(staleSubmission.accepted)
        XCTAssertNotEqual(nextSession.generation, session.generation)
        await pipeline.stop()
    }

    func testGenerationScopedStopCannotTerminateReplacementSession() async {
        let pipeline = LiveSubtitlePipeline(
            targetResolver: { _ in .simplifiedChinese },
            translator: { text, _ in
                TranslationProviderOutput(text: text, providerName: "test")
            }
        )
        let first = await pipeline.start()
        let replacement = await pipeline.start()

        await pipeline.stop(generation: first.generation)
        let accepted = await pipeline.submitRecognizedText(
            "replacement remains active",
            sequence: 1,
            generation: replacement.generation,
            isFinal: true
        )

        XCTAssertTrue(accepted)
        await pipeline.stop(generation: replacement.generation)
    }

    private func makeImage() throws -> CGImage {
        let context = try XCTUnwrap(
            CGContext(
                data: nil,
                width: 2,
                height: 2,
                bitsPerComponent: 8,
                bytesPerRow: 8,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        return try XCTUnwrap(context.makeImage())
    }

    private func makePixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
            &pixelBuffer
        )
        XCTAssertEqual(status, kCVReturnSuccess)
        return try XCTUnwrap(pixelBuffer)
    }

    private func eventually(
        timeout: TimeInterval = 1,
        condition: @escaping () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }
}

private actor RecognitionGate {
    private var observedSequences: [UInt64] = []
    private var firstContinuation: CheckedContinuation<Void, Never>?

    func recognize(_ frame: LiveSubtitleFrame) async -> ScreenTextOCRResult {
        observedSequences.append(frame.sequence)
        if frame.sequence == 1 {
            await withCheckedContinuation { continuation in
                firstContinuation = continuation
            }
        }
        return ScreenTextOCRResult(
            text: "frame-\(frame.sequence)",
            lineCount: 1,
            averageConfidence: 0.9
        )
    }

    func sequences() -> [UInt64] { observedSequences }

    func releaseFirstRecognition() {
        firstContinuation?.resume()
        firstContinuation = nil
    }
}

private actor RecognitionProbe {
    private var observedSequences: [UInt64] = []

    func recognize(_ frame: LiveSubtitleFrame) -> ScreenTextOCRResult {
        observedSequences.append(frame.sequence)
        let text: String
        switch frame.sequence {
        case 1...2: text = "First stable subtitle"
        case 3...4: text = "Second stable subtitle"
        default: text = "Third stable subtitle"
        }
        return ScreenTextOCRResult(text: text, lineCount: 1, averageConfidence: 0.9)
    }

    func sequences() -> [UInt64] { observedSequences }
}

private actor TranslationGate {
    private var startedTexts: [String] = []
    private var completedTexts: [String] = []
    private var firstContinuation: CheckedContinuation<Void, Never>?

    func translate(_ text: String) async -> TranslationProviderOutput {
        startedTexts.append(text)
        if startedTexts.count == 1 {
            await withCheckedContinuation { continuation in
                firstContinuation = continuation
            }
        }
        completedTexts.append(text)
        return TranslationProviderOutput(text: "translated: \(text)", providerName: "test")
    }

    func started() -> [String] { startedTexts }
    func completed() -> [String] { completedTexts }

    func releaseFirstTranslation() {
        firstContinuation?.resume()
        firstContinuation = nil
    }
}

private actor EventRecorder {
    private var storedEvents: [LiveSubtitlePipelineEvent] = []

    func append(_ event: LiveSubtitlePipelineEvent) {
        storedEvents.append(event)
    }

    func events() -> [LiveSubtitlePipelineEvent] { storedEvents }
}
