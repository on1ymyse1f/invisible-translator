import CoreGraphics
import Foundation
import XCTest
@testable import ClaudePromptTranslator

final class RuntimeLifecycleTests: XCTestCase {
    func testRuntimeDemandActivatesOnlyResourcesWhosePrerequisitesAreMet() {
        let disabled = RuntimeContext(
            translatorEnabled: false,
            accessibilityTrusted: true,
            selectionEnabled: true,
            hoverEnabled: true,
            unifiedBarEnabled: true,
            responseTranslationEnabled: true,
            foregroundIsAI: true,
            subtitleActive: true,
            promptUIVisible: true
        )
        XCTAssertEqual(
            AppRuntimeCoordinator.requiredDemand(for: disabled),
            [.promptUI]
        )

        let missingAccessibility = RuntimeContext(
            translatorEnabled: true,
            accessibilityTrusted: false,
            selectionEnabled: true,
            hoverEnabled: true,
            unifiedBarEnabled: true,
            responseTranslationEnabled: true,
            foregroundIsAI: true,
            subtitleActive: true,
            guideUIVisible: true
        )
        XCTAssertEqual(
            AppRuntimeCoordinator.requiredDemand(for: missingAccessibility),
            [.subtitle, .guideUI]
        )

        var ready = missingAccessibility
        ready.accessibilityTrusted = true
        XCTAssertEqual(
            AppRuntimeCoordinator.requiredDemand(for: ready),
            [.selection, .hover, .aiContext, .replyScanning, .subtitle, .guideUI]
        )
    }

    func testRuntimeCoordinatorReportsStartedAndStoppedDemand() {
        var coordinator = AppRuntimeCoordinator()
        let context = RuntimeContext(
            translatorEnabled: true,
            accessibilityTrusted: true,
            selectionEnabled: true,
            unifiedBarEnabled: true,
            responseTranslationEnabled: true,
            foregroundIsAI: true
        )

        let started = coordinator.handle(.reconcile(context))
        XCTAssertEqual(started.started, [.selection, .aiContext, .replyScanning])
        XCTAssertTrue(started.stopped.isEmpty)

        let suspended = coordinator.handle(.setSuspended(true))
        XCTAssertTrue(suspended.started.isEmpty)
        XCTAssertEqual(suspended.stopped, [.selection, .aiContext, .replyScanning])
        XCTAssertTrue(coordinator.demand.isEmpty)

        let resumed = coordinator.handle(.setSuspended(false))
        XCTAssertEqual(resumed.started, [.selection, .aiContext, .replyScanning])
        XCTAssertTrue(resumed.stopped.isEmpty)
    }

    func testRuntimeTerminationIsSticky() {
        var coordinator = AppRuntimeCoordinator()
        _ = coordinator.handle(
            .reconcile(
                RuntimeContext(
                    translatorEnabled: true,
                    accessibilityTrusted: true,
                    selectionEnabled: true
                )
            )
        )

        let terminated = coordinator.handle(.terminate)
        XCTAssertEqual(terminated.stopped, [.selection])
        XCTAssertTrue(coordinator.isTerminated)
        XCTAssertTrue(coordinator.demand.isEmpty)

        _ = coordinator.handle(
            .reconcile(
                RuntimeContext(
                    translatorEnabled: true,
                    accessibilityTrusted: true,
                    selectionEnabled: true,
                    hoverEnabled: true
                )
            )
        )
        XCTAssertTrue(coordinator.demand.isEmpty)
    }

    @MainActor
    func testTaskSlotDeliversOnlyLatestGeneration() async {
        let recorder = IntRecorder()
        let slot = TaskSlot<Int>()

        slot.replace(operation: {
            try? await Task.sleep(nanoseconds: 100_000_000)
            return 1
        }, deliver: { value in
            recorder.values.append(value)
        })
        slot.replace(operation: {
            try? await Task.sleep(nanoseconds: 10_000_000)
            return 2
        }, deliver: { value in
            recorder.values.append(value)
        })

        try? await Task.sleep(nanoseconds: 180_000_000)
        XCTAssertEqual(recorder.values, [2])
        XCTAssertFalse(slot.isRunning)
    }

