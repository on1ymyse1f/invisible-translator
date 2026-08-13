import CoreGraphics
import Foundation

/// A frame is retained only while Vision is processing it or while it is the
/// single newest queued frame. It is never placed in the translation cache or
/// emitted to observers.
struct LiveSubtitleFrame: @unchecked Sendable {
    let sequence: UInt64
    let image: CGImage
    let hasVisualChange: Bool

    init(sequence: UInt64, image: CGImage, hasVisualChange: Bool = true) {
        self.sequence = sequence
        self.image = image
        self.hasVisualChange = hasVisualChange
    }
}

struct LiveSubtitleCadencePolicy: Equatable, Sendable {
    static let dynamicInterval: TimeInterval = 0.25
    static let staticInterval: TimeInterval = 0.5

    let unchangedFramesBeforeStatic: Int
    private(set) var consecutiveUnchangedFrames = 0

    init(unchangedFramesBeforeStatic: Int = 8) {
        self.unchangedFramesBeforeStatic = max(unchangedFramesBeforeStatic, 1)
    }

    var recommendedInterval: TimeInterval {
        consecutiveUnchangedFrames >= unchangedFramesBeforeStatic
            ? Self.staticInterval
            : Self.dynamicInterval
    }

    mutating func observe(hasVisualChange: Bool) -> TimeInterval {
        if hasVisualChange {
            consecutiveUnchangedFrames = 0
        } else {
            consecutiveUnchangedFrames = min(
                consecutiveUnchangedFrames + 1,
                unchangedFramesBeforeStatic
            )
        }
        return recommendedInterval
    }
}

struct LiveSubtitleFrameSubmission: Equatable, Sendable {
    let accepted: Bool
    let replacedPendingFrame: Bool
    let recommendedCaptureInterval: TimeInterval
}

enum LiveSubtitlePipelineEvent: Equatable, Sendable {
    case recognized(generation: UInt64, sequence: UInt64, text: String)
    case translationStarted(generation: UInt64, sequence: UInt64, text: String)
    case translated(
        generation: UInt64,
        sequence: UInt64,
        sourceText: String,
        output: TranslationProviderOutput,
        cacheHit: Bool
    )
    case recognitionFailed(generation: UInt64, sequence: UInt64, message: String)
    case translationFailed(generation: UInt64, sequence: UInt64, message: String)
    case stopped(generation: UInt64)
}

struct LiveSubtitlePipelineSession: Sendable {
    let generation: UInt64
    let events: AsyncStream<LiveSubtitlePipelineEvent>
}

