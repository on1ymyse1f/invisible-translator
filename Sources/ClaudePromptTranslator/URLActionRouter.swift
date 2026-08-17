import Foundation

/// Pure mapping from an incoming `claude-prompt-translator://` URL to a
/// single canonical action. Both the direct handler and the existing-
/// instance forwarder consume this mapping, so the allow-list lives in
/// exactly one place.
///
/// Security intent: URLs can only reveal the edge bar or switch the target
/// language. A `translate` command never triggers translation on its own —
/// it only reveals the bar with a guard message. Query items, fragments and
/// credentials in the URL are ignored by construction, and unknown hosts or
/// paths map to `nil` so the caller does nothing.
enum URLActionRouter {
    enum Action: Equatable, Sendable {
        /// Open the edge bar without further side effects.
        case reveal
        /// Never auto-translate from a link: show a guard message, then reveal.
        case guardedTranslate
        /// Switch target language, then reveal.
        case setLanguageAndReveal(TargetLanguage)
    }

    static func action(for url: URL) -> Action? {
        guard url.scheme == "claude-prompt-translator" else {
            return nil
        }

        switch url.host {
        case "translate":
            return .guardedTranslate
        case "show", "input":
            return .reveal
        case "english":
            return .setLanguageAndReveal(.english)
        case "japanese":
            return .setLanguageAndReveal(.japanese)
        default:
            break
        }

        switch url.path {
        case "/show", "/input":
            return .reveal
        case "/translate":
            return .guardedTranslate
        default:
            return nil
        }
    }
}