    @MainActor
    func testTaskSlotCancellationSuppressesLateDelivery() async {
        let recorder = IntRecorder()
        let slot = TaskSlot<Int>()
        slot.replace(operation: {
            try? await Task.sleep(nanoseconds: 30_000_000)
            return 1
        }, deliver: { value in
            recorder.values.append(value)
        })

        slot.cancel()
        try? await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertTrue(recorder.values.isEmpty)
        XCTAssertFalse(slot.isRunning)
    }

    func testMemoryBudgetedCacheUsesLRUCountCostAndTTL() {
        let start = Date(timeIntervalSinceReferenceDate: 10_000)
        var cache = MemoryBudgetedCache<String, String>(
            maximumEntryCount: 2,
            maximumCost: 5,
            timeToLive: 10
        )

        cache.insert("A", for: "a", cost: 2, now: start)
        cache.insert("B", for: "b", cost: 2, now: start)
        XCTAssertEqual(cache.value(for: "a", now: start), "A")
        cache.insert("C", for: "c", cost: 2, now: start)

        XCTAssertNil(cache.value(for: "b", now: start))
        XCTAssertEqual(cache.value(for: "a", now: start), "A")
        XCTAssertEqual(cache.value(for: "c", now: start), "C")
        XCTAssertEqual(cache.count, 2)
        XCTAssertEqual(cache.totalCost, 4)

        XCTAssertNil(cache.value(for: "a", now: start.addingTimeInterval(10.1)))
        XCTAssertEqual(cache.count, 0)
        XCTAssertEqual(cache.totalCost, 0)
    }

    func testMemoryBudgetedCacheRejectsOversizeAndRespondsToPressure() {
        let start = Date(timeIntervalSinceReferenceDate: 20_000)
        var cache = MemoryBudgetedCache<String, String>(
            maximumEntryCount: 4,
            maximumCost: 10,
            timeToLive: 60
        )

        cache.insert("too large", for: "oversize", cost: 11, now: start)
        XCTAssertNil(cache.value(for: "oversize", now: start))

        cache.insert("A", for: "a", cost: 4, now: start)
        cache.insert("B", for: "b", cost: 4, now: start)
        XCTAssertEqual(cache.value(for: "b", now: start), "B")
        cache.applyMemoryPressure(.warning, now: start)
        XCTAssertEqual(cache.count, 1)
        XCTAssertEqual(cache.value(for: "b", now: start), "B")
        XCTAssertLessThanOrEqual(cache.totalCost, 5)

        cache.applyMemoryPressure(.critical, now: start)
        XCTAssertEqual(cache.count, 0)
        XCTAssertEqual(cache.totalCost, 0)
    }

    func testMemoryPressurePolicyNeverRequestsUserTaskCancellation() {
        XCTAssertEqual(MemoryPressurePolicy.actions(for: .normal), [])
        XCTAssertEqual(
            MemoryPressurePolicy.actions(for: .warning),
            [.trimCaches, .releaseHiddenUI]
        )
        XCTAssertEqual(
            MemoryPressurePolicy.actions(for: .critical),
            [
                .trimCaches,
                .releaseHiddenUI,
                .releaseIdleTranslationHost,
                .releaseIdleAccessibilityContexts
            ]
        )
    }

    func testSelectionMonitorFiltersUnrelatedKeyUpsBeforeMainActorDelivery() {
        XCTAssertFalse(
            SelectionMonitorEventPolicy.shouldDispatchKeyUp(
                keyCode: 0,
                shiftPressed: false,
                commandPressed: false
            )
        )
        XCTAssertFalse(
            SelectionMonitorEventPolicy.shouldDispatchKeyUp(
                keyCode: 0,
                shiftPressed: true,
                commandPressed: false
            )
        )
        XCTAssertTrue(
            SelectionMonitorEventPolicy.shouldDispatchKeyUp(
                keyCode: 123,
                shiftPressed: true,
                commandPressed: false
            )
        )
        XCTAssertTrue(
            SelectionMonitorEventPolicy.shouldDispatchKeyUp(
                keyCode: 0,
                shiftPressed: false,
                commandPressed: true
            )
        )
        XCTAssertFalse(
            SelectionMonitorEventPolicy.shouldDispatchKeyUp(
                keyCode: 11,
                shiftPressed: false,
                commandPressed: true
            )
        )
    }

