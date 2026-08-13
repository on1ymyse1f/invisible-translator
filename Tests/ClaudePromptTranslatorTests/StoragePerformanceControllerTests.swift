import Foundation
import XCTest
@testable import ClaudePromptTranslator

final class StoragePerformanceControllerTests: XCTestCase {
    func testSnapshotCountsOnlyConfiguredAppOwnedLocations() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StoragePerformanceTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let app = root.appendingPathComponent("Translator.app", isDirectory: true)
        let cache = root.appendingPathComponent("Caches/ClaudePromptTranslator", isDirectory: true)
        let models = root.appendingPathComponent("Application Support/ClaudePromptTranslator/ASRModels", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 11).write(to: app.appendingPathComponent("binary"))
        try Data(repeating: 2, count: 17).write(to: cache.appendingPathComponent("translation-cache"))
        try Data(repeating: 3, count: 23).write(to: models.appendingPathComponent("model.cptasr"))

        let inspector = StoragePerformanceInspector(
            locations: StoragePerformanceLocations(
                appBundleURL: app,
                cacheDirectoryURL: cache,
                asrModelsDirectoryURL: models
            )
        )
        let snapshot = inspector.snapshot()
        XCTAssertEqual(snapshot.appByteCount, 11)
        XCTAssertEqual(snapshot.cacheByteCount, 17)
        XCTAssertEqual(snapshot.asrModelByteCount, 23)
    }

    func testRejectsDirectoryOutsideExpectedASRModelsLocationBeforeMutating() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StoragePerformanceTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let unrelated = root.appendingPathComponent("not-owned", isDirectory: true)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        let inspector = StoragePerformanceInspector(
            locations: StoragePerformanceLocations(
                appBundleURL: root.appendingPathComponent("Translator.app"),
                cacheDirectoryURL: root.appendingPathComponent("Caches"),
                asrModelsDirectoryURL: unrelated
            )
        )

        XCTAssertThrowsError(try inspector.moveASRModelsToTrash()) { error in
            XCTAssertEqual(error as? StoragePerformanceError, .unsafeModelDirectory)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }
}
