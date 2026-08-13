# Invisible Translator Browser Extension

This is a zero-dependency Manifest V3 companion for the macOS app. It is not a cloud translator and contains no API token, endpoint, analytics SDK, or network request code.

## Status: local native chain implemented; distribution gates remain

This directory now includes an audited front-end boundary, a matching strict
Swift protocol validator, an embedded one-shot native helper, same-UID App IPC,
and explicit install/uninstall scripts. It is still not a public browser
translation release: this repository does not assign, hard-code, or claim a
production/store extension ID, and Developer ID signing/notarization plus real
Chrome installation evidence have not been supplied. Local testing requires
the user to pass the exact 32-character ID shown by Chromium for the extension
loaded on that Mac. The installer validates that value's syntax and the signed
helper, but a local ID is not evidence of a fixed production identity.

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

The service worker sends each message as a one-shot request to
`com.on1ymyse1f.InvisibleTranslator`; it does not keep a native port or helper
resident. The native app must verify the origin and its own per-domain privacy
permission before translating. If the app/host is absent, no cloud fallback is
attempted and the page remains untouched.

## Behaviour

- Site rules must match known ChatGPT, Claude, X, or YouTube message/content containers before a text-node walker can run. If a site changes its structure, auto mode fails closed instead of scanning the broader root. Draft editors, text boxes, forms, controls, navigation, code and translator-owned output are always excluded.
- Auto mode is off until a content script sends a body-free `settingsQuery` and the native host returns an explicit `extensionSettings` message for that exact origin. The worker binds this bootstrap to the sender tab, top frame, document ID and navigation generation; the toolbar action can explicitly refresh it. Page messages can never provide settings. At most 64 segments and 256 KiB UTF-8 are accepted per request and response; oversized source is deferred rather than truncated. Both the content script and worker validate those limits.
- The worker records the sender tab, frame, document ID, URL-origin, kind, and navigation generation for each request. A result is delivered only when its `version`, `requestId`, `origin`, and `kind` match that record. Navigation, TTL expiry, tab closure, an invalid response, or a failed one-shot connection discards pending work.
- Text-node replacement preserves surrounding links and formatting. Bilingual and translation-only display are controlled by native settings.
- Hover translation requires a 520 ms dwell; it does not poll the page.
- YouTube watches only the caption container, merges fragments, applies conservative sentence breaks, and renders a bilingual in-player overlay.

## Test

Requires only a current Node.js runtime:

```sh
node --test BrowserExtension/tests/core.test.js
```

## Native host contract

Every message uses `version: 1`. The native host must reject any other version.
On startup the content script sends only this body-free settings query (the
toolbar action can request the same refresh explicitly):

```json
{"type":"settingsQuery","version":1,"origin":"https://chatgpt.com"}
```

After validating the sender binding, the worker converts it to the
`settingsRequest` message understood by the native helper. Neither message
contains a URL path, title, DOM identifier, selection, draft or page text.

Request from the extension:

```json
{"type":"translationRequest","version":1,"requestId":"...","origin":"https://chatgpt.com","kind":"page","payload":{"kind":"page","items":[{"id":"...","text":"..."}]}}
```

Response from the native app:

```json
{"type":"translationResult","version":1,"requestId":"...","origin":"https://chatgpt.com","kind":"page","items":[{"id":"...","translation":"..."}]}
```

For subtitles, the response uses the same outer fields and may include `source`
and `translation`. Native-only settings are scoped to one origin:

```json
{"type":"extensionSettings","version":1,"origin":"https://chatgpt.com","settings":{"autoMode":true,"hoverMode":false,"hideOriginal":false}}
```

`Sources/ClaudePromptTranslator/BrowserNativeMessagingProtocol.swift` is the
matching validator and framing implementation. The host must use
native-messaging framing, reject non-whitelisted origins and
oversized batches, avoid logging content, and never return content to a
different tab/frame/document. For local testing, Chromium's native-host
manifest must name the exact extension ID explicitly supplied by the user. A
future public release must replace that local binding with its independently
verified store/production ID; no such ID is assigned or claimed here.

The explicit installer is fail-closed:

```sh
Scripts/install-chromium-native-host.sh --extension-id <local-extension-id> --browser chrome
Scripts/uninstall-chromium-native-host.sh chrome
```

It verifies the app and nested helper signatures, writes a user-scoped `0600`
manifest atomically, and grants only the exact extension origin supplied by the
user. The
helper itself exits after one request; the App socket is accepted only from the
same UID and each website remains disabled until the user enables that exact
canonical origin in the App menu. App absence, denial, malformed/oversized
input, local translation failure, and mismatched responses fail closed without
a cloud fallback.
