import Foundation
import XCTest
@testable import ClaudePromptTranslator

final class BrowserNativeMessagingProtocolTests: XCTestCase {
    func testAcceptsStrictTranslationRequest() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "type": "translationRequest",
            "version": 1,
            "requestId": "request-1",
            "origin": "https://chatgpt.com",
            "kind": "page",
            "payload": [
                "kind": "page",
                "items": [["id": "node-1", "text": "Hello"]]
            ]
        ])

        let message = try BrowserNativeMessagingProtocol.decodeIncomingFrame(data)
        XCTAssertEqual(
            message,
            .translation(
                .init(
                    requestID: "request-1",
                    origin: "https://chatgpt.com",
                    kind: .page,
                    items: [.init(id: "node-1", text: "Hello")]
                )
            )
        )
    }

    func testRejectsOriginVariantsAndUnknownSites() throws {
        for origin in [
            "https://chatgpt.com/",
            "https://chatgpt.com:443",
            "https://user@chatgpt.com",
            "https://sub.chatgpt.com",
            "http://chatgpt.com"
        ] {
            let data = try JSONSerialization.data(withJSONObject: [
                "type": "settingsRequest",
                "version": 1,
                "origin": origin
            ])
            XCTAssertThrowsError(
                try BrowserNativeMessagingProtocol.decodeIncomingFrame(data),
                "Expected rejection for \(origin)"
            )
        }
    }

    func testRejectsFieldsOutsideTheProtocolSchema() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "type": "settingsRequest",
            "version": 1,
            "origin": "https://chatgpt.com",
            "text": "must not be accepted in a settings query"
        ])
        XCTAssertThrowsError(try BrowserNativeMessagingProtocol.decodeIncomingFrame(data))
    }

    func testRejectsOversizedFramesAndBatches() throws {
        XCTAssertThrowsError(
            try BrowserNativeMessagingProtocol.decodeIncomingFrame(
                Data(repeating: 0, count: BrowserNativeMessagingProtocol.maximumFrameBytes + 1)
            )
        )

        let items = (0...BrowserNativeMessagingProtocol.maximumItems).map {
            ["id": "\($0)", "text": "text"]
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "type": "translationRequest",
            "version": 1,
            "requestId": "request-1",
            "origin": "https://claude.ai",
            "kind": "hover",
            "payload": ["kind": "hover", "items": items]
        ])
        XCTAssertThrowsError(try BrowserNativeMessagingProtocol.decodeIncomingFrame(data))
    }

    func testNativeFrameUsesLittleEndianLengthAndRoundTrips() throws {
        let object: [String: Any] = [
            "type": "extensionSettings",
            "version": 1,
            "origin": "https://x.com",
            "settings": ["autoMode": false]
        ]
        let frame = try BrowserNativeMessagingProtocol.encodeNativeFrame(jsonObject: object)
        let payload = try BrowserNativeMessagingProtocol.splitNativeFrame(frame)
        let decoded = try XCTUnwrap(
            JSONSerialization.jsonObject(with: payload) as? [String: Any]
        )
        XCTAssertEqual(decoded["origin"] as? String, "https://x.com")
    }

    func testResponseMustMatchRequestItemOrderAndFitBudget() throws {
        let request = BrowserNativeMessagingProtocol.TranslationRequest(
            requestID: "request-1",
            origin: "https://youtube.com",
            kind: .page,
            items: [.init(id: "one", text: "Hello")]
        )
        XCTAssertThrowsError(
            try BrowserNativeMessagingProtocol.translationResult(
                for: request,
                translations: [(id: "different", translation: "你好")]
            )
        )

        let response = try BrowserNativeMessagingProtocol.translationResult(
            for: request,
            translations: [(id: "one", translation: "你好")]
        )
        XCTAssertEqual(response["requestId"] as? String, "request-1")
    }

    func testSubtitleResponseUsesCaptionShape() throws {
        let request = BrowserNativeMessagingProtocol.TranslationRequest(
            requestID: "subtitle-1",
            origin: "https://www.youtube.com",
            kind: .subtitle,
            items: [.init(id: "cue", text: "Hello")]
        )
        let response = try BrowserNativeMessagingProtocol.translationResult(
            for: request,
            translations: [(id: "cue", translation: "你好")]
        )
        XCTAssertEqual(response["source"] as? String, "Hello")
        XCTAssertEqual(response["translation"] as? String, "你好")
        XCTAssertNil(response["items"])
    }

    func testNativeErrorContainsOnlyContentFreeAllowlistedFields() throws {
        let error = BrowserNativeMessagingProtocol.nativeError(code: "notAuthorized")
        XCTAssertEqual(error as NSDictionary, [
            "type": "nativeError",
            "version": 1,
            "code": "notAuthorized"
        ] as NSDictionary)
        XCTAssertNoThrow(
            try BrowserNativeMessagingProtocol.encodeNativeFrame(jsonObject: error)
        )
    }
}
