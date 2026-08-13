import AppKit
import ApplicationServices

enum AIWebURLScanPolicy {
    static let interval: TimeInterval = 3

    static func shouldReuse(
        cachedProcessIdentifier: pid_t,
        currentProcessIdentifier: pid_t,
        cachedWindowIdentity: CFHashCode,
        currentWindowIdentity: CFHashCode,
        expiresAt: Date,
        now: Date
    ) -> Bool {
        cachedProcessIdentifier == currentProcessIdentifier
            && cachedWindowIdentity == currentWindowIdentity
            && now < expiresAt
    }
}

final class ClaudeContextDetector {
    private static let excludedBundleIdentifiers: Set<String> = [
        "com.openai.codex"
    ]

    static func isExcludedAIApp(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return excludedBundleIdentifiers.contains(bundleIdentifier.lowercased())
    }

    private static let browserBundleIdentifiers: Set<String> = [
        "com.apple.safari",
        "com.google.chrome",
        "com.google.chrome.canary",
        "company.thebrowser.browser",
        "com.microsoft.edgemac",
        "com.brave.browser",
        "com.openai.atlas",
        "org.mozilla.firefox"
    ]

    private static let knownDesktopAIBundleIdentifiers: Set<String> = [
        "ai.perplexity.mac",
        "com.anthropic.claudefordesktop",
        "com.google.gemini",
        "com.microsoft.copilot",
        "com.openai.chat",
        "local.codex.chatgptsyntheticharness"
    ]

    private static let knownWebBackedDesktopAIBundleIdentifiers: Set<String> = [
        "ai.perplexity.mac",
        "com.anthropic.claudefordesktop",
        "com.google.gemini",
        "com.microsoft.copilot",
        "com.openai.chat"
    ]

    private static let knownDesktopAIApplicationNames: Set<String> = [
        "chatgpt", "claude", "gemini", "perplexity", "microsoft copilot",
        "poe", "grok", "deepseek", "kimi", "豆包", "通义千问"
    ]

    private static let knownAIWebHosts: Set<String> = [
        "chat.openai.com",
        "chatgpt.com",
        "claude.ai",
        "gemini.google.com",
        "perplexity.ai",
        "copilot.microsoft.com",
        "poe.com",
        "grok.com",
        "chat.deepseek.com",
        "kimi.com",
        "kimi.moonshot.cn",
        "doubao.com",
        "tongyi.aliyun.com",
        "qianwen.com"
    ]

    private struct CachedFrontmostWebURL {
        let processIdentifier: pid_t
        let windowIdentity: CFHashCode
        let windowElement: AXUIElement
        let expiresAt: Date
        let url: URL?
    }

    private var cachedFrontmostWebURL: CachedFrontmostWebURL?

    func isClaudeContext(_ app: NSRunningApplication) -> Bool {
        let name = app.localizedName?.lowercased() ?? ""
        let bundleIdentifier = app.bundleIdentifier?.lowercased() ?? ""

        guard !Self.isExcludedAIApp(bundleIdentifier: bundleIdentifier) else {
            return false
        }

        if bundleIdentifier == "com.anthropic.claudefordesktop" || name == "claude" {
            return true
        }

        guard Self.isSupportedBrowserIdentity(name: name, bundleIdentifier: bundleIdentifier) else {
            return false
        }

        guard AccessibilityPermission.isTrusted else {
            return false
        }

        return frontmostWebURL(for: app)?.host?.lowercased() == "claude.ai"
    }

    func isAIContext(_ app: NSRunningApplication) -> Bool {
        let name = app.localizedName?.lowercased() ?? ""
        let bundleIdentifier = app.bundleIdentifier?.lowercased() ?? ""
        guard !Self.isExcludedAIApp(bundleIdentifier: bundleIdentifier) else {
            return false
        }
        if Self.isKnownDesktopAIIdentity(name: name, bundleIdentifier: bundleIdentifier) {
            return true
        }

        guard Self.isSupportedBrowserIdentity(name: name, bundleIdentifier: bundleIdentifier) else {
            return false
        }

        guard AccessibilityPermission.isTrusted else {
            return false
        }

        guard let url = frontmostWebURL(for: app) else {
            // Browser window titles are untrusted content. A normal page can
            // contain “ChatGPT”, “OpenAI” or “Grok” in its title, so automatic
            // input/reply scanning fails closed unless AX exposes a known host.
            return false
        }
        return Self.isKnownAIWebURL(url)
    }

    static func isKnownDesktopAIIdentity(name: String, bundleIdentifier: String) -> Bool {
        knownDesktopAIBundleIdentifiers.contains(bundleIdentifier.lowercased())
            || knownDesktopAIApplicationNames.contains(name.lowercased())
    }

