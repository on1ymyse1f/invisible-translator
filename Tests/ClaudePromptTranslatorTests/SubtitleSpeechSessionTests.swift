import ScreenCaptureKit
import XCTest
@testable import ClaudePromptTranslator

final class SubtitleSpeechSessionTests: XCTestCase {
    func testCaptureStartLifecycleInvalidatesStopDuringStart() throws {
        var lifecycle = CaptureStartLifecycle()
        let token = try XCTUnwrap(lifecycle.beginStart())

        XCTAssertTrue(lifecycle.isActive)
        XCTAssertTrue(lifecycle.accepts(token))
        XCTAssertEqual(lifecycle.invalidate(), token)
        XCTAssertFalse(lifecycle.isActive)
        XCTAssertFalse(lifecycle.accepts(token))
        XCTAssertFalse(lifecycle.markStarted(token))
    }

    func testSubtitleCaptureTerminalStateHasExplicitStatus() {
        XCTAssertEqual(
            SubtitleCaptureStreamTerminal.stopped.statusMessage,
            "字幕画面捕获已停止。"
        )
        XCTAssertEqual(
            SubtitleCaptureStreamTerminal.failed(message: "权限已撤销").statusMessage,
            "字幕画面捕获已中断：权限已撤销"
        )
        XCTAssertFalse(SubtitleCaptureStreamTerminal.stopped.requiresApplicationShutdown)
        XCTAssertTrue(
            SubtitleCaptureStreamTerminal.failed(message: "权限已撤销")
                .requiresApplicationShutdown
        )
    }

    func testCaptureStartLifecycleRejectsConcurrentStartAndLateOldCompletion() throws {
        var lifecycle = CaptureStartLifecycle()
        let oldToken = try XCTUnwrap(lifecycle.beginStart())
        XCTAssertNil(lifecycle.beginStart())

        _ = lifecycle.invalidate()
        let newToken = try XCTUnwrap(lifecycle.beginStart())
        XCTAssertNotEqual(oldToken, newToken)
        XCTAssertFalse(lifecycle.markStarted(oldToken))
        XCTAssertTrue(lifecycle.accepts(newToken))
        XCTAssertTrue(lifecycle.markStarted(newToken))
    }

    func testFailedOldStartCannotInvalidateNewStart() throws {
        var lifecycle = CaptureStartLifecycle()
        let oldToken = try XCTUnwrap(lifecycle.beginStart())
        _ = lifecycle.invalidate()
        let newToken = try XCTUnwrap(lifecycle.beginStart())

        XCTAssertFalse(lifecycle.failStart(oldToken))
        XCTAssertTrue(lifecycle.accepts(newToken))
    }

    func testCapturePolicyIsAudioOnlyAndExcludesOurProcessAudio() {
        let policy = SubtitleSpeechCapturePolicy()
        XCTAssertTrue(policy.capturesAudio)
        XCTAssertTrue(policy.excludesCurrentProcessAudio)
        XCTAssertEqual(policy.sampleRate, 48_000)
        XCTAssertEqual(policy.channelCount, 1)
        let configuration = SCStreamConfiguration()
        policy.apply(to: configuration)
        XCTAssertFalse(configuration.captureMicrophone)
        XCTAssertEqual(configuration.width, 2)
        XCTAssertEqual(configuration.height, 2)
        XCTAssertEqual(configuration.queueDepth, 2)
    }

    func testLegacySpeechSegmentsRespectDurationAndByteBudgets() {
        let policy = LegacySpeechSegmentPolicy()
        XCTAssertEqual(
            policy.maximumFrames(sampleRate: 16_000, channelCount: 1),
            192_000
        )
        // At ScreenCaptureKit's 48 kHz mono rate, the 768 KiB bound is
        // stricter than 12 seconds: 196,608 float-equivalent frames.
        XCTAssertEqual(
            policy.maximumFrames(sampleRate: 48_000, channelCount: 1),
            196_608
        )
        XCTAssertFalse(
            policy.shouldRotate(
                accumulatedFrames: 190_000,
                incomingFrames: 6_608,
                sampleRate: 48_000,
                channelCount: 1
            )
        )
        XCTAssertTrue(
            policy.shouldRotate(
                accumulatedFrames: 190_000,
                incomingFrames: 6_609,
                sampleRate: 48_000,
                channelCount: 1
            )
        )
        XCTAssertFalse(
            policy.acceptsIndividualBuffer(
                frames: 196_609,
                sampleRate: 48_000,
                channelCount: 1
            )
        )
        XCTAssertTrue(
            policy.acceptsIndividualBuffer(
                frames: 196_608,
                sampleRate: 48_000,
                channelCount: 1
            )
        )
    }

    func testGenerationGateRejectsLateRecognitionCallbacks() {
        XCTAssertTrue(
            SubtitleSpeechGenerationGate.accepts(emittedGeneration: 8, activeGeneration: 8)
        )
        XCTAssertFalse(
            SubtitleSpeechGenerationGate.accepts(emittedGeneration: 8, activeGeneration: 9)
        )
        XCTAssertFalse(
            SubtitleSpeechGenerationGate.accepts(emittedGeneration: 8, activeGeneration: nil)
        )
    }

    func testStreamIdentityGateRejectsLateCallbackFromReplacedStream() {
        final class StreamIdentity {}

        let oldStream = StreamIdentity()
        let replacementStream = StreamIdentity()

        XCTAssertTrue(
            SubtitleSpeechStreamIdentityGate.accepts(
                activeStream: oldStream,
                callbackStream: oldStream
            )
        )
        XCTAssertFalse(
            SubtitleSpeechStreamIdentityGate.accepts(
                activeStream: replacementStream,
                callbackStream: oldStream
            )
        )
        XCTAssertFalse(
            SubtitleSpeechStreamIdentityGate.accepts(
                activeStream: Optional<StreamIdentity>.none,
                callbackStream: oldStream
            )
        )
    }

    func testEventsRetainPartialFinalAndLifecycleSemantics() {
        XCTAssertEqual(
            SubtitleSpeechSessionEvent.partial(generation: 3, text: "hello"),
            .partial(generation: 3, text: "hello")
        )
        XCTAssertNotEqual(
            SubtitleSpeechSessionEvent.final(generation: 3, text: "hello"),
            .partial(generation: 3, text: "hello")
        )
        XCTAssertEqual(
            SubtitleSpeechSessionEvent.cancelled(generation: 3),
            .cancelled(generation: 3)
        )
    }
}
