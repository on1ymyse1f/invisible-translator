import Dispatch
import Foundation
import OSLog

struct RuntimeDemand: OptionSet, Equatable, Sendable {
    let rawValue: UInt16

    static let selection = RuntimeDemand(rawValue: 1 << 0)
    static let hover = RuntimeDemand(rawValue: 1 << 1)
    static let aiContext = RuntimeDemand(rawValue: 1 << 2)
    static let replyScanning = RuntimeDemand(rawValue: 1 << 3)
    static let subtitle = RuntimeDemand(rawValue: 1 << 4)
    static let promptUI = RuntimeDemand(rawValue: 1 << 5)
    static let guideUI = RuntimeDemand(rawValue: 1 << 6)
}

struct RuntimeContext: Equatable, Sendable {
    var translatorEnabled: Bool
    var accessibilityTrusted: Bool
    var selectionEnabled: Bool
    var hoverEnabled: Bool
    var unifiedBarEnabled: Bool
    var responseTranslationEnabled: Bool
    var foregroundIsAI: Bool
    var subtitleActive: Bool
    var promptUIVisible: Bool
    var guideUIVisible: Bool

    init(
        translatorEnabled: Bool = false,
        accessibilityTrusted: Bool = false,
        selectionEnabled: Bool = false,
        hoverEnabled: Bool = false,
        unifiedBarEnabled: Bool = false,
        responseTranslationEnabled: Bool = false,
        foregroundIsAI: Bool = false,
        subtitleActive: Bool = false,
        promptUIVisible: Bool = false,
        guideUIVisible: Bool = false
    ) {
        self.translatorEnabled = translatorEnabled
        self.accessibilityTrusted = accessibilityTrusted
        self.selectionEnabled = selectionEnabled
        self.hoverEnabled = hoverEnabled
        self.unifiedBarEnabled = unifiedBarEnabled
        self.responseTranslationEnabled = responseTranslationEnabled
        self.foregroundIsAI = foregroundIsAI
        self.subtitleActive = subtitleActive
        self.promptUIVisible = promptUIVisible
        self.guideUIVisible = guideUIVisible
    }
}

enum RuntimeEvent: Equatable, Sendable {
    case reconcile(RuntimeContext)
    case setSuspended(Bool)
    case terminate
}

struct RuntimeTransition: Equatable, Sendable {
    let previous: RuntimeDemand
    let current: RuntimeDemand

    var started: RuntimeDemand {
        current.subtracting(previous)
    }

    var stopped: RuntimeDemand {
        previous.subtracting(current)
    }
}

/// Pure lifecycle reducer. It describes which resources are needed without
/// constructing timers, observers, event taps, windows, or translation sessions.
struct AppRuntimeCoordinator: Equatable, Sendable {
    private(set) var context = RuntimeContext()
    private(set) var demand: RuntimeDemand = []
    private(set) var isSuspended = false
    private(set) var isTerminated = false

    @discardableResult
    mutating func handle(_ event: RuntimeEvent) -> RuntimeTransition {
        let previous = demand

        switch event {
        case .reconcile(let context):
            guard !isTerminated else {
                return RuntimeTransition(previous: previous, current: demand)
            }
            self.context = context
        case .setSuspended(let suspended):
            guard !isTerminated else {
                return RuntimeTransition(previous: previous, current: demand)
            }
            isSuspended = suspended
        case .terminate:
            isTerminated = true
        }

        demand = Self.requiredDemand(
            for: context,
            isSuspended: isSuspended,
            isTerminated: isTerminated
        )
        return RuntimeTransition(previous: previous, current: demand)
    }

    static func requiredDemand(
        for context: RuntimeContext,
        isSuspended: Bool = false,
        isTerminated: Bool = false
    ) -> RuntimeDemand {
        guard !isSuspended, !isTerminated else {
            return []
        }

        var result: RuntimeDemand = []
        if context.promptUIVisible {
            result.insert(.promptUI)
        }
        if context.guideUIVisible {
            result.insert(.guideUI)
        }

        guard context.translatorEnabled else {
            return result
        }

        if context.subtitleActive {
            result.insert(.subtitle)
        }

        guard context.accessibilityTrusted else {
            return result
        }
        if context.selectionEnabled {
            result.insert(.selection)
        }
        if context.hoverEnabled {
            result.insert(.hover)
        }
        if context.unifiedBarEnabled, context.foregroundIsAI {
            result.insert(.aiContext)
            if context.responseTranslationEnabled {
                result.insert(.replyScanning)
            }
        }
        return result
    }
}

