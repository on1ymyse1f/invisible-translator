import Foundation
import XCTest
#if canImport(BrowserNativeBridgeShared)
import BrowserNativeBridgeShared
#endif
@testable import ClaudePromptTranslator

@MainActor
final class BrowserNativeBridgeTests: XCTestCase {
    func testDomainAuthorizationDefaultsEmptyAndDropsUnknownOrigins() {
        let suite = "BrowserNativeBridgeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(BrowserNativeDomainAuthorizationStore.load(from: defaults).isEmpty)

        defaults.set(
            ["https://claude.ai", "https://untrusted.example"],
            forKey: BrowserNativeDomainAuthorizationStore.defaultsKey
        )
        XCTAssertEqual(
            BrowserNativeDomainAuthorizationStore.load(from: defaults),
            ["https://claude.ai"]
        )
    }

    func testSettingsRemainDisabledWithoutExplicitPerOriginAuthorization() async throws {
        let handler = makeHandler(settings: .init(
            autoMode: false,
            hoverMode: false,
            hideOriginal: false
        ))
        let request = try nativeFrame([
            "type": "settingsRequest",
            "version": 1,
            "origin": "https://claude.ai"
        ])

        let response = try responseObject(await handler.responseFrame(for: request))
        XCTAssertEqual(response["type"] as? String, "extensionSettings")
        XCTAssertEqual(response["origin"] as? String, "https://claude.ai")
        XCTAssertEqual(response["settings"] as? NSDictionary, [
            "autoMode": false,
            "hoverMode": false,
            "hideOriginal": false
        ] as NSDictionary)
    }

    func testTranslationIsRejectedBeforeTranslatorWhenModeIsUnauthorized() async throws {
        var translationWasCalled = false
        let handler = BrowserNativeRequestHandler(
            settingsProvider: { _ in .init(autoMode: false, hoverMode: false, hideOriginal: false) },
            targetResolver: { _ in .simplifiedChinese },
            translator: { _, _, _ in
                translationWasCalled = true
                return "不应调用"
            }
        )
        let request = try translationRequestFrame(
            origin: "https://chatgpt.com",
            kind: "page",
            text: "private source"
        )

        let response = try responseObject(await handler.responseFrame(for: request))
        XCTAssertEqual(response as NSDictionary, [
            "type": "nativeError",
            "version": 1,
            "code": "notAuthorized"
        ] as NSDictionary)
        XCTAssertFalse(translationWasCalled)
    }

    func testUnknownOriginIsRejectedBeforeSettingsOrTranslation() async throws {
        var settingsWasRead = false
        let handler = BrowserNativeRequestHandler(
            settingsProvider: { _ in
                settingsWasRead = true
                return .init(autoMode: true, hoverMode: true, hideOriginal: false)
            },
            targetResolver: { _ in .simplifiedChinese },
            translator: { _, _, _ in "不应调用" }
        )
        let request = try nativeFrame([
            "type": "settingsRequest",
            "version": 1,
            "origin": "https://untrusted.example"
        ])

        let response = try responseObject(await handler.responseFrame(for: request))
        XCTAssertEqual(response["code"] as? String, "notAuthorized")
        XCTAssertFalse(settingsWasRead)
    }

    func testAuthorizedTranslationUsesBoundLocalHandler() async throws {
        var observedTarget: TargetLanguage?
        var observedWorkKind: TranslationWorkKind?
        let handler = BrowserNativeRequestHandler(
            settingsProvider: { _ in .init(autoMode: true, hoverMode: false, hideOriginal: true) },
            targetResolver: { _ in .simplifiedChinese },
            translator: { text, target, workKind in
                XCTAssertEqual(text, "Hello")
                observedTarget = target
                observedWorkKind = workKind
                return "你好"
            }
        )
        let request = try translationRequestFrame(
            origin: "https://chatgpt.com",
            kind: "page",
            text: "Hello"
        )

        let responseFrame = await handler.responseFrame(for: request)
        try BrowserNativeSocketTransport.validateResponse(
            responseFrame,
            for: BrowserNativeSocketTransport.requestBinding(from: request)
        )
        let response = try responseObject(responseFrame)
        XCTAssertEqual(response["requestId"] as? String, "request-1")
        XCTAssertEqual(response["origin"] as? String, "https://chatgpt.com")
        XCTAssertEqual(observedTarget, .simplifiedChinese)
        XCTAssertEqual(observedWorkKind, .automaticSelection)
        XCTAssertEqual(response["items"] as? NSArray, [
            ["id": "item-1", "translation": "你好"]
        ] as NSArray)
    }