    static func isKnownAIWebURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        if knownAIWebHosts.contains(host) {
            return true
        }
        if knownAIWebHosts.contains(where: { host.hasSuffix(".\($0)") }) {
            return true
        }
        if host == "x.com" || host == "www.x.com" {
            let path = url.path.lowercased()
            return path == "/i/grok" || path.hasPrefix("/i/grok/")
        }
        return false
    }

    static func isSupportedBrowserIdentity(name: String, bundleIdentifier: String) -> Bool {
        if browserBundleIdentifiers.contains(bundleIdentifier.lowercased()) {
            return true
        }

        return [
            "safari",
            "chrome",
            "arc",
            "edge",
            "brave",
            "firefox"
        ].contains { name.contains($0) }
    }

    func requiresCompatibilityPolling(_ app: NSRunningApplication) -> Bool {
        Self.requiresCompatibilityPolling(
            name: app.localizedName ?? "",
            bundleIdentifier: app.bundleIdentifier ?? ""
        )
    }

    static func requiresCompatibilityPolling(
        name: String,
        bundleIdentifier: String
    ) -> Bool {
        let normalizedName = name.lowercased()
        let normalizedBundleIdentifier = bundleIdentifier.lowercased()
        if isSupportedBrowserIdentity(
            name: normalizedName,
            bundleIdentifier: normalizedBundleIdentifier
        ) {
            return true
        }
        if knownWebBackedDesktopAIBundleIdentifiers.contains(normalizedBundleIdentifier) {
            return true
        }
        // Name-only desktop identities have no stable implementation contract;
        // retain compatibility polling until a concrete native bundle is known.
        return normalizedBundleIdentifier.isEmpty
            && knownDesktopAIApplicationNames.contains(normalizedName)
    }

    private func frontmostWebURL(for app: NSRunningApplication) -> URL? {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)

        var windowReference: CFTypeRef?
        var result = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &windowReference
        )

        if result != .success || windowReference == nil {
            result = AXUIElementCopyAttributeValue(
                appElement,
                kAXMainWindowAttribute as CFString,
                &windowReference
            )
        }

        guard result == .success, let windowRef = windowReference,
              CFGetTypeID(windowRef) == AXUIElementGetTypeID() else {
            return nil
        }
        let windowElement = windowRef as! AXUIElement
        let windowIdentity = CFHash(windowElement)
        let now = Date()
        if let cachedFrontmostWebURL,
           AIWebURLScanPolicy.shouldReuse(
            cachedProcessIdentifier: cachedFrontmostWebURL.processIdentifier,
            currentProcessIdentifier: app.processIdentifier,
            cachedWindowIdentity: cachedFrontmostWebURL.windowIdentity,
            currentWindowIdentity: windowIdentity,
            expiresAt: cachedFrontmostWebURL.expiresAt,
            now: now
           ),
           CFEqual(cachedFrontmostWebURL.windowElement, windowElement) {
            return cachedFrontmostWebURL.url
        }

        var queue: [(AXUIElement, Int)] = [(windowElement, 0)]
        var visited = 0
        while !queue.isEmpty, visited < 500 {
            let (element, depth) = queue.removeFirst()
            visited += 1
            if stringAttribute(kAXRoleAttribute, from: element) == "AXWebArea",
               let url = urlAttribute(kAXURLAttribute, from: element) {
                cachedFrontmostWebURL = CachedFrontmostWebURL(
                    processIdentifier: app.processIdentifier,
                    windowIdentity: windowIdentity,
                    windowElement: windowElement,
                    expiresAt: now.addingTimeInterval(AIWebURLScanPolicy.interval),
                    url: url
                )
                return url
            }
            guard depth < 12 else { continue }
            queue.append(contentsOf: childrenAttribute(element).map { ($0, depth + 1) })
        }
        cachedFrontmostWebURL = CachedFrontmostWebURL(
            processIdentifier: app.processIdentifier,
            windowIdentity: windowIdentity,
            windowElement: windowElement,
            expiresAt: now.addingTimeInterval(AIWebURLScanPolicy.interval),
            url: nil
        )
        return nil
    }

    private func urlAttribute(_ attribute: String, from element: AXUIElement) -> URL? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value else { return nil }
        if let url = value as? URL { return url }
        if let string = value as? String { return URL(string: string) }
        return nil
    }

    private func stringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private func childrenAttribute(_ element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &value
        ) == .success,
              let children = value as? [AXUIElement] else {
            return []
        }
        return children
    }
}

enum AccessibilityPermission {
    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    static func requestIfNeeded(prompt: Bool) -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}

enum ScreenRecordingPermission {
    static var isGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    static func requestIfNeeded() -> Bool {
        if isGranted {
            return true
        }
        return CGRequestScreenCaptureAccess() && isGranted
    }

    static func openSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        ) else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