/// Owns one asynchronous operation. Replacing or cancelling it invalidates the
/// previous generation, so a late, non-cooperative result cannot be delivered.
@MainActor
final class TaskSlot<Value: Sendable> {
    typealias Operation = @Sendable () async -> Value
    typealias Delivery = @MainActor @Sendable (Value) -> Void

    private var task: Task<Void, Never>?
    private(set) var generation: UInt64 = 0

    var isRunning: Bool {
        task != nil
    }

    @discardableResult
    func replace(
        priority: TaskPriority? = nil,
        operation: @escaping Operation,
        deliver: @escaping Delivery
    ) -> UInt64 {
        generation &+= 1
        let ticket = generation
        task?.cancel()
        task = Task(priority: priority) { [weak self] in
            let value = await operation()
            guard !Task.isCancelled,
                  let self,
                  self.generation == ticket else {
                return
            }
            deliver(value)
            self.finish(ticket: ticket)
        }
        return ticket
    }

    func cancel() {
        generation &+= 1
        task?.cancel()
        task = nil
    }

    private func finish(ticket: UInt64) {
        guard generation == ticket else { return }
        task = nil
    }

    deinit {
        task?.cancel()
    }
}

enum RuntimeMemoryPressure: Equatable, Sendable {
    case normal
    case warning
    case critical
}

struct MemoryPressureActions: OptionSet, Equatable, Sendable {
    let rawValue: UInt8

    static let trimCaches = MemoryPressureActions(rawValue: 1 << 0)
    static let releaseHiddenUI = MemoryPressureActions(rawValue: 1 << 1)
    static let releaseIdleTranslationHost = MemoryPressureActions(rawValue: 1 << 2)
    static let releaseIdleAccessibilityContexts = MemoryPressureActions(rawValue: 1 << 3)
}

enum MemoryPressurePolicy {
    static func actions(for pressure: RuntimeMemoryPressure) -> MemoryPressureActions {
        switch pressure {
        case .normal:
            return []
        case .warning:
            return [.trimCaches, .releaseHiddenUI]
        case .critical:
            return [
                .trimCaches,
                .releaseHiddenUI,
                .releaseIdleTranslationHost,
                .releaseIdleAccessibilityContexts
            ]
        }
    }
}

struct MemoryBudgetedCache<Key: Hashable & Sendable, Value: Sendable>: Sendable {
    private struct Entry: Sendable {
        let value: Value
        let cost: Int
        let expiresAt: Date
    }

    let maximumEntryCount: Int
    let maximumCost: Int
    let timeToLive: TimeInterval

    private var entries: [Key: Entry] = [:]
    private var recency: [Key] = []
    private(set) var totalCost = 0

    init(
        maximumEntryCount: Int,
        maximumCost: Int,
        timeToLive: TimeInterval
    ) {
        self.maximumEntryCount = max(1, maximumEntryCount)
        self.maximumCost = max(1, maximumCost)
        self.timeToLive = max(0.001, timeToLive)
    }

    var count: Int {
        entries.count
    }

    mutating func value(for key: Key, now: Date = Date()) -> Value? {
        removeExpiredEntries(now: now)
        guard let entry = entries[key] else { return nil }
        markMostRecent(key)
        return entry.value
    }

    mutating func insert(
        _ value: Value,
        for key: Key,
        cost: Int,
        now: Date = Date()
    ) {
        removeExpiredEntries(now: now)
        removeValue(for: key)

        let boundedCost = max(0, cost)
        guard boundedCost <= maximumCost else {
            return
        }

        entries[key] = Entry(
            value: value,
            cost: boundedCost,
            expiresAt: now.addingTimeInterval(timeToLive)
        )
        totalCost += boundedCost
        recency.append(key)
        evictToConfiguredBudget()
    }

    @discardableResult
    mutating func removeValue(for key: Key) -> Value? {
        guard let removed = entries.removeValue(forKey: key) else {
            return nil
        }
        totalCost -= removed.cost
        recency.removeAll { $0 == key }
        return removed.value
    }

