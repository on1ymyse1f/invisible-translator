import Foundation

#if canImport(Speech)
@preconcurrency import Speech
#endif

/// The richer 1.0 representation of a subtitle source.
///
/// `SubtitleRecognitionMode` predates DOM captions and model identifiers, so it
/// intentionally remains source-compatible in `ASRModelStore.swift`. New code
/// should use this type and only bridge to the legacy enum at UI persistence
/// boundaries.
enum SubtitleRecognitionRuntimeMode: Equatable, Sendable {
    case domCaption
    case screenOCR
    case appleOnDeviceSpeech
    case downloadedASR(modelID: String)

    var legacyMode: SubtitleRecognitionMode? {
        switch self {
        case .domCaption:
            return nil
        case .screenOCR:
            return .regionOCR
        case .appleOnDeviceSpeech:
            return .systemSpeech
        case .downloadedASR:
            return .offlineASRModel
        }
    }
}

/// Explicit source-language choices for Apple on-device speech. Apple Speech
/// does not provide a reliable cross-language auto-detect mode for a live
/// audio stream, so the UI keeps this setting visible instead of guessing and
/// silently producing low-quality subtitles.
enum SubtitleSpeechLocale: String, CaseIterable, Sendable {
    case system
    case englishUS
    case simplifiedChinese
    case japanese

    var localeIdentifier: String {
        switch self {
        case .system:
            return Locale.current.identifier
        case .englishUS:
            return "en-US"
        case .simplifiedChinese:
            return "zh-CN"
        case .japanese:
            return "ja-JP"
        }
    }

    var displayName: String {
        switch self {
        case .system: return "跟随系统语言"
        case .englishUS: return "英语"
        case .simplifiedChinese: return "简体中文"
        case .japanese: return "日语"
        }
    }
}

extension SubtitleRecognitionMode {
    /// Migrates older stored settings to the richer 1.0 runtime mode.
    var runtimeMode: SubtitleRecognitionRuntimeMode {
        switch self {
        case .regionOCR:
            return .screenOCR
        case .systemSpeech:
            return .appleOnDeviceSpeech
        case .offlineASRModel:
            return .downloadedASR(modelID: "current")
        }
    }
}

enum SystemSpeechEngineKind: Equatable, Sendable {
    case speechAnalyzer
    case sfSpeechRecognizer
}

/// An unavailable system asset must not silently become a cloud request. The
/// UI only offers the private-model download for `.systemUnsupported`.
enum SystemSpeechResolution: Equatable, Sendable {
    case ready(SystemSpeechEngineKind)
    case authorizationRequired
    case systemAssetPending
    case systemUnsupported

    var shouldOfferPrivateModel: Bool {
        if case .systemUnsupported = self { return true }
        return false
    }
}

/// Inspects Apple Speech without requesting permission, downloading an asset,
/// or creating a recognition task. This is deliberately fail-closed: network
/// capable legacy recognition is never reported as usable.
struct AppleOnDeviceSpeechCapability: SystemSpeechAvailabilityProviding, Sendable {
    func availability(for localeIdentifier: String) async -> SystemSpeechAvailability {
        switch await resolution(for: localeIdentifier) {
        case .ready:
            return .availableOnDevice
        case .authorizationRequired, .systemAssetPending, .systemUnsupported:
            return .unavailable
        }
    }

