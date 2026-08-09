import AppKit
import ApplicationServices

struct ClaudeContextDetector {
    private static let excludedBundleIdentifiers: Set<String> = [
        "com.openai.codex"
    ]

    static func isExcludedAIApp(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return excludedBundleIdentifiers.contains(bundleIdentifier.lowercased())
    }

    private let browserBundleIdentifiers: Set<String> = [
        "com.apple.Safari",
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "company.thebrowser.Browser",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "org.mozilla.firefox"
    ]

    func isClaudeContext(_ app: NSRunningApplication) -> Bool {
        let name = app.localizedName?.lowercased() ?? ""
        let bundleIdentifier = app.bundleIdentifier?.lowercased() ?? ""

        guard !Self.isExcludedAIApp(bundleIdentifier: bundleIdentifier) else {
            return false
        }

        if name.contains("claude") || bundleIdentifier.contains("claude") || bundleIdentifier.contains("anthropic") {
            return true
        }

        guard isSupportedBrowser(name: name, bundleIdentifier: bundleIdentifier) else {
            return false
        }

        guard AccessibilityPermission.isTrusted else {
            return false
        }

        return frontmostWindowTitle(for: app)?.lowercased().contains("claude") == true
    }

    func isAIContext(_ app: NSRunningApplication) -> Bool {
        let name = app.localizedName?.lowercased() ?? ""
        let bundleIdentifier = app.bundleIdentifier?.lowercased() ?? ""
        guard !Self.isExcludedAIApp(bundleIdentifier: bundleIdentifier) else {
            return false
        }
        let appIdentity = "\(name) \(bundleIdentifier)"

        if containsAIKeyword(appIdentity) {
            return true
        }

        guard isSupportedBrowser(name: name, bundleIdentifier: bundleIdentifier) else {
            return false
        }

        guard AccessibilityPermission.isTrusted else {
            return false
        }

        return frontmostWindowTitle(for: app).map { containsAIKeyword($0.lowercased()) } ?? false
    }

    private func isSupportedBrowser(name: String, bundleIdentifier: String) -> Bool {
        if browserBundleIdentifiers.contains(bundleIdentifier) {
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

    private func containsAIKeyword(_ text: String) -> Bool {
        [
            "claude",
            "anthropic",
            "chatgpt",
            "openai",
            "gemini",
            "perplexity",
            "copilot",
            "poe",
            "grok",
            "deepseek",
            "kimi",
            "doubao",
            "豆包",
            "通义",
            "千问"
        ].contains { text.contains($0) }
    }

    private func frontmostWindowTitle(for app: NSRunningApplication) -> String? {
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

        var titleReference: CFTypeRef?
        let titleResult = AXUIElementCopyAttributeValue(
            windowElement,
            kAXTitleAttribute as CFString,
            &titleReference
        )

        guard titleResult == .success else {
            return nil
        }

        return titleReference as? String
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