    mutating func removeAll() {
        entries.removeAll(keepingCapacity: false)
        recency.removeAll(keepingCapacity: false)
        totalCost = 0
    }

    mutating func applyMemoryPressure(
        _ pressure: RuntimeMemoryPressure,
        now: Date = Date()
    ) {
        removeExpiredEntries(now: now)
        switch pressure {
        case .normal:
            return
        case .warning:
            trim(toCost: maximumCost / 2)
        case .critical:
            removeAll()
        }
    }

    mutating func trim(toCost requestedCost: Int) {
        let targetCost = max(0, requestedCost)
        while totalCost > targetCost, let oldest = recency.first {
            removeValue(for: oldest)
        }
    }

    private mutating func markMostRecent(_ key: Key) {
        recency.removeAll { $0 == key }
        recency.append(key)
    }

    private mutating func evictToConfiguredBudget() {
        while entries.count > maximumEntryCount || totalCost > maximumCost {
            guard let oldest = recency.first else { break }
            removeValue(for: oldest)
        }
    }

    private mutating func removeExpiredEntries(now: Date) {
        let expiredKeys = entries.compactMap { key, entry in
            entry.expiresAt <= now ? key : nil
        }
        for key in expiredKeys {
            removeValue(for: key)
        }
    }
}

@MainActor
final class RuntimeMemoryPressureMonitor {
    typealias Handler = @MainActor (RuntimeMemoryPressure) -> Void

    private let handler: Handler
    private var source: DispatchSourceMemoryPressure?

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    var isRunning: Bool {
        source != nil
    }

    func start() {
        guard source == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .main
        )
        self.source = source
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, let data = self.source?.data else { return }
                self.handler(data.contains(.critical) ? .critical : .warning)
            }
        }
        source.resume()
    }

    func stop() {
        source?.cancel()
        source = nil
    }
}

enum PerformanceOperation: Int, Equatable, Sendable {
    case selectionDebounce = 1
    case hoverDwell
    case accessibilityScan
    case responseScan
    case screenOCR
    case translation
    case uiRender
    case cacheMaintenance
}

enum PerformanceOutcome: Int, Equatable, Sendable {
    case succeeded = 1
    case cancelled
    case failed
    case skipped
}

enum PerformanceRuntimeEvent: Int, Equatable, Sendable {
    case resourceStarted = 1
    case resourceStopped
    case cacheTrimmed
    case eventsCoalesced
}

/// Signpost metadata is intentionally closed over numeric enums and bounded
/// counts. There is no API accepting source text, translations, application
/// identity, window titles, URLs, screen coordinates, or arbitrary strings.
enum PerformanceSignpost {
    struct Interval: @unchecked Sendable {
        fileprivate let operation: PerformanceOperation
        fileprivate let state: OSSignpostIntervalState
    }

    private static let signposter = OSSignposter(
        subsystem: "local.codex.ClaudePromptTranslator",
        category: "Performance"
    )

    static func begin(
        _ operation: PerformanceOperation,
        units: Int = 0,
        bytes: Int = 0
    ) -> Interval {
        let state = signposter.beginInterval(
            "RuntimeOperation",
            "operation=\(operation.rawValue, privacy: .public) units=\(bounded(units), privacy: .public) bytes=\(bounded(bytes), privacy: .public)"
        )
        return Interval(operation: operation, state: state)
    }

    static func end(
        _ interval: Interval,
        outcome: PerformanceOutcome,
        units: Int = 0
    ) {
        signposter.endInterval(
            "RuntimeOperation",
            interval.state,
            "operation=\(interval.operation.rawValue, privacy: .public) outcome=\(outcome.rawValue, privacy: .public) units=\(bounded(units), privacy: .public)"
        )
    }

    static func event(
        _ event: PerformanceRuntimeEvent,
        count: Int = 0,
        bytes: Int = 0
    ) {
        signposter.emitEvent(
            "RuntimeEvent",
            "event=\(event.rawValue, privacy: .public) count=\(bounded(count), privacy: .public) bytes=\(bounded(bytes), privacy: .public)"
        )
    }

    private static func bounded(_ value: Int) -> Int {
        min(max(value, 0), 1_000_000_000)
    }
}
