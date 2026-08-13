import AppKit
import NaturalLanguage
import SwiftUI

#if canImport(Translation)
import Translation

enum AppleTranslationLanguageResolver {
    static func sourceLanguage(for text: String) throws -> Locale.Language {
        let languageSample = TranslationChunker.languageDetectionProjection(for: text)
        guard !languageSample.isEmpty else {
            throw TranslationProviderUnavailableError.languageCouldNotBeDetermined
        }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(languageSample)
        guard let language = recognizer.dominantLanguage,
              language != .undetermined else {
            throw TranslationProviderUnavailableError.languageCouldNotBeDetermined
        }
        return Locale.Language(identifier: language.rawValue)
    }
}

/// Owns the SwiftUI view required by Apple's Translation framework. A
/// TranslationSession obtained from `translationTask` can request permission
/// for missing on-device language models; a standalone session cannot.
@available(macOS 15.0, *)
@MainActor
final class AppleTranslationCoordinator: ObservableObject {
    static let shared = AppleTranslationCoordinator()

    @Published fileprivate var configuration: TranslationSession.Configuration?
    @Published fileprivate var statusText = "正在准备 Apple 本地翻译…"

    private struct PendingRequest {
        let id: UUID
        let text: String
        let source: Locale.Language
        let target: Locale.Language
        let maximumCharacters: Int
        let continuation: CheckedContinuation<String, Error>
    }

    private struct RequestSnapshot: Sendable {
        let id: UUID
        let text: String
    }

    private var pendingRequest: PendingRequest?
    private var queuedRequests: [PendingRequest] = []
    private var panel: NSPanel?
    private var hostingView: NSHostingView<AppleTranslationHostView>?
    private var hostReleaseTask: Task<Void, Never>?

    private static let maximumQueuedRequests = 2
    private static let maximumInFlightTextBytes = 1_048_576
    private static let hostIdleReleaseDelay: Duration = .seconds(30)

    private init() {}

