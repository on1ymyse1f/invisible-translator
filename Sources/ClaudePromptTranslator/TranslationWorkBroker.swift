import Foundation

/// Identifies a translation source without retaining any source text in telemetry.
enum TranslationWorkKind: String, Sendable, CaseIterable {
    case manual
    case automaticSelection
    case automaticResponse
    case subtitle
    case hover

    var isManual: Bool {
        self == .manual
    }
}

enum TranslationWorkBrokerError: LocalizedError, Equatable {
    case manualQueueFull
    case textBudgetExceeded(limitBytes: Int)

    var errorDescription: String? {
        switch self {
        case .manualQueueFull:
            return "已有两项手动翻译正在等待；请取消旧任务后再试。"
        case .textBudgetExceeded(let limitBytes):
            return "待翻译正文超过内存预算（\(limitBytes / 1_024) KiB）；请缩小本次范围。"
        }
    }
}

/// A bounded, single-session broker for local translation work.
///
/// Only one operation is executed at a time. Manual work preempts automatic
/// work, while queued automatic work is latest-wins per source. The broker
/// keeps only the text already owned by each request closure and accounts for
/// its UTF-8 size; it never logs or persists the source text.
actor TranslationWorkBroker {
    static let shared = TranslationWorkBroker()

    static let defaultMaximumTextBytes = 1_048_576
    static let defaultMaximumWaitingManualItems = 2

    private final class Request: @unchecked Sendable {
        let id: UUID
        let kind: TranslationWorkKind
        let text: String
        let operation: @Sendable (String) async throws -> String
        let continuation: CheckedContinuation<String, Error>

        init(
            id: UUID,
            kind: TranslationWorkKind,
            text: String,
            operation: @escaping @Sendable (String) async throws -> String,
            continuation: CheckedContinuation<String, Error>
        ) {
            self.id = id
            self.kind = kind
            self.text = text
            self.operation = operation
            self.continuation = continuation
        }

        var textBytes: Int { text.utf8.count }
    }

    private let maximumTextBytes: Int
    private let maximumWaitingManualItems: Int
    private var activeRequest: Request?
    private var activeTask: Task<Void, Never>?
    private var queuedRequests: [Request] = []
    private var accountedTextBytes = 0

    init(
        maximumTextBytes: Int = TranslationWorkBroker.defaultMaximumTextBytes,
        maximumWaitingManualItems: Int = TranslationWorkBroker.defaultMaximumWaitingManualItems
    ) {
        self.maximumTextBytes = maximumTextBytes
        self.maximumWaitingManualItems = maximumWaitingManualItems
    }

    func submit(
        text: String,
        kind: TranslationWorkKind,
        operation: @escaping @Sendable (String) async throws -> String
    ) async throws -> String {
        let requestID = UUID()
        let textBytes = text.utf8.count
        guard textBytes <= maximumTextBytes else {
            throw TranslationWorkBrokerError.textBudgetExceeded(limitBytes: maximumTextBytes)
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                enqueue(
                    Request(
                        id: requestID,
                        kind: kind,
                        text: text,
                        operation: operation,
                        continuation: continuation
                    )
                )
            }
        } onCancel: {
            Task { await self.cancel(id: requestID) }
        }
    }

    func cancelAll() {
        activeTask?.cancel()
        activeTask = nil
        if let activeRequest {
            activeRequest.continuation.resume(throwing: CancellationError())
            accountedTextBytes -= activeRequest.textBytes
            self.activeRequest = nil
        }
        let queued = queuedRequests
        queuedRequests.removeAll(keepingCapacity: false)
        for request in queued {
            request.continuation.resume(throwing: CancellationError())
        }
        accountedTextBytes = 0
    }

    func snapshot() -> (active: TranslationWorkKind?, queued: Int, textBytes: Int) {
        (activeRequest?.kind, queuedRequests.count, accountedTextBytes)
    }

    private func enqueue(_ request: Request) {
        if request.kind.isManual {
            let waitingManualCount = queuedRequests.lazy.filter(\.kind.isManual).count
            guard waitingManualCount < maximumWaitingManualItems else {
                request.continuation.resume(throwing: TranslationWorkBrokerError.manualQueueFull)
                return
            }
        } else {
            replaceQueuedAutomaticWork(of: request.kind)
        }

        guard accountedTextBytes + request.textBytes <= maximumTextBytes else {
            request.continuation.resume(
                throwing: TranslationWorkBrokerError.textBudgetExceeded(limitBytes: maximumTextBytes)
            )
            return
        }

        accountedTextBytes += request.textBytes
        if activeRequest == nil {
            begin(request)
            return
        }

        if request.kind.isManual, activeRequest?.kind.isManual == false {
            // Manual intent is explicit. Cancel the running automatic job so it
            // cannot hold an Apple TranslationSession while the user waits.
            activeTask?.cancel()
            queuedRequests.insert(request, at: 0)
        } else if request.kind.isManual {
            let automaticIndex = queuedRequests.firstIndex { !$0.kind.isManual }
                ?? queuedRequests.endIndex
            queuedRequests.insert(request, at: automaticIndex)
        } else {
            queuedRequests.append(request)
        }
    }

    private func replaceQueuedAutomaticWork(of kind: TranslationWorkKind) {
        var retained: [Request] = []
        for request in queuedRequests {
            if request.kind == kind {
                accountedTextBytes -= request.textBytes
                request.continuation.resume(throwing: CancellationError())
            } else {
                retained.append(request)
            }
        }
        queuedRequests = retained

        if activeRequest?.kind == kind {
            activeTask?.cancel()
        }
    }

    private func begin(_ request: Request) {
        activeRequest = request
        activeTask = Task { [weak self] in
            let result: Result<String, Error>
            do {
                result = .success(try await request.operation(request.text))
            } catch {
                result = .failure(error)
            }
            await self?.finish(id: request.id, result: result)
        }
    }

    private func finish(id: UUID, result: Result<String, Error>) {
        guard let request = activeRequest, request.id == id else {
            return
        }
        activeRequest = nil
        activeTask = nil
        accountedTextBytes -= request.textBytes
        request.continuation.resume(with: result)

        guard !queuedRequests.isEmpty else {
            accountedTextBytes = max(0, accountedTextBytes)
            return
        }
        let next = queuedRequests.removeFirst()
        begin(next)
    }

    private func cancel(id: UUID) {
        if activeRequest?.id == id {
            activeTask?.cancel()
            return
        }
        guard let index = queuedRequests.firstIndex(where: { $0.id == id }) else {
            return
        }
        let request = queuedRequests.remove(at: index)
        accountedTextBytes -= request.textBytes
        request.continuation.resume(throwing: CancellationError())
    }
}
