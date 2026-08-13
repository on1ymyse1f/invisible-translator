import AppKit
import AVFAudio
import CoreMedia
import ScreenCaptureKit

#if canImport(Speech)
@preconcurrency import Speech
#endif

/// Events emitted by one explicit, source-application-only system ASR session.
/// Audio is passed directly from ScreenCaptureKit to Apple Speech and is never
/// written to a file or retained after the active recognition request consumes it.
enum SubtitleSpeechSessionEvent: Equatable, Sendable {
    case started(generation: UInt64, engine: SystemSpeechEngineKind)
    case partial(generation: UInt64, text: String)
    case final(generation: UInt64, text: String)
    case stopped(generation: UInt64)
    case cancelled(generation: UInt64)
    case failed(generation: UInt64, message: String)
}

struct SubtitleSpeechSessionHandle: Sendable {
    let generation: UInt64
    let events: AsyncStream<SubtitleSpeechSessionEvent>
}

enum SubtitleSpeechSessionError: LocalizedError, Equatable {
    case speechAuthorizationDenied
    case screenRecordingPermissionRequired
    case sourceApplicationUnavailable
    case onDeviceRecognitionUnavailable
    case onDeviceSpeechAssetUnavailable

    var errorDescription: String? {
        switch self {
        case .speechAuthorizationDenied:
            return "系统语音识别权限未获授权。"
        case .screenRecordingPermissionRequired:
            return "捕获目标 App 音频需要屏幕录制权限。"
        case .sourceApplicationUnavailable:
            return "目标 App 当前没有可共享的窗口。"
        case .onDeviceRecognitionUnavailable:
            return "此语言没有可用的设备端系统语音识别。"
        case .onDeviceSpeechAssetUnavailable:
            return "此语言的 Apple 设备端语音资源尚未安装。"
        }
    }
}

/// Values applied to every ScreenCaptureKit stream. Keeping this policy pure
/// makes the privacy-sensitive capture choices independently testable.
struct SubtitleSpeechCapturePolicy: Equatable, Sendable {
    let capturesAudio = true
    let excludesCurrentProcessAudio = true
    let sampleRate = 48_000
    let channelCount = 1

    func apply(to configuration: SCStreamConfiguration) {
        configuration.capturesAudio = capturesAudio
        configuration.excludesCurrentProcessAudio = excludesCurrentProcessAudio
        configuration.captureMicrophone = false
        configuration.sampleRate = sampleRate
        configuration.channelCount = channelCount
        configuration.queueDepth = 2
        configuration.showsCursor = false
        // No screen output is registered for this stream. Keep the unused
        // video surface minimal so an audio-only session cannot inherit a
        // display-sized allocation from ScreenCaptureKit defaults.
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
    }
}

/// Bounds each legacy `SFSpeechAudioBufferRecognitionRequest`. Apple does not
/// expose its internal buffering, so the only enforceable cap is to finish and
/// replace the request before either the duration or an uncompressed
/// float-equivalent byte budget is exceeded.
struct LegacySpeechSegmentPolicy: Equatable, Sendable {
    let maximumDuration: TimeInterval = 12
    let maximumEstimatedBytes = 768 * 1_024

    func maximumFrames(
        sampleRate: Double,
        channelCount: Int,
        bytesPerSample: Int = MemoryLayout<Float>.size
    ) -> Int64 {
        let safeRate = max(sampleRate, 1)
        let safeChannels = max(channelCount, 1)
        let safeBytes = max(bytesPerSample, 1)
        let durationFrames = Int64((safeRate * maximumDuration).rounded(.down))
        let byteFrames = Int64(maximumEstimatedBytes / (safeChannels * safeBytes))
        return max(min(durationFrames, byteFrames), 1)
    }

    func shouldRotate(
        accumulatedFrames: Int64,
        incomingFrames: Int64,
        sampleRate: Double,
        channelCount: Int
    ) -> Bool {
        let limit = maximumFrames(
            sampleRate: sampleRate,
            channelCount: channelCount
        )
        guard incomingFrames <= limit else { return false }
        guard accumulatedFrames > 0 else { return false }
        return accumulatedFrames + max(incomingFrames, 0) > limit
    }

