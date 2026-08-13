import XCTest
@testable import ClaudePromptTranslator

private actor TranslationBrokerTestGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func releaseAll() {
        let current = waiters
        waiters.removeAll()
        current.forEach { $0.resume() }
    }
}

final class TranslationWorkBrokerTests: XCTestCase {
    func testRejectsOneRequestLargerThanTotalTextBudget() async {
        let broker = TranslationWorkBroker(maximumTextBytes: 8)

        do {
            _ = try await broker.submit(text: "123456789", kind: .manual) { _ in "unused" }
            XCTFail("Expected the byte budget to reject the request")
        } catch let error as TranslationWorkBrokerError {
            XCTAssertEqual(error, .textBudgetExceeded(limitBytes: 8))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testQueuedAutomaticWorkIsLatestWins() async throws {
        let broker = TranslationWorkBroker(maximumTextBytes: 1_024)
        let gate = TranslationBrokerTestGate()
        let manual = Task {
            try await broker.submit(text: "manual", kind: .manual) { _ in
                await gate.wait()
                return "manual-result"
            }
        }
        try await waitUntil { await broker.snapshot().active == .manual }

        let oldAutomatic = Task {
            try await broker.submit(text: "old", kind: .automaticResponse) { _ in "old-result" }
        }
        try await waitUntil { await broker.snapshot().queued == 1 }
        let latestAutomatic = Task {
            try await broker.submit(text: "latest", kind: .automaticResponse) { _ in "latest-result" }
        }
        try await waitUntil { await broker.snapshot().queued == 1 }

        do {
            _ = try await oldAutomatic.value
            XCTFail("The replaced automatic request must be cancelled")
        } catch is CancellationError {
            // Expected.
        }

        await gate.releaseAll()
        let manualResult = try await manual.value
        let latestResult = try await latestAutomatic.value
        XCTAssertEqual(manualResult, "manual-result")
        XCTAssertEqual(latestResult, "latest-result")
        let final = await broker.snapshot()
        XCTAssertNil(final.active)
        XCTAssertEqual(final.queued, 0)
        XCTAssertEqual(final.textBytes, 0)
    }

    func testManualWaitingQueueIsBoundedToTwoItems() async throws {
        let broker = TranslationWorkBroker(
            maximumTextBytes: 1_024,
            maximumWaitingManualItems: 2
        )
        let gate = TranslationBrokerTestGate()
        let active = Task {
            try await broker.submit(text: "active", kind: .manual) { _ in
                await gate.wait()
                return "active"
            }
        }
        try await waitUntil { await broker.snapshot().active == .manual }

        let first = Task {
            try await broker.submit(text: "first", kind: .manual) { _ in "first" }
        }
        let second = Task {
            try await broker.submit(text: "second", kind: .manual) { _ in "second" }
        }
        try await waitUntil { await broker.snapshot().queued == 2 }

        do {
            _ = try await broker.submit(text: "third", kind: .manual) { _ in "third" }
            XCTFail("Expected the third waiting manual request to be rejected")
        } catch let error as TranslationWorkBrokerError {
            XCTAssertEqual(error, .manualQueueFull)
        }

        await gate.releaseAll()
        let activeResult = try await active.value
        let firstResult = try await first.value
        let secondResult = try await second.value
        XCTAssertEqual(activeResult, "active")
        XCTAssertEqual(firstResult, "first")
        XCTAssertEqual(secondResult, "second")
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping @Sendable () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !(await condition()) {
            guard clock.now < deadline else {
                XCTFail("Timed out waiting for broker state")
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