actor LiveSubtitlePipeline {
    typealias Recognizer = @Sendable (LiveSubtitleFrame) async throws -> ScreenTextOCRResult
    typealias TargetResolver = @Sendable (String) -> TargetLanguage
    typealias Translator = @Sendable (
        _ text: String,
        _ target: TargetLanguage
    ) async throws -> TranslationProviderOutput

    private struct QueuedCue: Sendable {
        let generation: UInt64
        let sequence: UInt64
        let text: String
        let target: TargetLanguage
    }

    private let recognizer: Recognizer
    private let targetResolver: TargetResolver
    private let translator: Translator
    private let cache: SubtitleTranslationCache

    private var generation: UInt64 = 0
    private var cadencePolicy: LiveSubtitleCadencePolicy
    private var frameContinuation: AsyncStream<LiveSubtitleFrame>.Continuation?
    private var cueContinuation: AsyncStream<QueuedCue>.Continuation?
    private var eventContinuation: AsyncStream<LiveSubtitlePipelineEvent>.Continuation?
    private var recognitionTask: Task<Void, Never>?
    private var translationTask: Task<Void, Never>?

    init(
        cadencePolicy: LiveSubtitleCadencePolicy = LiveSubtitleCadencePolicy(),
        cache: SubtitleTranslationCache = SubtitleTranslationCache(),
        recognizer: Recognizer? = nil,
        targetResolver: @escaping TargetResolver,
        translator: @escaping Translator
    ) {
        self.cadencePolicy = cadencePolicy
        self.cache = cache
        self.recognizer = recognizer ?? Self.defaultRecognizer
        self.targetResolver = targetResolver
        self.translator = translator
    }

    func start() async -> LiveSubtitlePipelineSession {
        await stopCurrentSession(emitStopped: false)
        generation &+= 1
        let sessionGeneration = generation
        cadencePolicy = LiveSubtitleCadencePolicy(
            unchangedFramesBeforeStatic: cadencePolicy.unchangedFramesBeforeStatic
        )

        let frameChannel = AsyncStream<LiveSubtitleFrame>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let cueChannel = AsyncStream<QueuedCue>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let eventChannel = AsyncStream<LiveSubtitlePipelineEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(16)
        )
        frameContinuation = frameChannel.continuation
        cueContinuation = cueChannel.continuation
        eventContinuation = eventChannel.continuation

        recognitionTask = Task { [weak self] in
            guard let self else { return }
            await self.consumeFrames(frameChannel.stream, generation: sessionGeneration)
        }
        translationTask = Task { [weak self] in
            guard let self else { return }
            await self.consumeCues(cueChannel.stream, generation: sessionGeneration)
        }
        return LiveSubtitlePipelineSession(
            generation: sessionGeneration,
            events: eventChannel.stream
        )
    }

    func submitFrame(
        _ frame: LiveSubtitleFrame,
        generation submittedGeneration: UInt64
    ) -> LiveSubtitleFrameSubmission {
        guard submittedGeneration == generation,
              recognitionTask != nil,
              let frameContinuation else {
            return LiveSubtitleFrameSubmission(
                accepted: false,
                replacedPendingFrame: false,
                recommendedCaptureInterval: cadencePolicy.recommendedInterval
            )
        }
        let interval = cadencePolicy.observe(hasVisualChange: frame.hasVisualChange)

        let result = frameContinuation.yield(frame)
        let accepted: Bool
        let replaced: Bool
        switch result {
        case .enqueued:
            accepted = true
            replaced = false
        case .dropped:
            accepted = true
            replaced = true
        case .terminated:
            accepted = false
            replaced = false
        @unknown default:
            accepted = false
            replaced = false
        }
        return LiveSubtitleFrameSubmission(
            accepted: accepted,
            replacedPendingFrame: replaced,
            recommendedCaptureInterval: interval
        )
    }

    func recommendedCaptureInterval() -> TimeInterval {
        cadencePolicy.recommendedInterval
    }

    func stop() async {
        await stopCurrentSession(emitStopped: true)
    }

    private func consumeFrames(
        _ frames: AsyncStream<LiveSubtitleFrame>,
        generation sessionGeneration: UInt64
    ) async {
        var cueProcessor = SubtitleCueProcessor()
        for await frame in frames {
            guard !Task.isCancelled, sessionGeneration == generation else { break }
            do {
                let result = try await recognizer(frame)
                try Task.checkCancellation()
                guard sessionGeneration == generation else { continue }
                eventContinuation?.yield(
                    .recognized(
                        generation: sessionGeneration,
                        sequence: frame.sequence,
                        text: result.text
                    )
                )
                guard let cue = cueProcessor.observe(result.text) else { continue }
                let queuedCue = QueuedCue(
                    generation: sessionGeneration,
                    sequence: frame.sequence,
                    text: cue,
                    target: targetResolver(cue)
                )
                cueContinuation?.yield(queuedCue)
            } catch is CancellationError {
                break
            } catch {
                guard sessionGeneration == generation else { continue }
                eventContinuation?.yield(
                    .recognitionFailed(
                        generation: sessionGeneration,
                        sequence: frame.sequence,
                        message: Self.safeMessage(for: error)
                    )
                )
            }
        }
    }

    private func consumeCues(
        _ cues: AsyncStream<QueuedCue>,
        generation sessionGeneration: UInt64
    ) async {
        for await cue in cues {
            guard !Task.isCancelled,
                  cue.generation == sessionGeneration,
                  sessionGeneration == generation else { break }

            if let cached = await cache.value(for: cue.text, target: cue.target) {
                guard !Task.isCancelled, sessionGeneration == generation else { continue }
                eventContinuation?.yield(
                    .translated(
                        generation: sessionGeneration,
                        sequence: cue.sequence,
                        sourceText: cue.text,
                        output: cached,
                        cacheHit: true
                    )
                )
                continue
            }

            eventContinuation?.yield(
                .translationStarted(
                    generation: sessionGeneration,
                    sequence: cue.sequence,
                    text: cue.text
                )
            )
            do {
                let output = try await translator(cue.text, cue.target)
                try Task.checkCancellation()
                guard sessionGeneration == generation else { continue }
                await cache.insert(output, for: cue.text, target: cue.target)
                guard !Task.isCancelled, sessionGeneration == generation else { continue }
                eventContinuation?.yield(
                    .translated(
                        generation: sessionGeneration,
                        sequence: cue.sequence,
                        sourceText: cue.text,
                        output: output,
                        cacheHit: false
                    )
                )
            } catch is CancellationError {
                break
            } catch {
                guard sessionGeneration == generation else { continue }
                eventContinuation?.yield(
                    .translationFailed(
                        generation: sessionGeneration,
                        sequence: cue.sequence,
                        message: Self.safeMessage(for: error)
                    )
                )
            }
        }
    }

    private func stopCurrentSession(emitStopped: Bool) async {
        let stoppedGeneration = generation
        generation &+= 1
        frameContinuation?.finish()
        cueContinuation?.finish()
        recognitionTask?.cancel()
        translationTask?.cancel()
        frameContinuation = nil
        cueContinuation = nil
        recognitionTask = nil
        translationTask = nil
        await cache.removeAll()

        if emitStopped, stoppedGeneration > 0 {
            eventContinuation?.yield(.stopped(generation: stoppedGeneration))
        }
        eventContinuation?.finish()
        eventContinuation = nil
    }

    private nonisolated static func defaultRecognizer(
        _ frame: LiveSubtitleFrame
    ) async throws -> ScreenTextOCRResult {
        try Task.checkCancellation()
        let result = try ScreenTextOCRRecognizer.recognize(
            in: frame.image,
            profile: .liveSubtitle
        )
        try Task.checkCancellation()
        return result
    }

    private nonisolated static func safeMessage(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "字幕处理失败，请稍后重试。"
    }
}