    func acceptsIndividualBuffer(
        frames: Int64,
        sampleRate: Double,
        channelCount: Int
    ) -> Bool {
        frames >= 0 && frames <= maximumFrames(
            sampleRate: sampleRate,
            channelCount: channelCount
        )
    }
}

/// Generation checks are intentionally shared by both legacy callback results
/// and macOS 26 `SpeechTranscriber.results`, so a prior session can never emit
/// into a newer session's stream.
enum SubtitleSpeechGenerationGate {
    static func accepts(emittedGeneration: UInt64, activeGeneration: UInt64?) -> Bool {
        emittedGeneration == activeGeneration
    }
}

/// Keeps callback ownership checks independently testable without requiring a
/// live ScreenCaptureKit stream. The check is performed while the session lock
/// is held before any generation or recognition runtime is snapshotted.
enum SubtitleSpeechStreamIdentityGate {
    static func accepts<Stream: AnyObject>(activeStream: Stream?, callbackStream: Stream) -> Bool {
        activeStream === callbackStream
    }
}

/// An independent system ASR chain for a user-selected application. It has no
/// dependency on the OCR subtitle pipeline or AppModel; a future coordinator
/// can consume `SubtitleSpeechSessionHandle.events` and bridge the text itself.
final class SubtitleSpeechSession: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private struct ReleasedResources {
        let generation: UInt64?
        let stream: SCStream?
        let continuation: AsyncStream<SubtitleSpeechSessionEvent>.Continuation?
        #if canImport(Speech)
        let request: SFSpeechAudioBufferRecognitionRequest?
        let task: SFSpeechRecognitionTask?
        #endif
        let analyzerRuntime: AnyObject?
    }

    private let lock = NSLock()
    private let outputQueue = DispatchQueue(
        label: "local.codex.ClaudePromptTranslator.subtitle-speech-audio",
        qos: .userInitiated
    )
    private let capturePolicy: SubtitleSpeechCapturePolicy
    private let legacySegmentPolicy = LegacySpeechSegmentPolicy()
    private let capturePermissionCheck: @Sendable () -> Bool

    private var startLifecycle = CaptureStartLifecycle()
    private var continuation: AsyncStream<SubtitleSpeechSessionEvent>.Continuation?
    private var stream: SCStream?

    #if canImport(Speech)
    private var legacyRecognizer: SFSpeechRecognizer?
    private var legacyRequest: SFSpeechAudioBufferRecognitionRequest?
    private var legacyTask: SFSpeechRecognitionTask?
    private var legacySegmentID: UInt64 = 0
    private var legacySegmentFrames: Int64 = 0
    #endif

    /// Type-erased so this macOS 15 deployment target does not expose a
    /// macOS-26-only stored-property type. Every downcast is availability
    /// checked at its use site.
    private var analyzerRuntime: AnyObject?
    private var permissionLastCheckedUptime: TimeInterval = 0
    private var permissionLastValue = true

    init(
        capturePolicy: SubtitleSpeechCapturePolicy = SubtitleSpeechCapturePolicy(),
        capturePermissionCheck: @escaping @Sendable () -> Bool = {
            ScreenRecordingPermission.isGranted
        }
    ) {
        self.capturePolicy = capturePolicy
        self.capturePermissionCheck = capturePermissionCheck
        super.init()
    }

    /// Requests Speech permission when needed, then starts an audio-only
    /// ScreenCaptureKit stream whose filter includes windows owned only by the
    /// explicitly supplied target application.
    @MainActor
    func start(
        sourceApplication: NSRunningApplication,
        localeIdentifier: String,
        authorizationCheck: @escaping @MainActor () -> Bool = { true }
    ) async throws -> SubtitleSpeechSessionHandle {
        await stopInternal(cancelled: true, emitTerminalEvent: false)
        guard authorizationCheck(), capturePermissionCheck() else {
            throw SubtitleSpeechSessionError.screenRecordingPermissionRequired
        }
        try await Self.ensureSpeechAuthorization()
        guard authorizationCheck(), capturePermissionCheck() else {
            throw CancellationError()
        }

        let eventChannel = AsyncStream<SubtitleSpeechSessionEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        guard let startToken = beginSession(continuation: eventChannel.continuation) else {
            eventChannel.continuation.finish()
            throw CancellationError()
        }
        let sessionGeneration = startToken.generation
        var createdStream: SCStream?

        do {
            let filter = try await Self.sourceApplicationFilter(for: sourceApplication)
            guard authorizationCheck(), capturePermissionCheck() else {
                throw CancellationError()
            }
            let configuration = SCStreamConfiguration()
            capturePolicy.apply(to: configuration)
            let streamForThisStart = SCStream(
                filter: filter,
                configuration: configuration,
                delegate: self
            )
            createdStream = streamForThisStart
            try streamForThisStart.addStreamOutput(
                self,
                type: .audio,
                sampleHandlerQueue: outputQueue
            )

            let engine = try await startRecognition(
                localeIdentifier: localeIdentifier,
                generation: sessionGeneration
            )
            guard authorizationCheck(), capturePermissionCheck() else {
                throw CancellationError()
            }
            let shouldStart = lock.withLock {
                let isCurrent = startLifecycle.accepts(startToken)
                    && activeGenerationLocked == sessionGeneration
                if isCurrent { stream = streamForThisStart }
                return isCurrent
            }
            guard shouldStart else { throw CancellationError() }

            try await streamForThisStart.startCapture()
            let retained = lock.withLock {
                stream === streamForThisStart && startLifecycle.markStarted(startToken)
            }
            guard retained else {
                // A stop may have invalidated and stopped this stream while
                // startCapture was suspended. Stop the local stream after the
                // start returns so it cannot escape the session unowned.
                try? await streamForThisStart.stopCapture()
                throw CancellationError()
            }
            guard authorizationCheck(), capturePermissionCheck() else {
                throw CancellationError()
            }
            emit(.started(generation: sessionGeneration, engine: engine), generation: sessionGeneration)
            return SubtitleSpeechSessionHandle(
                generation: sessionGeneration,
                events: eventChannel.stream
            )
        } catch {
            // This stream belongs to this invocation, not necessarily to the
            // generation that is current now. Always stop it locally before
            // generation-gated shared-state cleanup; otherwise a failed old
            // start can escape after a replacement session has taken over.
            if let createdStream {
                try? await createdStream.stopCapture()
            }
            await stopInternal(
                cancelled: true,
                emitTerminalEvent: false,
                expectedGeneration: sessionGeneration
            )
            eventChannel.continuation.finish()
            throw error
        }
    }

    func stop() async {
        await stopInternal(cancelled: false, emitTerminalEvent: true)
    }

    func cancel() async {
        await stopInternal(cancelled: true, emitTerminalEvent: true)
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .audio,
              CMSampleBufferIsValid(sampleBuffer) else {
            return
        }

        let snapshot = lock.withLock { () -> (generation: UInt64, runtime: AnyObject?)? in
            guard SubtitleSpeechStreamIdentityGate.accepts(
                activeStream: self.stream,
                callbackStream: stream
            ), let generation = activeGenerationLocked else {
                return nil
            }
            return (generation, analyzerRuntime)
        }
        guard let snapshot else { return }
        let sessionGeneration = snapshot.generation
        guard capturePermissionRemainsGranted() else {
            failAndStop(
                message: "屏幕录制权限已撤销，设备端语音字幕已停止。",
                generation: sessionGeneration
            )
            return
        }
        guard let buffer = SubtitleSpeechAudioBridge.pcmBuffer(from: sampleBuffer) else {
            return
        }
        let runtime = snapshot.runtime
        #if canImport(Speech)
        // `legacyRequestForAppending` owns its lock acquisition because a
        // rolling segment replaces multiple fields atomically. Never call it
        // while holding the non-recursive session lock.
        let request = legacyRequestForAppending(buffer, generation: sessionGeneration)
        if let request {
            let stillCurrent = lock.withLock {
                guard activeGenerationLocked == sessionGeneration,
                      legacyRequest === request else { return false }
                return true
            }
            if stillCurrent {
                // Do not call Apple APIs while holding our state lock: a
                // synchronous recognition callback may re-enter `emit`.
                // stopInternal drains outputQueue before endAudio/cancel, so
                // this append still completes before resource teardown.
                request.append(buffer)
                return
            }
        }
        #endif
        if #available(macOS 26.0, *),
           let runtime = runtime as? SubtitleSpeechAnalyzerRuntime {
            let stillCurrent = lock.withLock {
                guard activeGenerationLocked == sessionGeneration,
                      analyzerRuntime === runtime else { return false }
                return true
            }
            if stillCurrent {
                // AsyncStream.yield is an external call as well; keep it out of
                // the state lock and rely on the same output-queue drain.
                runtime.append(
                    buffer,
                    presentationTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                )
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let stoppedGeneration = lock.withLock {
            self.stream === stream ? activeGenerationLocked : nil
        }
        guard let stoppedGeneration else { return }
        failAndStop(
            message: "目标 App 的音频捕获已中断。",
            generation: stoppedGeneration
        )
    }

    private var activeGenerationLocked: UInt64? {
        guard continuation != nil else { return nil }
        return startLifecycle.activeToken?.generation
    }

    private func beginSession(
        continuation: AsyncStream<SubtitleSpeechSessionEvent>.Continuation
    ) -> CaptureStartToken? {
        lock.withLock {
            guard let token = startLifecycle.beginStart() else { return nil }
            self.continuation = continuation
            permissionLastCheckedUptime = 0
            permissionLastValue = true
            return token
        }
    }

    /// Audio callbacks can arrive far more often than video frames. Recheck
    /// TCC at most four times per second so revocation is observed promptly
    /// without invoking the system preflight API for every PCM packet.
    private func capturePermissionRemainsGranted() -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        if let cached = lock.withLock({ () -> Bool? in
            guard now - permissionLastCheckedUptime < 0.25 else { return nil }
            return permissionLastValue
        }) {
            return cached
        }
        let granted = capturePermissionCheck()
        lock.withLock {
            permissionLastCheckedUptime = now
            permissionLastValue = granted
        }
        return granted
    }

    private func startRecognition(
        localeIdentifier: String,
        generation: UInt64
    ) async throws -> SystemSpeechEngineKind {
        #if canImport(Speech)
        if #available(macOS 26.0, *) {
            let runtime = try await SubtitleSpeechAnalyzerRuntime(
                localeIdentifier: localeIdentifier,
                generation: generation,
                eventSink: { [weak self] event, eventGeneration in
                    if case let .failed(_, message) = event {
                        self?.failAndStop(message: message, generation: eventGeneration)
                    } else {
                        self?.emit(event, generation: eventGeneration)
                    }
                }
            )
            let isCurrent = lock.withLock {
                let active = SubtitleSpeechGenerationGate.accepts(
                    emittedGeneration: generation,
                    activeGeneration: activeGenerationLocked
                )
                if active { analyzerRuntime = runtime }
                return active
            }
            guard isCurrent else {
                await runtime.cancel()
                throw CancellationError()
            }
            return .speechAnalyzer
        }

        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)),
              recognizer.isAvailable,
              recognizer.supportsOnDeviceRecognition else {
            throw SubtitleSpeechSessionError.onDeviceRecognitionUnavailable
        }
        let segmentID: UInt64 = 1
        let segment = makeLegacySegment(
            recognizer: recognizer,
            generation: generation,
            segmentID: segmentID
        )
        let isCurrent = lock.withLock {
            let active = SubtitleSpeechGenerationGate.accepts(
                emittedGeneration: generation,
                activeGeneration: activeGenerationLocked
            )
            if active {
                legacyRecognizer = recognizer
                legacyRequest = segment.request
                legacyTask = segment.task
                legacySegmentID = segmentID
                legacySegmentFrames = 0
            }
            return active
        }
        guard isCurrent else {
            segment.task.cancel()
            throw CancellationError()
        }
        return .sfSpeechRecognizer
        #else
        _ = localeIdentifier
        _ = generation
        throw SubtitleSpeechSessionError.onDeviceRecognitionUnavailable
        #endif
    }

    private func stopInternal(
        cancelled: Bool,
        emitTerminalEvent: Bool,
        expectedGeneration: UInt64? = nil
    ) async {
        let released = lock.withLock { () -> ReleasedResources? in
            let stoppedGeneration = activeGenerationLocked
            if let expectedGeneration, stoppedGeneration != expectedGeneration {
                return nil
            }
            _ = startLifecycle.invalidate()
            let activeStream = stream
            stream = nil
            let terminalContinuation = continuation
            // Invalidate all callback generations before releasing resources.
            continuation = nil
            #if canImport(Speech)
            let request = legacyRequest
            let task = legacyTask
            legacyRecognizer = nil
            legacyRequest = nil
            legacyTask = nil
            legacySegmentID = 0
            legacySegmentFrames = 0
            #endif
            let runtime = analyzerRuntime
            analyzerRuntime = nil
            #if canImport(Speech)
            return ReleasedResources(
                generation: stoppedGeneration,
                stream: activeStream,
                continuation: terminalContinuation,
                request: request,
                task: task,
                analyzerRuntime: runtime
            )
            #else
            return ReleasedResources(
                generation: stoppedGeneration,
                stream: activeStream,
                continuation: terminalContinuation,
                analyzerRuntime: runtime
            )
            #endif
        }
        guard let released else { return }
        let stoppedGeneration = released.generation
        let activeStream = released.stream
        let terminalContinuation = released.continuation
        #if canImport(Speech)
        let request = released.request
        let task = released.task
        let runtime = released.analyzerRuntime
        #else
        let runtime = released.analyzerRuntime
        #endif

        // Invalidate state first (above), stop ScreenCaptureKit, then enqueue a
        // marker on its serial output queue. Awaiting that marker proves every
        // callback that could have snapshotted the old generation has returned
        // before endAudio/cancel. No Apple API needs to run under `lock`.
        if let activeStream { try? await activeStream.stopCapture() }
        await drainOutputQueue()
        #if canImport(Speech)
        if let request { request.endAudio() }
        if cancelled { task?.cancel() } else { task?.finish() }
        #endif
        if #available(macOS 26.0, *),
           let runtime = runtime as? SubtitleSpeechAnalyzerRuntime {
            if cancelled { await runtime.cancel() } else { await runtime.finish() }
        }
        guard let stoppedGeneration, emitTerminalEvent else {
            terminalContinuation?.finish()
            return
        }
        terminalContinuation?.yield(
            cancelled
                ? .cancelled(generation: stoppedGeneration)
                : .stopped(generation: stoppedGeneration)
        )
        terminalContinuation?.finish()
    }

    private func drainOutputQueue() async {
        await withCheckedContinuation { continuation in
            outputQueue.async {
                continuation.resume()
            }
        }
    }

    private func emit(_ event: SubtitleSpeechSessionEvent, generation eventGeneration: UInt64) {
        lock.lock()
        let target = SubtitleSpeechGenerationGate.accepts(
            emittedGeneration: eventGeneration,
            activeGeneration: activeGenerationLocked
        ) ? continuation : nil
        lock.unlock()
        target?.yield(event)
    }

    private func failAndStop(message: String, generation: UInt64) {
        emit(.failed(generation: generation, message: message), generation: generation)
        Task { [weak self] in
            await self?.stopInternal(
                cancelled: true,
                emitTerminalEvent: false,
                expectedGeneration: generation
            )
        }
    }

    #if canImport(Speech)
    private struct LegacyRecognitionSegment {
        let request: SFSpeechAudioBufferRecognitionRequest
        let task: SFSpeechRecognitionTask
    }

    private func makeLegacySegment(
        recognizer: SFSpeechRecognizer,
        generation: UInt64,
        segmentID: UInt64
    ) -> LegacyRecognitionSegment {
        let request = SFSpeechAudioBufferRecognitionRequest()
        // This is the non-negotiable network fallback gate for macOS 15–25.
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        let task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            let segmentIsCurrent = self.lock.withLock {
                self.activeGenerationLocked == generation
                    && self.legacySegmentID == segmentID
            }
            if let result, result.isFinal || segmentIsCurrent {
                self.emit(
                    result.isFinal
                        ? .final(generation: generation, text: result.bestTranscription.formattedString)
                        : .partial(generation: generation, text: result.bestTranscription.formattedString),
                    generation: generation
                )
            }
            // Finishing an old rolling segment may itself report an error; only
            // the currently installed segment is allowed to terminate capture.
            if error != nil, result?.isFinal != true, segmentIsCurrent {
                self.failAndStop(message: "设备端语音识别已中断。", generation: generation)
            }
        }
        return LegacyRecognitionSegment(request: request, task: task)
    }

    /// Called only by ScreenCaptureKit's serial sample queue. Every installed
    /// request is rolled before the next buffer would exceed the duration or
    /// 768 KiB float-equivalent budget; no audio sample is retained by us.
    private func legacyRequestForAppending(
        _ buffer: AVAudioPCMBuffer,
        generation: UInt64
    ) -> SFSpeechAudioBufferRecognitionRequest? {
        let incomingFrames = Int64(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        let sampleRate = buffer.format.sampleRate
        guard legacySegmentPolicy.acceptsIndividualBuffer(
            frames: incomingFrames,
            sampleRate: sampleRate,
            channelCount: channelCount
        ) else {
            return nil
        }
        let snapshot = lock.withLock { () -> (
            recognizer: SFSpeechRecognizer,
            oldRequest: SFSpeechAudioBufferRecognitionRequest,
            oldTask: SFSpeechRecognitionTask,
            oldSegmentID: UInt64,
            nextSegmentID: UInt64
        )? in
            guard activeGenerationLocked == generation,
                  let recognizer = legacyRecognizer,
                  let request = legacyRequest,
                  let task = legacyTask else { return nil }
            guard legacySegmentPolicy.shouldRotate(
                accumulatedFrames: legacySegmentFrames,
                incomingFrames: incomingFrames,
                sampleRate: sampleRate,
                channelCount: channelCount
            ) else {
                legacySegmentFrames += incomingFrames
                return nil
            }
            return (recognizer, request, task, legacySegmentID, legacySegmentID &+ 1)
        }

        guard let snapshot else {
            return lock.withLock {
                guard activeGenerationLocked == generation else { return nil }
                return legacyRequest
            }
        }
        let replacement = makeLegacySegment(
            recognizer: snapshot.recognizer,
            generation: generation,
            segmentID: snapshot.nextSegmentID
        )
        let installed = lock.withLock {
            guard activeGenerationLocked == generation,
                  legacySegmentID == snapshot.oldSegmentID,
                  legacyRequest === snapshot.oldRequest else { return false }
            legacySegmentID = snapshot.nextSegmentID
            legacyRequest = replacement.request
            legacyTask = replacement.task
            legacySegmentFrames = incomingFrames
            return true
        }
        guard installed else {
            replacement.task.cancel()
            return nil
        }
        snapshot.oldRequest.endAudio()
        snapshot.oldTask.finish()
        return replacement.request
    }
    #endif

    private static func sourceApplicationFilter(
        for application: NSRunningApplication
    ) async throws -> SCContentFilter {
        guard !application.isTerminated, application.processIdentifier > 0 else {
            throw SubtitleSpeechSessionError.sourceApplicationUnavailable
        }
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        let windows = content.windows.filter {
            $0.owningApplication?.processID == application.processIdentifier
        }
        guard !application.isTerminated, !windows.isEmpty else {
            throw SubtitleSpeechSessionError.sourceApplicationUnavailable
        }
        // Window inclusion is deliberately PID-scoped: other Apps' pixels and
        // their audio are outside this capture filter.
        guard let display = content.displays.first(where: { display in
            windows.contains { display.frame.intersects($0.frame) }
        }) else {
            throw SubtitleSpeechSessionError.sourceApplicationUnavailable
        }
        let windowsOnDisplay = windows.filter { display.frame.intersects($0.frame) }
        guard !windowsOnDisplay.isEmpty else {
            throw SubtitleSpeechSessionError.sourceApplicationUnavailable
        }
        return SCContentFilter(display: display, including: windowsOnDisplay)
    }

    private static func ensureSpeechAuthorization() async throws {
        #if canImport(Speech)
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return
        case .notDetermined:
            let status = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
            guard status == .authorized else { throw SubtitleSpeechSessionError.speechAuthorizationDenied }
        case .denied, .restricted:
            throw SubtitleSpeechSessionError.speechAuthorizationDenied
        @unknown default:
            throw SubtitleSpeechSessionError.speechAuthorizationDenied
        }
        #else
        throw SubtitleSpeechSessionError.onDeviceRecognitionUnavailable
        #endif
    }
}

