# Browser extension privacy boundary

- The extension is injected only by the manifest's six supported site families. It has no `<all_urls>` permission and no optional host permission.
- It performs no `fetch`, `XMLHttpRequest`, WebSocket, telemetry, crash reporting, or analytics. It stores no API key and declares no remote code.
- The page text sent for an explicitly enabled translation is limited to 64 segments / 256 KiB per request and travels only through browser native messaging to the local macOS app.
- Automatic page/subtitle translation is disabled by default. The macOS app must explicitly send settings after the user enables a supported domain.
- Mutation observers are attached only to a supported site's selected content/caption container, never `document` or `body`. Hover translation uses a dwell timer and does not capture screenshots, clipboard data, keystrokes, URLs outside the active supported site, or browser history.
- The native app is the policy enforcement point: it must verify sender origin, apply its App/domain privacy allow-list, manage any explicitly selected cloud provider, and redact all content from diagnostics.
- Removing the extension stops all browser-side processing. The extension owns no model, cache, or user data outside normal browser extension storage for future non-content settings.