    func testServerAndClientExchangeOneSameUIDFramedRequest() throws {
        let directory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
            .appendingPathComponent("ClaudePromptTranslator", isDirectory: true)
            .appendingPathComponent("BNT-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let socketURL = directory.appendingPathComponent("bridge.sock")
        let server = BrowserNativeBridgeServer(socketURL: socketURL) { frame in
            do {
                let binding = try BrowserNativeSocketTransport.requestBinding(from: frame)
                return try BrowserNativeMessagingProtocol.encodeNativeFrame(jsonObject: [
                    "type": "extensionSettings",
                    "version": 1,
                    "origin": binding.origin,
                    "settings": ["autoMode": false, "hoverMode": false, "hideOriginal": false]
                ])
            } catch {
                return BrowserNativeSocketTransport.nativeErrorFrame(code: "invalidRequest")
            }
        }
        try server.start()
        defer { server.stop() }
        XCTAssertTrue(BrowserNativeSocketTransport.secureSocketNode(at: socketURL, owner: geteuid()))
        let request = try nativeFrame([
            "type": "settingsRequest",
            "version": 1,
            "origin": "https://x.com"
        ])

        let response = try BrowserNativeSocketTransport.exchange(
            requestFrame: request,
            socketURL: socketURL
        )
        try BrowserNativeSocketTransport.validateResponse(
            response,
            for: BrowserNativeSocketTransport.requestBinding(from: request)
        )
        XCTAssertEqual(try responseObject(response)["origin"] as? String, "https://x.com")
    }

    func testNativeHostExecutableRoundTripsThroughAppSocketAndExits() throws {
        let directory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
            .appendingPathComponent("ClaudePromptTranslator", isDirectory: true)
            .appendingPathComponent("BNT-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let socketURL = directory.appendingPathComponent("bridge.sock")
        let server = BrowserNativeBridgeServer(socketURL: socketURL) { frame in
            do {
                let binding = try BrowserNativeSocketTransport.requestBinding(from: frame)
                return try BrowserNativeMessagingProtocol.encodeNativeFrame(jsonObject: [
                    "type": "extensionSettings",
                    "version": 1,
                    "origin": binding.origin,
                    "settings": ["autoMode": false, "hoverMode": false, "hideOriginal": false]
                ])
            } catch {
                return BrowserNativeSocketTransport.nativeErrorFrame(code: "invalidRequest")
            }
        }
        try server.start()
        defer { server.stop() }

        let testBundleURL = Bundle(for: Self.self).bundleURL
        let executableCandidates = [
            // SwiftPM places the helper beside the package test bundle.
            testBundleURL
                .deletingLastPathComponent()
                .appendingPathComponent("ClaudePromptTranslatorNativeHost"),
            // Xcode hosts the tests in Contents/PlugIns and embeds the helper
            // beside the main executable in Contents/MacOS.
            testBundleURL
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("MacOS/ClaudePromptTranslatorNativeHost")
        ]
        guard let executable = executableCandidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }) else {
            XCTFail("Native host executable is missing from both supported test layouts")
            return
        }
        let input = Pipe()
        let output = Pipe()
        let process = Process()
        process.executableURL = executable
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment["CPT_TEST_BROWSER_NATIVE_SOCKET"] = socketURL.path
        process.environment = environment

        let request = try nativeFrame([
            "type": "settingsRequest",
            "version": 1,
            "origin": "https://claude.ai"
        ])
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: request)
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        let response = try output.fileHandleForReading.readToEnd() ?? Data()

        XCTAssertEqual(process.terminationStatus, 0)
        try BrowserNativeSocketTransport.validateResponse(
            response,
            for: BrowserNativeSocketTransport.requestBinding(from: request)
        )
        XCTAssertEqual(
            try responseObject(response)["origin"] as? String,
            "https://claude.ai"
        )
    }

    func testServerRejectsOccupiedNonSocketPath() throws {
        let directory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
            .appendingPathComponent("ClaudePromptTranslator", isDirectory: true)
            .appendingPathComponent("BNT-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let occupiedURL = directory.appendingPathComponent("bridge.sock")
        XCTAssertTrue(FileManager.default.createFile(atPath: occupiedURL.path, contents: Data()))
        let server = BrowserNativeBridgeServer(socketURL: occupiedURL) { _ in Data() }
        XCTAssertThrowsError(try server.start()) { error in
            XCTAssertEqual(error as? BrowserNativeBridgeServerError, .occupiedSocket)
        }
    }

    func testResponseValidatorRejectsCrossOriginReply() throws {
        let request = try translationRequestFrame(
            origin: "https://claude.ai",
            kind: "hover",
            text: "Hello"
        )
        let wrongOrigin = try nativeFrame([
            "type": "translationResult",
            "version": 1,
            "requestId": "request-1",
            "origin": "https://chatgpt.com",
            "kind": "hover",
            "items": [["id": "item-1", "translation": "你好"]]
        ])
        XCTAssertThrowsError(
            try BrowserNativeSocketTransport.validateResponse(
                wrongOrigin,
                for: BrowserNativeSocketTransport.requestBinding(from: request)
            )
        )
    }

    private func makeHandler(settings: BrowserNativeBridgeSettings) -> BrowserNativeRequestHandler {
        BrowserNativeRequestHandler(
            settingsProvider: { _ in settings },
            targetResolver: { _ in .simplifiedChinese },
            translator: { _, _, _ in
                XCTFail("Translator should not be called.")
                return ""
            }
        )
    }

    private func translationRequestFrame(origin: String, kind: String, text: String) throws -> Data {
        try nativeFrame([
            "type": "translationRequest",
            "version": 1,
            "requestId": "request-1",
            "origin": origin,
            "kind": kind,
            "payload": [
                "kind": kind,
                "items": [["id": "item-1", "text": text]]
            ]
        ])
    }

    private func nativeFrame(_ object: [String: Any]) throws -> Data {
        try BrowserNativeMessagingProtocol.encodeNativeFrame(jsonObject: object)
    }

    private func responseObject(_ frame: Data) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: BrowserNativeSocketTransport.payload(from: frame)
            ) as? [String: Any]
        )
    }
}