private enum SubtitleSpeechAudioBridge {
    static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription),
              let format = AVAudioFormat(streamDescription: asbd) else {
            return nil
        }
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(frames)
              ) else {
            return nil
        }
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frames),
            into: buffer.mutableAudioBufferList
        )
        guard status == noErr else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        return buffer
    }
}

#if canImport(Speech)
@available(macOS 26.0, *)
private final class SubtitleSpeechAnalyzerRuntime: @unchecked Sendable {
    private let analyzer: SpeechAnalyzer
    private let transcriber: SpeechTranscriber
    private let analyzerFormat: AVAudioFormat
    private let inputContinuation: AsyncStream<AnalyzerInput>.Continuation
    private let analysisTask: Task<Void, Never>
    private let resultsTask: Task<Void, Never>
    /// Accessed only from SubtitleSpeechSession's serial output queue. The
    /// queue is drained before finish/cancel, so converter state is never
    /// mutated concurrently and no raw audio is retained after teardown.
    private var audioConverter: AVAudioConverter?
    private var converterSourceFormat: AVAudioFormat?

    init(
        localeIdentifier: String,
        generation: UInt64,
        eventSink: @escaping @Sendable (SubtitleSpeechSessionEvent, UInt64) -> Void
    ) async throws {
        guard let supportedLocale = await SpeechTranscriber.supportedLocale(
            equivalentTo: Locale(identifier: localeIdentifier)
        ) else {
            throw SubtitleSpeechSessionError.onDeviceRecognitionUnavailable
        }
        let transcriber = SpeechTranscriber(
            locale: supportedLocale,
            preset: .progressiveTranscription
        )
        guard SpeechTranscriber.isAvailable else {
            throw SubtitleSpeechSessionError.onDeviceRecognitionUnavailable
        }
        let assetStatus = await AssetInventory.status(forModules: [transcriber])
        guard assetStatus == .installed else {
            throw assetStatus == .unsupported
                ? SubtitleSpeechSessionError.onDeviceRecognitionUnavailable
                : SubtitleSpeechSessionError.onDeviceSpeechAssetUnavailable
        }
        let channel = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingNewest(8))
        let analyzer = SpeechAnalyzer(
            modules: [transcriber],
            options: SpeechAnalyzer.Options(priority: .utility, modelRetention: .whileInUse)
        )
        let captureFormat = AVAudioFormat(
            standardFormatWithSampleRate: 48_000,
            channels: 1
        )
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber],
            considering: captureFormat
        ) else {
            throw SubtitleSpeechSessionError.onDeviceRecognitionUnavailable
        }
        try await analyzer.prepareToAnalyze(in: analyzerFormat)
        self.analyzer = analyzer
        self.transcriber = transcriber
        self.analyzerFormat = analyzerFormat
        inputContinuation = channel.continuation
        resultsTask = Task {
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    guard !text.isEmpty else { continue }
                    eventSink(
                        result.isFinal
                            ? .final(generation: generation, text: text)
                            : .partial(generation: generation, text: text),
                        generation
                    )
                }
            } catch is CancellationError {
                return
            } catch {
                eventSink(.failed(generation: generation, message: "设备端语音识别已中断。"), generation)
            }
        }
        analysisTask = Task {
            do {
                try await analyzer.start(inputSequence: channel.stream)
            } catch is CancellationError {
                return
            } catch {
                eventSink(.failed(generation: generation, message: "设备端语音分析无法启动。"), generation)
            }
        }
    }

    func append(_ buffer: AVAudioPCMBuffer, presentationTime: CMTime) {
        if buffer.format.isEqual(analyzerFormat) {
            inputContinuation.yield(
                AnalyzerInput(buffer: buffer, bufferStartTime: presentationTime)
            )
            return
        }

        guard let converted = convert(buffer, presentationTime: presentationTime) else {
            return
        }
        for input in converted {
            inputContinuation.yield(input)
        }
    }

    func finish() async {
        inputContinuation.finish()
        try? await analyzer.finalizeAndFinishThroughEndOfInput()
        analysisTask.cancel()
        resultsTask.cancel()
    }

    func cancel() async {
        inputContinuation.finish()
        await analyzer.cancelAndFinishNow()
        analysisTask.cancel()
        resultsTask.cancel()
    }

    /// macOS 26 does not yet expose `AnalyzerInputConverter`, so use the
    /// system AVAudioConverter as a streaming adapter to the exact format
    /// selected by SpeechAnalyzer. At most one ScreenCaptureKit buffer and one
    /// converted buffer are alive at a time.
    private func convert(
        _ inputBuffer: AVAudioPCMBuffer,
        presentationTime: CMTime
    ) -> [AnalyzerInput]? {
        if audioConverter == nil || converterSourceFormat?.isEqual(inputBuffer.format) != true {
            audioConverter = AVAudioConverter(from: inputBuffer.format, to: analyzerFormat)
            converterSourceFormat = inputBuffer.format
        }
        guard let audioConverter else { return nil }

        let ratio = analyzerFormat.sampleRate / max(inputBuffer.format.sampleRate, 1)
        let capacity = AVAudioFrameCount(
            max(ceil(Double(inputBuffer.frameLength) * ratio) + 32, 1)
        )
        var suppliedInput = false
        var conversionError: NSError?
        var convertedInputs: [AnalyzerInput] = []
        var outputStartTime = presentationTime

        while true {
            guard let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: analyzerFormat,
                frameCapacity: capacity
            ) else { return nil }
            let status = audioConverter.convert(
                to: outputBuffer,
                error: &conversionError
            ) { _, inputStatus in
                guard !suppliedInput else {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                suppliedInput = true
                inputStatus.pointee = .haveData
                return inputBuffer
            }

            if outputBuffer.frameLength > 0 {
                convertedInputs.append(
                    AnalyzerInput(buffer: outputBuffer, bufferStartTime: outputStartTime)
                )
                let duration = CMTime(
                    value: CMTimeValue(outputBuffer.frameLength),
                    timescale: CMTimeScale(max(Int32(analyzerFormat.sampleRate.rounded()), 1))
                )
                outputStartTime = CMTimeAdd(outputStartTime, duration)
            }

            switch status {
            case .haveData:
                continue
            case .inputRanDry, .endOfStream:
                return convertedInputs
            case .error:
                _ = conversionError
                return nil
            @unknown default:
                return nil
            }
        }
    }
}
#endif