    func resolution(for localeIdentifier: String) async -> SystemSpeechResolution {
        #if canImport(Speech)
        if #available(macOS 26.0, *) {
            return await speechAnalyzerResolution(localeIdentifier: localeIdentifier)
        }
        return sfSpeechRecognizerResolution(localeIdentifier: localeIdentifier)
        #else
        _ = localeIdentifier
        return .systemUnsupported
        #endif
    }

    #if canImport(Speech)
    @available(macOS 26.0, *)
    private func speechAnalyzerResolution(localeIdentifier: String) async -> SystemSpeechResolution {
        guard let supportedLocale = await SpeechTranscriber.supportedLocale(
            equivalentTo: Locale(identifier: localeIdentifier)
        ) else {
            return .systemUnsupported
        }
        let transcriber = SpeechTranscriber(
            locale: supportedLocale,
            preset: .progressiveTranscription
        )
        guard SpeechTranscriber.isAvailable else {
            return .systemUnsupported
        }

        switch await AssetInventory.status(forModules: [transcriber]) {
        case .installed:
            return .ready(.speechAnalyzer)
        case .supported, .downloading:
            // The system owns this asset. Do not download a private model until
            // it reports that this locale is unsupported.
            return .systemAssetPending
        case .unsupported:
            return .systemUnsupported
        @unknown default:
            return .systemUnsupported
        }
    }

    /// Builds the macOS 26+ analyzer only after its system-managed asset is
    /// installed. `whileInUse` prevents this app from pinning Apple's shared
    /// model after the explicit subtitle session releases the analyzer.
    @available(macOS 26.0, *)
    func makeSpeechAnalyzer(localeIdentifier: String) async -> SpeechAnalyzer? {
        guard let supportedLocale = await SpeechTranscriber.supportedLocale(
            equivalentTo: Locale(identifier: localeIdentifier)
        ) else {
            return nil
        }
        let transcriber = SpeechTranscriber(
            locale: supportedLocale,
            preset: .progressiveTranscription
        )
        guard SpeechTranscriber.isAvailable,
              await AssetInventory.status(forModules: [transcriber]) == .installed else {
            return nil
        }
        return SpeechAnalyzer(
            modules: [transcriber],
            options: SpeechAnalyzer.Options(
                priority: .utility,
                modelRetention: .whileInUse
            )
        )
    }

    private func sfSpeechRecognizerResolution(localeIdentifier: String) -> SystemSpeechResolution {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            break
        case .notDetermined, .denied, .restricted:
            return .authorizationRequired
        @unknown default:
            return .authorizationRequired
        }

        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)),
              recognizer.supportsOnDeviceRecognition else {
            return .systemUnsupported
        }
        return .ready(.sfSpeechRecognizer)
    }

    /// All legacy requests are explicitly device-only. Callers retain and end
    /// the request themselves; this helper neither starts recognition nor
    /// permits Apple's network fallback.
    func makeLegacyOnDeviceRequest() -> SFSpeechAudioBufferRecognitionRequest? {
        guard #unavailable(macOS 26.0) else { return nil }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        return request
    }
    #endif
}

struct SpeechAudioPacket: Sendable, Equatable {
    let pcm: Data
    let sampleRate: Double
    let channelCount: Int
    let bytesPerSample: Int

    init(
        pcm: Data,
        sampleRate: Double = 16_000,
        channelCount: Int = 1,
        bytesPerSample: Int = 2
    ) {
        self.pcm = pcm
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.bytesPerSample = bytesPerSample
    }

    var duration: TimeInterval {
        guard sampleRate > 0, channelCount > 0, bytesPerSample > 0 else { return 0 }
        let bytesPerSecond = sampleRate * Double(channelCount * bytesPerSample)
        return Double(pcm.count) / bytesPerSecond
    }
}

struct SpeechAudioRingBufferSnapshot: Equatable, Sendable {
    let packetCount: Int
    let byteCount: Int
    let duration: TimeInterval
}

/// Bounded raw PCM storage for explicit system-audio capture. It never writes
/// audio to disk and rejects malformed or oversized packets rather than
/// retaining them temporarily.
actor SpeechAudioRingBuffer {
    static let maximumDuration: TimeInterval = 12
    static let maximumByteCount = 768 * 1_024

    private var packets: [SpeechAudioPacket] = []
    private var storedByteCount = 0
    private var storedDuration: TimeInterval = 0

    @discardableResult
    func append(_ packet: SpeechAudioPacket) -> Bool {
        guard packet.sampleRate > 0,
              packet.channelCount > 0,
              packet.bytesPerSample > 0,
              packet.pcm.count <= Self.maximumByteCount,
              packet.duration <= Self.maximumDuration else {
            return false
        }

        packets.append(packet)
        storedByteCount += packet.pcm.count
        storedDuration += packet.duration
        trimToBudget()
        return true
    }

    func drain() -> [SpeechAudioPacket] {
        defer { removeAll() }
        return packets
    }

    func removeAll() {
        packets.removeAll(keepingCapacity: false)
        storedByteCount = 0
        storedDuration = 0
    }

    func snapshot() -> SpeechAudioRingBufferSnapshot {
        SpeechAudioRingBufferSnapshot(
            packetCount: packets.count,
            byteCount: storedByteCount,
            duration: storedDuration
        )
    }

    private func trimToBudget() {
        while storedByteCount > Self.maximumByteCount || storedDuration > Self.maximumDuration {
            guard !packets.isEmpty else {
                storedByteCount = 0
                storedDuration = 0
                return
            }
            let removed = packets.removeFirst()
            storedByteCount -= removed.pcm.count
            storedDuration -= removed.duration
        }
    }
}