    func translateText(
        _ text: String,
        targetLanguageCode: String,
        maximumCharacters: Int
    ) async throws -> String {
        guard text.count <= maximumCharacters else {
            throw TranslationError.inputTooLong(limit: maximumCharacters)
        }

        let source = try AppleTranslationLanguageResolver.sourceLanguage(for: text)
        let target = Locale.Language(identifier: targetLanguageCode)
        let availability = LanguageAvailability()
        let status = await availability.status(from: source, to: target)
        SelectionDiagnostics.record("apple availability status=\(String(describing: status))")
        guard status != .unsupported else {
            throw TranslationProviderUnavailableError.unsupportedLanguagePair
        }

        // macOS 26 can create a headless session when both models are already
        // installed. This keeps routine translations completely unobtrusive.
        if #available(macOS 26.0, *), status == .installed {
            let client = InstalledAppleTranslateClient()
            do {
                return try await client.translateText(
                    text,
                    sourceLanguage: source,
                    targetLanguageCode: targetLanguageCode,
                    maximumCharacters: maximumCharacters
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch TranslationProviderUnavailableError.languagePairNotInstalled {
                // LanguageAvailability can briefly report `.installed` before
                // a cold headless session becomes ready. Fall through to the
                // official translationTask host, which can prepare the same
                // on-device pair without sending text to a network provider.
                SelectionDiagnostics.record("headless session not ready; using local preparation host")
            }
        }

        let requestID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                startRequest(
                    id: requestID,
                    text: text,
                    source: source,
                    target: target,
                    maximumCharacters: maximumCharacters,
                    continuation: continuation
                )
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelRequest(id: requestID)
            }
        }
    }

    nonisolated fileprivate func performPendingRequest(
        using handle: AppleTranslationSessionHandle
    ) async {
        let session = handle.session
        guard let request = await pendingRequestSnapshot() else {
            return
        }

        do {
            SelectionDiagnostics.record("apple translation task attached")
            await updateStatus("如系统询问，请确认下载一次语言包。")
            try await session.prepareTranslation()
            try Task.checkCancellation()
            guard await isPendingRequest(id: request.id) else {
                return
            }

            await updateStatus("语言包已就绪，正在本机翻译…")
            SelectionDiagnostics.record("apple language pair ready")
            let translated = try await translatePreservingStructure(
                request.text,
                using: session,
                requestID: request.id
            )
            await finishRequest(id: request.id, result: .success(translated))
        } catch is CancellationError {
            await finishRequest(id: request.id, result: .failure(CancellationError()))
        } catch {
            await finishRequest(id: request.id, result: .failure(error))
        }
    }

    fileprivate func cancelPendingRequest() {
        guard let request = pendingRequest else {
            return
        }
        finishRequest(id: request.id, result: .failure(CancellationError()))
        configuration = nil
    }

    private func startRequest(
        id: UUID,
        text: String,
        source: Locale.Language,
        target: Locale.Language,
        maximumCharacters: Int,
        continuation: CheckedContinuation<String, Error>
    ) {
        let request = PendingRequest(
            id: id,
            text: text,
            source: source,
            target: target,
            maximumCharacters: maximumCharacters,
            continuation: continuation
        )
        let waitingBytes = queuedRequests.reduce(pendingRequest?.text.utf8.count ?? 0) {
            $0 + $1.text.utf8.count
        }
        guard waitingBytes + text.utf8.count <= Self.maximumInFlightTextBytes else {
            continuation.resume(
                throwing: TranslationWorkBrokerError.textBudgetExceeded(
                    limitBytes: Self.maximumInFlightTextBytes
                )
            )
            return
        }
        guard pendingRequest == nil else {
            guard queuedRequests.count < Self.maximumQueuedRequests else {
                continuation.resume(throwing: TranslationWorkBrokerError.manualQueueFull)
                return
            }
            queuedRequests.append(request)
            return
        }
        begin(request)
    }

    private func begin(_ request: PendingRequest) {
        hostReleaseTask?.cancel()
        hostReleaseTask = nil
        pendingRequest = request
        statusText = "正在准备 Apple 本地翻译…"
        SelectionDiagnostics.record("apple setup request started")
        ensureHostPanel()

        if var current = configuration,
           current.source == request.source,
           current.target == request.target {
            current.invalidate()
            configuration = current
        } else {
            configuration = TranslationSession.Configuration(
                source: request.source,
                target: request.target
            )
        }

        // The Translation host must be attached to a visible window on older
        // systems, but it must not take focus away from the captured selection.
        panel?.center()
        panel?.orderFrontRegardless()
    }

    private func finishRequest(id: UUID, result: Result<String, Error>) {
        guard let request = pendingRequest, request.id == id else {
            return
        }
        pendingRequest = nil
        request.continuation.resume(with: result)
        if queuedRequests.isEmpty {
            panel?.orderOut(nil)
            scheduleHostRelease()
        } else {
            let next = queuedRequests.removeFirst()
            begin(next)
        }
    }

    private func pendingRequestSnapshot() -> RequestSnapshot? {
        pendingRequest.map { RequestSnapshot(id: $0.id, text: $0.text) }
    }

    private func isPendingRequest(id: UUID) -> Bool {
        pendingRequest?.id == id
    }

    private func updateStatus(_ status: String) {
        statusText = status
    }

    private func cancelRequest(id: UUID) {
        if pendingRequest?.id == id {
            finishRequest(id: id, result: .failure(CancellationError()))
            return
        }
        guard let index = queuedRequests.firstIndex(where: { $0.id == id }) else {
            return
        }
        let request = queuedRequests.remove(at: index)
        request.continuation.resume(throwing: CancellationError())
    }

    func releaseIdleResources() {
        guard pendingRequest == nil, queuedRequests.isEmpty else {
            return
        }
        hostReleaseTask?.cancel()
        hostReleaseTask = nil
        configuration = nil
        hostingView = nil
        panel?.contentView = nil
        panel?.close()
        panel = nil
    }

    private func scheduleHostRelease() {
        hostReleaseTask?.cancel()
        hostReleaseTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: Self.hostIdleReleaseDelay)
            } catch {
                return
            }
            self?.releaseIdleResources()
        }
    }

    private func ensureHostPanel() {
        guard panel == nil else {
            return
        }

        let host = NSHostingView(rootView: AppleTranslationHostView(coordinator: self))
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 390, height: 132),
            styleMask: [.titled, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.title = "准备本地翻译"
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.level = .floating
        window.contentView = host
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel = window
        hostingView = host
    }

    nonisolated private func translatePreservingStructure(
        _ text: String,
        using session: TranslationSession,
        requestID: UUID
    ) async throws -> String {
        let chunks = TranslationChunker.chunks(for: text)
        var translated = ""
        for chunk in chunks {
            try Task.checkCancellation()
            guard await isPendingRequest(id: requestID) else {
                throw CancellationError()
            }
            if chunk.shouldTranslate {
                translated += try await session.translate(chunk.text).targetText
            } else {
                translated += chunk.text
            }
            guard await isPendingRequest(id: requestID) else {
                throw CancellationError()
            }
        }

        guard !translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TranslationError.emptyTranslation
        }
        return translated
    }
}

/// The framework scopes this non-Sendable session to the `translationTask`
/// callback. The handle is never persisted and the callback awaits all work,
/// so there is one owner and no concurrent access while crossing from SwiftUI's
/// main-actor view into the async Translation methods.
@available(macOS 15.0, *)
fileprivate struct AppleTranslationSessionHandle: @unchecked Sendable {
    let session: TranslationSession
}

@available(macOS 15.0, *)
private struct AppleTranslationHostView: View {
    @ObservedObject var coordinator: AppleTranslationCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "translate")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Apple 本地翻译")
                        .font(.headline)
                    Text(coordinator.statusText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Text("原文与译文不会发送给第三方翻译网站。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("取消") {
                    coordinator.cancelPendingRequest()
                }
            }
        }
        .padding(18)
        .frame(width: 390, height: 132)
        .translationTask(coordinator.configuration) { session in
            await coordinator.performPendingRequest(
                using: AppleTranslationSessionHandle(session: session)
            )
        }
    }
}
#endif
