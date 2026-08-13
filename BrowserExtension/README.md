# Invisible Translator Browser Extension

This is a zero-dependency Manifest V3 companion for the macOS app. It is not a cloud translator and contains no API token, endpoint, analytics SDK, or network request code.

## Scope and install

`chromium/` is the canonical reusable WebExtension source. Load that directory as an unpacked extension in Chrome/Chromium for development. It can only run on these HTTPS hosts:

- `chatgpt.com`, `chat.openai.com`, `claude.ai`
- `x.com`, `twitter.com`
- `youtube.com`, `www.youtube.com`

Every other host has no content script, no observer, and no runtime work.

For Safari, convert the same directory in Xcode; see [safari/README.md](safari/README.md). Do not hand-copy source files into a second implementation.

## Translation path

```
page content root -> capped local batch -> extension service worker -> native messaging host -> macOS app
                                                                                  -> response -> page
```

The service worker only relays messages to `com.on1ymyse1f.InvisibleTranslator`. The native app must verify the origin and its own per-app/per-domain privacy permission before translating. If the app/host is absent, no cloud fallback is attempted and the page remains untouched.

## Behaviour

- Site rules select known ChatGPT, Claude, X, and YouTube containers first; a text-node walker is used only inside that content root as a fallback.
- Auto mode is off until the native app sends an explicit `extensionSettings` message. At most 64 segments and 256 KiB UTF-8 are sent in one request; oversized source is deferred rather than truncated.
- Text-node replacement preserves surrounding links and formatting. Bilingual and translation-only display are controlled by native settings.
- Hover translation requires a 520 ms dwell; it does not poll the page.
- YouTube watches only the caption container, merges fragments, applies conservative sentence breaks, and renders a bilingual in-player overlay.

## Test

Requires only a current Node.js runtime:

```sh
node --test BrowserExtension/tests/core.test.js
```

## Native host contract

Request from the extension:

```json
{"type":"translationRequest","requestId":"...","origin":"https://chatgpt.com","payload":{"kind":"page|hover|subtitle","items":[{"id":"...","text":"..."}]}}
```

Response from the native app:

```json
{"requestId":"...","kind":"page|hover|subtitle","items":[{"id":"...","translation":"..."}]}
```

For subtitles, the response may additionally include `source` and `translation`. The native host must use native-messaging framing, reject non-whitelisted origins, avoid logging content, and never return content to a different tab.
