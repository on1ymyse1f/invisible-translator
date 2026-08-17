import XCTest
@testable import ClaudePromptTranslator

final class URLActionRouterTests: XCTestCase {
    private func action(_ rawURL: String) -> URLActionRouter.Action? {
        URLActionRouter.action(for: try! XCTUnwrap(URL(string: rawURL)))
    }

    func testRejectsForeignSchemes() {
        XCTAssertNil(action("https://claude-prompt-translator/show"))
        XCTAssertNil(action("claude-prompt-translator-plus://show"))
    }

    func testHostCommands() {
        XCTAssertEqual(action("claude-prompt-translator://show"), .reveal)
        XCTAssertEqual(action("claude-prompt-translator://input"), .reveal)
        XCTAssertEqual(action("claude-prompt-translator://translate"), .guardedTranslate)
        XCTAssertEqual(
            action("claude-prompt-translator://english"),
            .setLanguageAndReveal(.english)
        )
        XCTAssertEqual(
            action("claude-prompt-translator://japanese"),
            .setLanguageAndReveal(.japanese)
        )
    }

    func testPathCommandsWithoutHost() {
        XCTAssertEqual(action("claude-prompt-translator:///show"), .reveal)
        XCTAssertEqual(action("claude-prompt-translator:///input"), .reveal)
        XCTAssertEqual(action("claude-prompt-translator:///translate"), .guardedTranslate)
    }

    func testUnknownHostsAndPathsAreIgnored() {
        XCTAssertNil(action("claude-prompt-translator://evil.example"))
        XCTAssertNil(action("claude-prompt-translator:///settings/deleteAll"))
        XCTAssertNil(action("claude-prompt-translator://"))
    }

    func testTranslateLinkNeverCarriesPayloadIntoTheAction() {
        // A crafted link cannot smuggle text or options into a translation:
        // query items and fragments never influence the mapped action.
        XCTAssertEqual(
            action("claude-prompt-translator://translate?text=secret&auto=1#frag"),
            .guardedTranslate
        )
        XCTAssertEqual(
            action("claude-prompt-translator://english?theme=neon"),
            .setLanguageAndReveal(.english)
        )
    }
}