protocol PrivateASRRecognizing: AnyObject, Sendable {
    func transcribe(_ packets: [SpeechAudioPacket]) async throws -> String
    func unload() async
}

enum RecognitionEnginePoolError: LocalizedError, Equatable {
    case modelNotInstalled
    case installedModelDoesNotMatchRequestedID
    case engineBusy
    case staleLease

    var errorDescription: String? {
        switch self {
        case .modelNotInstalled:
            return "未安装离线语音模型。"
        case .installedModelDoesNotMatchRequestedID:
            return "当前离线语音模型与所选模型不一致。"
        case .engineBusy:
            return "离线语音识别正在使用中。"
        case .staleLease:
            return "离线语音识别会话已失效。"
        }
    }
}

struct RecognitionEngineLease: Sendable {
    let generation: UInt64
    private let transcribeOperation: @Sendable ([SpeechAudioPacket], UInt64) async throws -> String
    private let releaseOperation: @Sendable (UUID, UInt64) async -> Void
    private let identifier: UUID

    fileprivate init(
        generation: UInt64,
        identifier: UUID,
        transcribeOperation: @escaping @Sendable ([SpeechAudioPacket], UInt64) async throws -> String,
        releaseOperation: @escaping @Sendable (UUID, UInt64) async -> Void
    ) {
        self.generation = generation
        self.identifier = identifier
        self.transcribeOperation = transcribeOperation
        self.releaseOperation = releaseOperation
    }

    func transcribe(_ packets: [SpeechAudioPacket]) async throws -> String {
        try await transcribeOperation(packets, generation)
    }

    func release() async {
        await releaseOperation(identifier, generation)
    }
}

