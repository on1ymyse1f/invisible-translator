import Foundation
import XCTest
@testable import ClaudePromptTranslator

final class SpeechRecognitionRuntimeTests: XCTestCase {
    func testRuntimeSubtitleModesBridgeWithoutChangingLegacyPersistence() {
        XCTAssertEqual(SubtitleRecognitionMode.regionOCR.runtimeMode, .screenOCR)
        XCTAssertEqual(SubtitleRecognitionMode.systemSpeech.runtimeMode, .appleOnDeviceSpeech)
        XCTAssertEqual(
            SubtitleRecognitionMode.offlineASRModel.runtimeMode,
            .downloadedASR(modelID: "current")
        )
        XCTAssertEqual(SubtitleRecognitionRuntimeMode.screenOCR.legacyMode, .regionOCR)
        XCTAssertNil(SubtitleRecognitionRuntimeMode.domCaption.legacyMode)
    }

    func testSystemAssetPendingDoesNotOfferPrivateModel() {
        XCTAssertFalse(SystemSpeechResolution.systemAssetPending.shouldOfferPrivateModel)
        XCTAssertFalse(SystemSpeechResolution.authorizationRequired.shouldOfferPrivateModel)
        XCTAssertTrue(SystemSpeechResolution.systemUnsupported.shouldOfferPrivateModel)
    }

    func testSpeechLocaleChoicesAreExplicitAndStable() {
        XCTAssertEqual(SubtitleSpeechLocale.englishUS.localeIdentifier, "en-US")
        XCTAssertEqual(SubtitleSpeechLocale.simplifiedChinese.localeIdentifier, "zh-CN")
        XCTAssertEqual(SubtitleSpeechLocale.japanese.localeIdentifier, "ja-JP")
        XCTAssertFalse(SubtitleSpeechLocale.system.localeIdentifier.isEmpty)
        XCTAssertEqual(SubtitleSpeechLocale.allCases.count, 4)
    }

    func testAudioRingBufferCapsBothBytesAndDuration() async {
        let buffer = SpeechAudioRingBuffer()
        let packet = SpeechAudioPacket(
            pcm: Data(repeating: 0x01, count: 320_000),
            sampleRate: 16_000,
            channelCount: 1,
            bytesPerSample: 2
        )
        let firstAccepted = await buffer.append(packet)
        let secondAccepted = await buffer.append(packet)
        XCTAssertTrue(firstAccepted) // 10 seconds
        XCTAssertTrue(secondAccepted)

        let snapshot = await buffer.snapshot()
        XCTAssertLessThanOrEqual(snapshot.duration, SpeechAudioRingBuffer.maximumDuration)
        XCTAssertLessThanOrEqual(snapshot.byteCount, SpeechAudioRingBuffer.maximumByteCount)
        XCTAssertEqual(snapshot.packetCount, 1)

        let oversized = SpeechAudioPacket(
            pcm: Data(repeating: 0x02, count: SpeechAudioRingBuffer.maximumByteCount + 1)
        )
        let oversizedAccepted = await buffer.append(oversized)
        XCTAssertFalse(oversizedAccepted)
    }

    func testRecognitionPoolAllowsOneLeaseAndUnloadsWhenIdle() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = try await makeInstalledStore(now: now)
        let recorder = TestEngineRecorder()
        let pool = RecognitionEnginePool(
            modelStore: store,
            idleUnloadInterval: 30,
            engineFactory: { _ in TestEngine(recorder: recorder) }
        )
        let first = try await pool.acquire(modelID: "synthetic-asr", now: now)
        let activeAfterFirstLease = await pool.hasActiveLease()
        XCTAssertTrue(activeAfterFirstLease)

        do {
            _ = try await pool.acquire(modelID: "synthetic-asr", now: now)
            XCTFail("A second ASR lease must not be admitted.")
        } catch {
            XCTAssertEqual(error as? RecognitionEnginePoolError, .engineBusy)
        }

