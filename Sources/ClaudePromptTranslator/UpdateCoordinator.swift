import Foundation

#if canImport(Sparkle)
import Sparkle
#endif

enum UpdateCoordinatorError: LocalizedError, Equatable {
    case updaterUnavailable
    case updaterStartFailed

    var errorDescription: String? {
        switch self {
        case .updaterUnavailable:
            return "当前构建未包含更新组件。"
        case .updaterStartFailed:
            return "更新组件未能安全启动。"
        }
    }
}

@MainActor
protocol UpdateDriving: AnyObject {
    var isAvailable: Bool { get }
    func startIfNeeded() throws
    func checkForUpdates()
    /// Drops an updater controller once the caller no longer needs its UI.
    /// This is intentionally separate from checking: Sparkle may still be
    /// presenting its standard update window on the current run loop.
    func releaseAfterCheck()
}

@MainActor
final class UnavailableUpdateDriver: UpdateDriving {
    let isAvailable = false

    func startIfNeeded() throws {
        throw UpdateCoordinatorError.updaterUnavailable
    }

    func checkForUpdates() {}

    func releaseAfterCheck() {}
}

#if canImport(Sparkle)
@MainActor
final class SparkleUpdateDriver: UpdateDriving {
    private var controller: SPUStandardUpdaterController?
    private var started = false

    var isAvailable: Bool { true }

    func startIfNeeded() throws {
        guard !started else { return }
        do {
            let controller = SPUStandardUpdaterController(
                startingUpdater: false,
                updaterDelegate: nil,
                userDriverDelegate: nil
            )
            try controller.updater.start()
            self.controller = controller
            started = true
        } catch {
            throw UpdateCoordinatorError.updaterStartFailed
        }
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    func releaseAfterCheck() {
        controller = nil
        started = false
    }
}
#endif

@MainActor
final class UpdateCoordinator {
    static let checkInterval: TimeInterval = 24 * 60 * 60
    static let deadlineDefaultsKey = "updateCoordinator.nextCheckDeadline.v1"

    private let defaults: UserDefaults
    private let driver: any UpdateDriving

    init(
        defaults: UserDefaults = .standard,
        driver: (any UpdateDriving)? = nil
    ) {
        self.defaults = defaults
        self.driver = driver ?? Self.platformDriver()
    }

    var isUpdaterAvailable: Bool {
        driver.isAvailable
    }

    var nextCheckDeadline: Date? {
        guard defaults.object(forKey: Self.deadlineDefaultsKey) != nil else { return nil }
        let timestamp = defaults.double(forKey: Self.deadlineDefaultsKey)
        guard timestamp.isFinite, timestamp > 0 else { return nil }
        return Date(timeIntervalSince1970: timestamp)
    }

    /// The first launch only records a future deadline. It must not create an
    /// updater controller or open a network connection.
    @discardableResult
    func scheduleInitialDeadlineIfNeeded(at date: Date = Date()) -> Date? {
        guard driver.isAvailable else { return nil }
        if let existing = nextCheckDeadline {
            return existing
        }
        let deadline = date.addingTimeInterval(Self.checkInterval)
        defaults.set(deadline.timeIntervalSince1970, forKey: Self.deadlineDefaultsKey)
        return deadline
    }

    func shouldPerformScheduledCheck(at date: Date = Date()) -> Bool {
        guard driver.isAvailable else { return false }
        guard let deadline = nextCheckDeadline else { return false }
        return date >= deadline
    }

    @discardableResult
    func performScheduledCheck(at date: Date = Date()) throws -> Bool {
        guard shouldPerformScheduledCheck(at: date) else { return false }
        try performCheck(at: date)
        return true
    }

    func performUserInitiatedCheck(at date: Date = Date()) throws {
        try performCheck(at: date)
    }

    func resetSchedule() {
        defaults.removeObject(forKey: Self.deadlineDefaultsKey)
    }

    /// Releases the optional Sparkle controller after its standard UI has had
    /// time to complete. This also makes memory pressure/termination handling
    /// deterministic in builds that include Sparkle.
    func releaseUpdaterAfterCheck() {
        driver.releaseAfterCheck()
    }

    private func performCheck(at date: Date) throws {
        guard driver.isAvailable else {
            throw UpdateCoordinatorError.updaterUnavailable
        }
        try driver.startIfNeeded()
        driver.checkForUpdates()
        let deadline = date.addingTimeInterval(Self.checkInterval)
        defaults.set(deadline.timeIntervalSince1970, forKey: Self.deadlineDefaultsKey)
    }

    private static func platformDriver() -> any UpdateDriving {
        #if canImport(Sparkle)
        return SparkleUpdateDriver()
        #else
        return UnavailableUpdateDriver()
        #endif
    }
}