/// A single model engine can remain warm for 30 seconds after a lease ends,
/// but there is never more than one active lease or loaded model. The pool
/// talks only to `ASRModelStore`; model download and networking stay outside
/// this runtime.
actor RecognitionEnginePool {
    typealias EngineFactory = @Sendable (URL) async throws -> any PrivateASRRecognizing

    private struct LoadedEngine {
        let modelURL: URL
        let modelIdentifier: String
        let engine: any PrivateASRRecognizing
        var lastReleasedAt: Date?
    }

    private let modelStore: ASRModelStore
    private let engineFactory: EngineFactory
    private let idleUnloadInterval: TimeInterval
    private var loaded: LoadedEngine?
    private var activeLeaseIdentifier: UUID?
    private var acquisitionInProgress = false
    private var generation: UInt64 = 0
    private var scheduledUnload: Task<Void, Never>?

    init(
        modelStore: ASRModelStore,
        idleUnloadInterval: TimeInterval = 30,
        engineFactory: @escaping EngineFactory
    ) {
        self.modelStore = modelStore
        self.idleUnloadInterval = max(idleUnloadInterval, 0)
        self.engineFactory = engineFactory
    }

    deinit {
        scheduledUnload?.cancel()
    }

    func acquire(modelID: String, now: Date = Date()) async throws -> RecognitionEngineLease {
        guard activeLeaseIdentifier == nil, !acquisitionInProgress else {
            throw RecognitionEnginePoolError.engineBusy
        }
        // Reserve admission before the first await. Actors are reentrant, so
        // checking only activeLeaseIdentifier would allow two simultaneous
        // callers to create and overwrite a private ASR engine.
        acquisitionInProgress = true
        defer { acquisitionInProgress = false }
        scheduledUnload?.cancel()
        scheduledUnload = nil

        guard case .installed(let descriptor, _, _) = await modelStore.status(now: now),
              let modelURL = try await modelStore.installedModelURL(now: now) else {
            throw RecognitionEnginePoolError.modelNotInstalled
        }
        guard descriptor.identifier == modelID else {
            throw RecognitionEnginePoolError.installedModelDoesNotMatchRequestedID
        }

        if let existing = loaded, existing.modelURL != modelURL {
            await existing.engine.unload()
            loaded = nil
        }
        let loadedDuringThisAcquire = loaded == nil
        if loadedDuringThisAcquire {
            let engine = try await engineFactory(modelURL)
            loaded = LoadedEngine(
                modelURL: modelURL,
                modelIdentifier: descriptor.identifier,
                engine: engine,
                lastReleasedAt: nil
            )
        }

        do {
            try await modelStore.markUsed(at: now)
        } catch {
            // Do not leave a busy lease after metadata persistence fails. A
            // newly loaded engine is also released immediately; a reusable
            // prior engine returns to the normal idle-unload path.
            if loadedDuringThisAcquire, let current = loaded {
                await current.engine.unload()
                loaded = nil
            } else if var current = loaded {
                current.lastReleasedAt = now
                loaded = current
                scheduleIdleUnload(for: generation)
            }
            throw error
        }
        generation &+= 1
        let leaseID = UUID()
        activeLeaseIdentifier = leaseID
        let leaseGeneration = generation
        return RecognitionEngineLease(
            generation: leaseGeneration,
            identifier: leaseID,
            transcribeOperation: { [weak self] packets, generation in
                guard let self else { throw RecognitionEnginePoolError.staleLease }
                return try await self.transcribe(
                    packets,
                    leaseIdentifier: leaseID,
                    generation: generation
                )
            },
            releaseOperation: { [weak self] identifier, generation in
                await self?.release(identifier: identifier, generation: generation, now: Date())
            }
        )
    }

    func unloadIfIdle(now: Date = Date()) async -> Bool {
        guard activeLeaseIdentifier == nil, !acquisitionInProgress,
              let current = loaded,
              let releasedAt = current.lastReleasedAt,
              now.timeIntervalSince(releasedAt) >= idleUnloadInterval else {
            return false
        }
        await current.engine.unload()
        loaded = nil
        scheduledUnload?.cancel()
        scheduledUnload = nil
        return true
    }

    /// A running transcription is not interrupted; idle model memory is
    /// released immediately when macOS reports memory pressure.
    func releaseIdleEngineForMemoryPressure() async -> Bool {
        guard activeLeaseIdentifier == nil, !acquisitionInProgress,
              let current = loaded else { return false }
        await current.engine.unload()
        loaded = nil
        scheduledUnload?.cancel()
        scheduledUnload = nil
        return true
    }

    func currentGeneration() -> UInt64 { generation }
    func hasLoadedEngine() -> Bool { loaded != nil }
    func hasActiveLease() -> Bool { activeLeaseIdentifier != nil }

    private func transcribe(
        _ packets: [SpeechAudioPacket],
        leaseIdentifier: UUID,
        generation: UInt64
    ) async throws -> String {
        guard activeLeaseIdentifier == leaseIdentifier,
              self.generation == generation,
              let current = loaded else {
            throw RecognitionEnginePoolError.staleLease
        }
        // Deliberately return text only to the caller. The runtime never logs
        // source audio or recognition text.
        return try await current.engine.transcribe(packets)
    }

    private func release(identifier: UUID, generation: UInt64, now: Date) async {
        guard activeLeaseIdentifier == identifier, self.generation == generation else { return }
        activeLeaseIdentifier = nil
        guard var current = loaded else { return }
        current.lastReleasedAt = now
        loaded = current
        scheduleIdleUnload(for: generation)
    }

    private func scheduleIdleUnload(for expectedGeneration: UInt64) {
        guard idleUnloadInterval > 0 else {
            Task { [weak self] in
                _ = await self?.unloadIfIdle(now: Date.distantFuture)
            }
            return
        }
        scheduledUnload = Task { [weak self, idleUnloadInterval] in
            do {
                try await Task.sleep(for: .seconds(idleUnloadInterval))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.unloadIfGenerationIsIdle(expectedGeneration)
        }
    }

    private func unloadIfGenerationIsIdle(_ expectedGeneration: UInt64) async {
        guard generation == expectedGeneration else { return }
        _ = await unloadIfIdle(now: Date())
    }
}