        let output = try await first.transcribe([
            SpeechAudioPacket(pcm: Data(repeating: 0x3, count: 320))
        ])
        XCTAssertEqual(output, "synthetic")
        await first.release()
        let activeAfterRelease = await pool.hasActiveLease()
        let loadedAfterRelease = await pool.hasLoadedEngine()
        let didUnload = await pool.unloadIfIdle(now: now.addingTimeInterval(31))
        let loadedAfterUnload = await pool.hasLoadedEngine()
        let unloadCount = await recorder.unloadCount
        XCTAssertFalse(activeAfterRelease)
        XCTAssertTrue(loadedAfterRelease)
        XCTAssertTrue(didUnload)
        XCTAssertFalse(loadedAfterUnload)
        XCTAssertEqual(unloadCount, 1)
    }

    func testStaleLeaseCannotTranscribeAfterNewLease() async throws {
        let store = try await makeInstalledStore()
        let recorder = TestEngineRecorder()
        let pool = RecognitionEnginePool(
            modelStore: store,
            idleUnloadInterval: 30,
            engineFactory: { _ in TestEngine(recorder: recorder) }
        )
        let first = try await pool.acquire(modelID: "synthetic-asr")
        await first.release()
        let second = try await pool.acquire(modelID: "synthetic-asr")
        do {
            _ = try await first.transcribe([])
            XCTFail("A released lease must not outlive its generation.")
        } catch {
            XCTAssertEqual(error as? RecognitionEnginePoolError, .staleLease)
        }
        await second.release()
    }

    func testConcurrentAcquireAdmitsOnlyOneFactoryLoad() async throws {
        let store = try await makeInstalledStore()
        let recorder = TestEngineRecorder()
        let gate = SuspendingEngineFactoryGate()
        let pool = RecognitionEnginePool(
            modelStore: store,
            idleUnloadInterval: 30,
            engineFactory: { _ in
                await gate.suspendOnce()
                return TestEngine(recorder: recorder)
            }
        )

        let firstTask = Task {
            try await pool.acquire(modelID: "synthetic-asr")
        }
        await gate.waitUntilSuspended()

        do {
            _ = try await pool.acquire(modelID: "synthetic-asr")
            XCTFail("A concurrent acquire must fail before starting a second model load.")
        } catch {
            XCTAssertEqual(error as? RecognitionEnginePoolError, .engineBusy)
        }

        await gate.release()
        let first = try await firstTask.value
        let active = await pool.hasActiveLease()
        XCTAssertTrue(active)
        await first.release()
    }

    private func makeInstalledStore(now: Date = Date()) async throws -> ASRModelStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CPT-SpeechRuntimeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let verifier = AcceptingVerifier()
        let store = ASRModelStore(rootDirectory: root, verifier: verifier)
        let descriptor = ASRModelDescriptor(
            identifier: "synthetic-asr",
            version: "1.0.0",
            downloadURL: URL(string: "https://models.example.invalid/synthetic.cptasr")!,
            expectedByteCount: 64,
            sha256Hex: String(repeating: "0", count: 64),
            digestSignatureBase64: Data(repeating: 0, count: 64).base64EncodedString()
        )
        _ = try await store.install(
            descriptor,
            using: ASRModelDownloadClient { _, destination, _, progress in
                try Data(repeating: 0, count: 64).write(to: destination)
                await progress(64)
            },
            now: now
        )
        return store
    }
}

private struct AcceptingVerifier: ASRModelVerifying {
    func verify(fileAt url: URL, descriptor: ASRModelDescriptor) async throws {
        _ = url
        _ = descriptor
    }
}

private actor TestEngineRecorder {
    private(set) var unloadCount = 0

    func recordUnload() { unloadCount += 1 }
}

private actor SuspendingEngineFactoryGate {
    private var didSuspend = false
    private var suspensionContinuation: CheckedContinuation<Void, Never>?
    private var waiterContinuations: [CheckedContinuation<Void, Never>] = []

    func suspendOnce() async {
        guard !didSuspend else { return }
        didSuspend = true
        let waiters = waiterContinuations
        waiterContinuations.removeAll()
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { continuation in
            suspensionContinuation = continuation
        }
    }

    func waitUntilSuspended() async {
        if didSuspend { return }
        await withCheckedContinuation { continuation in
            waiterContinuations.append(continuation)
        }
    }

    func release() {
        suspensionContinuation?.resume()
        suspensionContinuation = nil
    }
}

private final class TestEngine: PrivateASRRecognizing, @unchecked Sendable {
    private let recorder: TestEngineRecorder

    init(recorder: TestEngineRecorder) {
        self.recorder = recorder
    }

    func transcribe(_ packets: [SpeechAudioPacket]) async throws -> String {
        _ = packets
        return "synthetic"
    }

    func unload() async {
        await recorder.recordUnload()
    }
}
