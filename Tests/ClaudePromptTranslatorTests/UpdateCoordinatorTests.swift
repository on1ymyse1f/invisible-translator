import Foundation
import XCTest
@testable import ClaudePromptTranslator

@MainActor
final class UpdateCoordinatorTests: XCTestCase {
    func testInitialLaunchPersistsOnlyTwentyFourHourDeadlineWithoutStartingUpdater() throws {
        let suiteName = "UpdateCoordinatorTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Could not create isolated defaults.")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let driver = RecordingUpdateDriver()
        let coordinator = UpdateCoordinator(defaults: defaults, driver: driver)
        let start = Date(timeIntervalSince1970: 1_900_000_000)

        XCTAssertEqual(
            coordinator.scheduleInitialDeadlineIfNeeded(at: start),
            start.addingTimeInterval(UpdateCoordinator.checkInterval)
        )
        XCTAssertEqual(driver.startCount, 0)
        XCTAssertEqual(driver.checkCount, 0)
        XCTAssertFalse(coordinator.shouldPerformScheduledCheck(at: start))
        XCTAssertFalse(
            coordinator.shouldPerformScheduledCheck(
                at: start.addingTimeInterval(UpdateCoordinator.checkInterval - 1)
            )
        )
        XCTAssertTrue(
            coordinator.shouldPerformScheduledCheck(
                at: start.addingTimeInterval(UpdateCoordinator.checkInterval)
            )
        )
        XCTAssertFalse(try coordinator.performScheduledCheck(at: start))
        // The explicit early call is intentionally skipped until the deadline.
        XCTAssertEqual(driver.startCount, 0)
        XCTAssertEqual(driver.checkCount, 0)
        XCTAssertTrue(
            try coordinator.performScheduledCheck(
                at: start.addingTimeInterval(UpdateCoordinator.checkInterval)
            )
        )
        XCTAssertEqual(driver.startCount, 1)
        XCTAssertEqual(driver.checkCount, 1)
        XCTAssertEqual(
            coordinator.nextCheckDeadline,
            start.addingTimeInterval(2 * UpdateCoordinator.checkInterval)
        )
        let persistedKeys = Set((defaults.persistentDomain(forName: suiteName) ?? [:]).keys)
        XCTAssertEqual(persistedKeys, [UpdateCoordinator.deadlineDefaultsKey])

        XCTAssertFalse(
            try coordinator.performScheduledCheck(
                at: start.addingTimeInterval(2 * UpdateCoordinator.checkInterval - 1)
            )
        )
        XCTAssertEqual(driver.checkCount, 1)
        XCTAssertTrue(
            try coordinator.performScheduledCheck(
                at: start.addingTimeInterval(2 * UpdateCoordinator.checkInterval)
            )
        )
        XCTAssertEqual(driver.startCount, 1)
        XCTAssertEqual(driver.checkCount, 2)
    }

    func testUnavailableUpdaterDoesNotCreateSchedule() throws {
        let suiteName = "UpdateCoordinatorTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Could not create isolated defaults.")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let coordinator = UpdateCoordinator(
            defaults: defaults,
            driver: UnavailableUpdateDriver()
        )
        XCTAssertFalse(coordinator.shouldPerformScheduledCheck())
        XCTAssertThrowsError(try coordinator.performUserInitiatedCheck()) { error in
            XCTAssertEqual(error as? UpdateCoordinatorError, .updaterUnavailable)
        }
        XCTAssertNil(coordinator.scheduleInitialDeadlineIfNeeded())
        XCTAssertNil(coordinator.nextCheckDeadline)
        XCTAssertTrue(defaults.persistentDomain(forName: suiteName)?.isEmpty ?? true)
    }
}

@MainActor
private final class RecordingUpdateDriver: UpdateDriving {
    let isAvailable = true
    private(set) var startCount = 0
    private(set) var checkCount = 0

    func startIfNeeded() throws {
        if startCount == 0 {
            startCount = 1
        }
    }

    func checkForUpdates() {
        checkCount += 1
    }

    func releaseAfterCheck() {}
}