    func testSelectionMonitorRequiresDragThresholdButKeepsMultiClickSelection() {
        XCTAssertFalse(
            SelectionMonitorEventPolicy.shouldInspectMouseUp(
                dragStart: CGPoint(x: 10, y: 10),
                dragEnd: CGPoint(x: 11, y: 11),
                clickCount: 1
            )
        )
        XCTAssertTrue(
            SelectionMonitorEventPolicy.shouldInspectMouseUp(
                dragStart: CGPoint(x: 10, y: 10),
                dragEnd: CGPoint(x: 13, y: 10),
                clickCount: 1
            )
        )
        XCTAssertTrue(
            SelectionMonitorEventPolicy.shouldInspectMouseUp(
                dragStart: nil,
                dragEnd: nil,
                clickCount: 2
            )
        )
        XCTAssertTrue(
            SelectionMonitorEventPolicy.shouldInspectMouseUp(
                dragStart: CGPoint(x: 10, y: 10),
                dragEnd: CGPoint(x: 10, y: 10),
                clickCount: 1,
                extendsExistingSelection: true
            )
        )
    }

    func testHoverEventDeliveryPolicyCapsMainQueueDeliveryAtTenHertz() {
        XCTAssertEqual(
            HoverEventDeliveryPolicy.nextDelay(
                lastDeliveryUptime: -.infinity,
                currentUptime: 100
            ),
            0
        )
        XCTAssertEqual(
            HoverEventDeliveryPolicy.nextDelay(
                lastDeliveryUptime: 100,
                currentUptime: 100.04
            ),
            0.06,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            HoverEventDeliveryPolicy.nextDelay(
                lastDeliveryUptime: 100,
                currentUptime: 100.1
            ),
            0,
            accuracy: 0.000_001
        )
    }

    @MainActor
    func testHoverEventCoalescerDeliversLatestPointOnly() async {
        let recorder = PointRecorder()
        let coalescer = HoverEventCoalescer(maximumDeliveriesPerSecond: 10)

        for index in 0..<20 {
            coalescer.submit(CGPoint(x: index, y: index)) { point in
                recorder.values.append(point)
            }
        }

        try? await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertEqual(recorder.values, [CGPoint(x: 19, y: 19)])

        coalescer.submit(CGPoint(x: 20, y: 20)) { point in
            recorder.values.append(point)
        }
        coalescer.submit(CGPoint(x: 21, y: 21)) { point in
            recorder.values.append(point)
        }
        try? await Task.sleep(nanoseconds: 130_000_000)
        XCTAssertEqual(recorder.values.last, CGPoint(x: 21, y: 21))
        XCTAssertEqual(recorder.values.count, 2)
    }

    @MainActor
    func testHoverEventCoalescerDropsQueuedPointAfterCancellation() async {
        let recorder = PointRecorder()
        let coalescer = HoverEventCoalescer(maximumDeliveriesPerSecond: 10)

        coalescer.submit(CGPoint(x: 1, y: 1)) { point in
            recorder.values.append(point)
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        coalescer.submit(CGPoint(x: 2, y: 2)) { point in
            recorder.values.append(point)
        }
        coalescer.cancel()
        try? await Task.sleep(nanoseconds: 120_000_000)

        XCTAssertEqual(recorder.values, [CGPoint(x: 1, y: 1)])
    }

    func testPerformanceSignpostAcceptsOnlyClosedNumericMetadata() {
        let interval = PerformanceSignpost.begin(.accessibilityScan, units: 12, bytes: 256)
        PerformanceSignpost.end(interval, outcome: .succeeded, units: 12)
        PerformanceSignpost.event(.eventsCoalesced, count: 4, bytes: 0)
    }
}

@MainActor
private final class IntRecorder {
    var values: [Int] = []
}

@MainActor
private final class PointRecorder {
    var values: [CGPoint] = []
}
