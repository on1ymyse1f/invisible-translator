import AppKit
import ApplicationServices

enum InputReplacementScope: Equatable {
    case insertAtCursor
    /// `expectedValue` is the exact, untrimmed Accessibility value captured
    /// before translation. It is a compare-and-swap guard, not the text sent
    /// to the translator.
    case all(expectedValue: String?)
    case selection(range: NSRange?, expectedText: String)
}

struct InputTranslationSource: Equatable {
    let text: String
    let replacementScope: InputReplacementScope

    var usesSelection: Bool {
        if case .selection = replacementScope {
            return true
        }
        return false
    }
}

struct InputWindowIdentity: Equatable {
    let processIdentifier: pid_t
    let accessibilityElementHash: Int?
    let fallbackWindowID: CGWindowID?
}

@MainActor
final class InputTarget {
    let app: NSRunningApplication
    let appName: String
    private let inferAIInputArea: Bool
    private let focusedElement: AXUIElement?
    private let anchorWindowElement: AXUIElement?
    private let fallbackAnchorRatio: CGRect?
    let windowIdentity: InputWindowIdentity?

    init(
        app: NSRunningApplication,
        focusedElement: AXUIElement? = nil,
        inferAIInputArea: Bool = false,
        anchorWindowElement: AXUIElement? = nil,
        fallbackAnchorRatio: CGRect? = nil,
        windowIdentity: InputWindowIdentity? = nil
    ) {
        self.app = app
        self.appName = app.localizedName ?? "target app"
        self.focusedElement = focusedElement
        self.inferAIInputArea = inferAIInputArea
        self.anchorWindowElement = anchorWindowElement
        self.fallbackAnchorRatio = fallbackAnchorRatio
        self.windowIdentity = windowIdentity
            ?? Self.windowIdentity(for: app, windowElement: anchorWindowElement)
    }

    static func capture(from app: NSRunningApplication?, inferAIInputArea: Bool = false) -> InputTarget? {
        guard let app else {
            return nil
        }

        let focusedElement = focusedElement(for: app)
        let targetElement = textInputElement(near: focusedElement, in: app) ?? focusedElement
        let anchorWindowElement = windowElement(for: app)
        return InputTarget(
            app: app,
            focusedElement: targetElement,
            inferAIInputArea: inferAIInputArea,
            anchorWindowElement: anchorWindowElement,
            fallbackAnchorRatio: inferAIInputArea ? fallbackAnchorRatio(for: app, windowElement: anchorWindowElement) : nil
        )
    }

    static func captureTextTarget(from app: NSRunningApplication?) -> InputTarget? {
        guard let app else {
            return nil
        }

        if let focusedTarget = captureFocusedTextTarget(from: app) {
            return focusedTarget
        }

        let anchorWindowElement = windowElement(for: app)
        guard let textInput = bestTextInputElement(in: app, windowElement: anchorWindowElement) else {
            return nil
        }

        return InputTarget(
            app: app,
            focusedElement: textInput,
            anchorWindowElement: anchorWindowElement
        )
    }

    /// Fast O(1) path used while the user is actively typing. It avoids walking
    /// the entire Accessibility tree and only accepts the real focused composer.
    static func captureFocusedTextTarget(from app: NSRunningApplication?) -> InputTarget? {
        guard let app else {
            return nil
        }

        let anchorWindowElement = windowElement(for: app)
        let windowRect = anchorWindowElement.flatMap { rect(for: $0) }
            ?? frontmostWindowRect(for: app)
        guard let focusedElement = focusedElement(for: app),
              isTextInput(focusedElement),
              isLikelyChatInputElement(
                focusedElement,
                in: app,
                knownWindowRect: windowRect
              ) else {
            return nil
        }

        return InputTarget(
            app: app,
            focusedElement: focusedElement,
            anchorWindowElement: anchorWindowElement
        )
    }

    var anchorRect: NSRect? {
        if inferAIInputArea,
           let fallbackAnchorRatio,
           let windowRect = anchorWindowRect() {
            return Self.rect(from: fallbackAnchorRatio, in: windowRect)
        }

        if let focusedElement,
           Self.isTextInput(focusedElement),
           let rect = Self.rect(for: focusedElement),
           rect.isUsableTextInputAnchor {
            return rect
        }

        if let textInput = Self.bestTextInputElement(in: app),
           let rect = Self.rect(for: textInput),
           rect.isUsableTextInputAnchor {
            return rect
        }

        guard inferAIInputArea, let windowRect = anchorWindowRect() else {
            return nil
        }

        return Self.inferredInputRect(in: windowRect)
    }

    var windowRect: NSRect? {
        anchorWindowRect()
    }

    var hasConcreteTextInput: Bool {
        textElementForInteraction() != nil
    }

    var matchesCurrentWindow: Bool {
        guard let windowIdentity,
              let currentIdentity = Self.currentWindowIdentity(for: app) else {
            return false
        }
        return windowIdentity == currentIdentity
    }

    static func currentWindowIdentity(for app: NSRunningApplication) -> InputWindowIdentity? {
        windowIdentity(for: app, windowElement: windowElement(for: app))
    }

    func currentText() -> String? {
        guard AccessibilityPermission.isTrusted else {
            return nil
        }

        if let textElement = textElementForInteraction(),
           let value = Self.stringAttribute(kAXValueAttribute, from: textElement),
           let trimmedValue = Self.trimmedInputText(value),
           Self.isMeaningfulInputText(trimmedValue) {
            return trimmedValue
        }

        return nil
    }

    func currentTranslationSource() -> InputTranslationSource? {
        guard AccessibilityPermission.isTrusted,
              let textElement = textElementForInteraction() else {
            return nil
        }

        return Self.preferredTranslationSource(
            value: Self.stringAttribute(kAXValueAttribute, from: textElement),
            selectedText: Self.stringAttribute(kAXSelectedTextAttribute, from: textElement),
            selectedRange: Self.rangeAttribute(kAXSelectedTextRangeAttribute, from: textElement)
        )
    }

    var readableConcreteTextValue: String? {
        guard AccessibilityPermission.isTrusted,
              let textElement = textElementForInteraction() else {
            return nil
        }
        return Self.stringAttribute(kAXValueAttribute, from: textElement)
    }

    @discardableResult
    func restoreSelection(range: NSRange, expectedText: String) -> Bool {
        guard AccessibilityPermission.isTrusted,
              let textElement = textElementForInteraction(),
              let value = Self.stringAttribute(kAXValueAttribute, from: textElement) else {
            return false
        }

        let valueNSString = value as NSString
        guard range.location != NSNotFound,
              range.location >= 0,
              range.length > 0,
              NSMaxRange(range) <= valueNSString.length,
              valueNSString.substring(with: range) == expectedText else {
            return false
        }

        var cfRange = CFRange(location: range.location, length: range.length)
        guard let rangeValue = AXValueCreate(.cfRange, &cfRange),
              AXUIElementSetAttributeValue(
                textElement,
                kAXSelectedTextRangeAttribute as CFString,
                rangeValue
              ) == .success else {
            return false
        }

        return true
    }

    func currentTextExactlyMatches(_ expectedText: String) -> Bool? {
        guard AccessibilityPermission.isTrusted,
              let textElement = textElementForInteraction(),
              let value = Self.stringAttribute(kAXValueAttribute, from: textElement) else {
            return nil
        }

        return value == expectedText
    }

    func matchesCurrentFocusedInput(_ currentFocusedElement: AXUIElement) -> Bool {
        guard AccessibilityPermission.isTrusted,
              !app.isTerminated,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
              matchesCurrentWindow,
              let capturedElement = textElementForInteraction() else {
            return false
        }
        return CFEqual(capturedElement, currentFocusedElement)
    }

    func replacementScopeIsCurrent(_ scope: InputReplacementScope) -> Bool {
        guard AccessibilityPermission.isTrusted,
              let textElement = textElementForInteraction() else {
            return false
        }

        switch scope {
        case .insertAtCursor:
            return true
        case .all(let expectedValue):
            guard let expectedValue else { return true }
            return Self.stringAttribute(kAXValueAttribute, from: textElement) == expectedValue
        case .selection(let expectedRange, let expectedText):
            guard Self.stringAttribute(kAXSelectedTextAttribute, from: textElement) == expectedText else {
                return false
            }
            guard let expectedRange else { return true }
            return Self.rangeAttribute(kAXSelectedTextRangeAttribute, from: textElement) == expectedRange
        }
    }

    func replaceTextDirectly(_ replacement: String, scope: InputReplacementScope) async -> Bool {
        guard AccessibilityPermission.isTrusted,
              let textElement = textElementForInteraction() else {
            return false
        }

        // ChatGPT Classic reports AXValue as settable, but assigning it can
        // clear the React contenteditable without committing the replacement.
        // Use its real focused composer with keyboard paste instead.
        if app.bundleIdentifier == "com.openai.chat" {
            return false
        }

        switch scope {
        case .insertAtCursor:
            return false

        case .all(let expectedValue):
            if let expectedValue, currentTextExactlyMatches(expectedValue) == false {
                return false
            }
            guard AXUIElementSetAttributeValue(
                textElement,
                kAXValueAttribute as CFString,
                replacement as CFString
            ) == .success else {
                return false
            }
            try? await Task.sleep(nanoseconds: 80_000_000)
            return Self.stringAttribute(kAXValueAttribute, from: textElement) == replacement

        case .selection(let suppliedRange, let expectedText):
            if app.bundleIdentifier == "com.anthropic.claudefordesktop" {
                guard let value = Self.stringAttribute(kAXValueAttribute, from: textElement),
                      let range = Self.resolvedSelectionRange(
                        in: value,
                        suppliedRange: suppliedRange,
                        expectedText: expectedText
                      ) else {
                    return false
                }
                let expectedValue = (value as NSString).replacingCharacters(in: range, with: replacement)
                guard AXUIElementSetAttributeValue(
                    textElement,
                    kAXValueAttribute as CFString,
                    expectedValue as CFString
                ) == .success else {
                    return false
                }
                try? await Task.sleep(nanoseconds: 120_000_000)
                return Self.stringAttribute(kAXValueAttribute, from: textElement) == expectedValue
            }
            guard let value = Self.stringAttribute(kAXValueAttribute, from: textElement),
                  let range = Self.resolvedSelectionRange(
                    in: value,
                    suppliedRange: suppliedRange,
                    expectedText: expectedText
                  ) else {
                return false
            }
            let expectedValue = (value as NSString).replacingCharacters(in: range, with: replacement)

            var cfRange = CFRange(location: range.location, length: range.length)
            guard let rangeValue = AXValueCreate(.cfRange, &cfRange),
                  AXUIElementSetAttributeValue(
                    textElement,
                    kAXSelectedTextRangeAttribute as CFString,
                    rangeValue
                  ) == .success else {
                return false
            }

            guard AXUIElementSetAttributeValue(
                textElement,
                kAXSelectedTextAttribute as CFString,
                replacement as CFString
            ) == .success else {
                return false
            }
            try? await Task.sleep(nanoseconds: 80_000_000)
            return Self.stringAttribute(kAXValueAttribute, from: textElement) == expectedValue
        }
    }

    func selectAllText() {
        guard AccessibilityPermission.isTrusted,
              let textElement = textElementForInteraction() else {
            return
        }

        let value = Self.stringAttribute(kAXValueAttribute, from: textElement) ?? ""
        var range = CFRange(location: 0, length: value.utf16.count)
        guard let rangeValue = AXValueCreate(.cfRange, &range) else {
            return
        }

        AXUIElementSetAttributeValue(
            textElement,
            kAXSelectedTextRangeAttribute as CFString,
            rangeValue
        )
    }

    func collapseSelectionToEnd() {
        guard AccessibilityPermission.isTrusted,
              let textElement = textElementForInteraction() else {
            return
        }

        let value = Self.stringAttribute(kAXValueAttribute, from: textElement) ?? ""
        var range = CFRange(location: value.utf16.count, length: 0)
        guard let rangeValue = AXValueCreate(.cfRange, &range) else {
            return
        }

        AXUIElementSetAttributeValue(
            textElement,
            kAXSelectedTextRangeAttribute as CFString,
            rangeValue
        )
    }

    private func anchorWindowRect() -> NSRect? {
        if let anchorWindowElement,
           let rect = Self.rect(for: anchorWindowElement),
           rect.width > 260,
           rect.height > 220 {
            return rect
        }

        return Self.frontmostWindowRect(for: app)
    }

    var isActiveForInput: Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
            || app.isActive
    }

    @discardableResult
    func prepareForPaste() -> Bool {
        app.activate()

        guard isActiveForInput else {
            return false
        }

        // Normal translation must never guess an input location or synthesize
        // a mouse click. Only proceed when Accessibility exposes a concrete
        // text input that can be focused without moving the user's pointer.
        guard AccessibilityPermission.isTrusted,
              let textElement = textElementForInteraction() else {
            return false
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        let appFocusResult = AXUIElementSetAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            textElement
        )
        let elementFocusResult = AXUIElementSetAttributeValue(
            textElement,
            kAXFocusedAttribute as CFString,
            kCFBooleanTrue
        )
        return appFocusResult == .success || elementFocusResult == .success
    }

    private func textElementForInteraction() -> AXUIElement? {
        if let focusedElement, Self.isTextInput(focusedElement) {
            return focusedElement
        }

        return Self.bestTextInputElement(in: app)
    }

    private static func focusedElement(for app: NSRunningApplication) -> AXUIElement? {
        guard AccessibilityPermission.isTrusted else {
            return nil
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var focusedReference: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedReference
        )

        guard result == .success, let focusedReference else {
            return nil
        }
        guard CFGetTypeID(focusedReference) == AXUIElementGetTypeID() else {
            return nil
        }
        return (focusedReference as! AXUIElement)
    }

    private static func textInputElement(near focusedElement: AXUIElement?, in app: NSRunningApplication) -> AXUIElement? {
        if let focusedElement, isTextInput(focusedElement) {
            return focusedElement
        }

        return bestTextInputElement(in: app)
    }

    private static func bestTextInputElement(
        in app: NSRunningApplication,
        windowElement suppliedWindowElement: AXUIElement? = nil
    ) -> AXUIElement? {
        guard AccessibilityPermission.isTrusted else {
            return nil
        }

        let windowElement = suppliedWindowElement ?? windowElement(for: app)
        let root = windowElement ?? AXUIElementCreateApplication(app.processIdentifier)
        let windowRect = windowElement.flatMap { rect(for: $0) }
            ?? frontmostWindowRect(for: app)
        var bestCandidate: (element: AXUIElement, score: CGFloat)?
        var visitedNodes = 0
        var foundSemanticComposer = false

        func visit(_ element: AXUIElement, depth: Int) {
            guard !foundSemanticComposer, depth <= 12, visitedNodes < 1_200 else {
                return
            }
            visitedNodes += 1

            if isTextInput(element),
               let rect = rect(for: element),
               rect.isUsableTextInputAnchor,
               let windowRect {
                let metadata = inputMetadata(
                    for: element,
                    includingAncestorCount: 2,
                    stoppingAt: root
                )
                guard let score = chatInputCandidateScore(
                    metadata: metadata,
                    rect: rect,
                    windowRect: windowRect
                ) else {
                    return visitChildren(of: element, depth: depth)
                }
                if bestCandidate == nil || score > bestCandidate!.score {
                    bestCandidate = (element, score)
                }
                if hasChatComposerHint(metadata) {
                    foundSemanticComposer = true
                    return
                }
            }

            visitChildren(of: element, depth: depth)
        }

        func visitChildren(of element: AXUIElement, depth: Int) {
            guard let children = childrenAttribute(kAXChildrenAttribute, from: element) else {
                return
            }

            for child in children {
                visit(child, depth: depth + 1)
            }
        }

        visit(root, depth: 0)
        return bestCandidate?.element
    }

    private static func windowIdentity(
        for app: NSRunningApplication,
        windowElement: AXUIElement?
    ) -> InputWindowIdentity? {
        if let windowElement {
            return InputWindowIdentity(
                processIdentifier: app.processIdentifier,
                accessibilityElementHash: Int(CFHash(windowElement)),
                fallbackWindowID: nil
            )
        }

        if let fallbackWindowID = EdgeOverlayGeometry.mainWindowID(
            for: app,
            minimumSize: NSSize(width: 260, height: 220)
        ) {
            return InputWindowIdentity(
                processIdentifier: app.processIdentifier,
                accessibilityElementHash: nil,
                fallbackWindowID: fallbackWindowID
            )
        }

        return nil
    }

    private static func windowElement(for app: NSRunningApplication) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)

        if let focusedWindow = elementAttribute(kAXFocusedWindowAttribute, from: appElement) {
            return focusedWindow
        }

        if let mainWindow = elementAttribute(kAXMainWindowAttribute, from: appElement) {
            return mainWindow
        }

        return nil
    }

    private static func rootElement(for app: NSRunningApplication) -> AXUIElement {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)

        if let windowElement = windowElement(for: app) {
            return windowElement
        }

        return appElement
    }

    private static func frontmostWindowRect(for app: NSRunningApplication) -> NSRect? {
        let root = rootElement(for: app)
        let rect = rect(for: root)

        if let rect, rect.width > 260, rect.height > 220 {
            return rect
        }

        return EdgeOverlayGeometry.mainWindowRect(
            for: app,
            minimumSize: NSSize(width: 260, height: 220)
        )
    }

    private static func inferredInputRect(in windowRect: NSRect) -> NSRect {
        let width = min(max(windowRect.width * 0.64, 520), windowRect.width - 96)
        let height = min(max(windowRect.height * 0.10, 88), 118)
        let bottomInset = min(max(windowRect.height * 0.055, 58), 92)
        return NSRect(
            x: windowRect.midX - width / 2,
            y: windowRect.minY + bottomInset,
            width: width,
            height: height
        )
    }

    private static func fallbackAnchorRatio(for app: NSRunningApplication, windowElement: AXUIElement?) -> CGRect? {
        let windowRect: NSRect?
        if let windowElement,
           let rect = rect(for: windowElement),
           rect.width > 260,
           rect.height > 220 {
            windowRect = rect
        } else {
            windowRect = frontmostWindowRect(for: app)
        }

        guard let windowRect else {
            return nil
        }

        let anchorRect = inferredInputRect(in: windowRect)
        return CGRect(
            x: (anchorRect.minX - windowRect.minX) / windowRect.width,
            y: (anchorRect.minY - windowRect.minY) / windowRect.height,
            width: anchorRect.width / windowRect.width,
            height: anchorRect.height / windowRect.height
        )
    }

    private static func rect(from ratio: CGRect, in windowRect: NSRect) -> NSRect {
        NSRect(
            x: windowRect.minX + ratio.minX * windowRect.width,
            y: windowRect.minY + ratio.minY * windowRect.height,
            width: ratio.width * windowRect.width,
            height: ratio.height * windowRect.height
        )
    }

    private static func isTextInput(_ element: AXUIElement) -> Bool {
        guard let role = stringAttribute(kAXRoleAttribute, from: element) else {
            return false
        }

        if let subrole = stringAttribute(kAXSubroleAttribute, from: element),
           subrole.localizedCaseInsensitiveContains("secure") {
            return false
        }

        let textRoles = [
            kAXTextFieldRole as String,
            kAXTextAreaRole as String,
            kAXComboBoxRole as String
        ]

        var settable = DarwinBoolean(false)
        let settableResult = AXUIElementIsAttributeSettable(
            element,
            kAXValueAttribute as CFString,
            &settable
        )

        guard settableResult == .success, settable.boolValue else {
            return false
        }

        if textRoles.contains(role) {
            return true
        }

        // Electron/WebView chat inputs sometimes expose contenteditable fields as
        // small settable AXGroup/AXWebArea nodes instead of AXTextArea.
        let webEditableRoles = [
            kAXGroupRole as String,
            "AXWebArea"
        ]
        guard webEditableRoles.contains(role),
              let rect = rect(for: element),
              rect.isUsableTextInputAnchor else {
            return false
        }

        return true
    }

    private static func isLikelyChatInputElement(
        _ element: AXUIElement,
        in app: NSRunningApplication,
        knownWindowRect: NSRect? = nil
    ) -> Bool {
        let metadata = inputMetadata(for: element, includingAncestorCount: 2)
        guard let inputRect = rect(for: element),
              let windowRect = knownWindowRect ?? frontmostWindowRect(for: app) else {
            return false
        }
        return chatInputCandidateScore(
            metadata: metadata,
            rect: inputRect,
            windowRect: windowRect,
            isFocused: true
        ) != nil
    }

    static func chatInputCandidateScore(
        metadata: String,
        rect: NSRect,
        windowRect: NSRect,
        isFocused: Bool = false
    ) -> CGFloat? {
        guard rect.isUsableTextInputAnchor,
              windowRect.width > 0,
              windowRect.height > 0,
              !hasExcludedInputHint(metadata) else {
            return nil
        }

        let intersection = rect.intersection(windowRect)
        guard !intersection.isNull,
              intersection.width * intersection.height >= rect.width * rect.height * 0.55 else {
            return nil
        }

        let relativeMidY = (rect.midY - windowRect.minY) / windowRect.height
        let widthRatio = rect.width / windowRect.width
        let hasSemanticHint = hasChatComposerHint(metadata)
        let isWideEnough = rect.width >= max(220, windowRect.width * 0.26)
        // WebKit exposes ChatGPT's contenteditable composer as a one-line
        // AXTextArea (roughly 17 pt high) inside a much taller visual card.
        let isComposerHeight = rect.height >= 14
            && rect.height <= max(180, windowRect.height * 0.28)

        guard isComposerHeight,
              hasSemanticHint || (relativeMidY <= 0.38 && isWideEnough) else {
            return nil
        }

        let semanticScore: CGFloat = hasSemanticHint ? 4_000 : 0
        let focusScore: CGFloat = isFocused ? 1_200 : 0
        let bottomScore = max(0, 1 - max(0, relativeMidY)) * 900
        let widthScore = min(max(widthRatio, 0), 1) * 500
        return semanticScore + focusScore + bottomScore + widthScore + min(rect.height, 160)
    }

    static func hasChatComposerHint(_ metadata: String) -> Bool {
        let normalized = metadata.lowercased()
        return [
            "write your prompt",
            "write a message",
            "message claude",
            "message chatgpt",
            "message gemini",
            "ask anything",
            "send a message",
            "enter a prompt",
            "type a message",
            "prompt-textarea",
            "prompt textarea",
            "chat input",
            "chat-input",
            "message composer",
            "输入消息",
            "发送消息",
            "输入提示",
            "问问",
            "询问 chatgpt"
        ].contains { normalized.contains($0) }
    }

    static func hasExcludedInputHint(_ metadata: String) -> Bool {
        let normalized = metadata.lowercased()
        return [
            "search",
            "filter",
            "find in",
            "rename",
            "conversation title",
            "source editor",
            "code editor",
            "terminal",
            "console",
            "搜索",
            "查找",
            "筛选",
            "重命名",
            "代码编辑器",
            "终端"
        ].contains { normalized.contains($0) }
    }

    private static func inputMetadata(
        for element: AXUIElement,
        includingAncestorCount: Int = 0,
        stoppingAt root: AXUIElement? = nil
    ) -> String {
        var parts: [String] = []
        var current: AXUIElement? = element
        var remainingAncestors = includingAncestorCount

        while let candidate = current {
            parts.append(contentsOf: [
                stringAttribute(kAXIdentifierAttribute, from: candidate),
                stringAttribute(kAXDescriptionAttribute, from: candidate),
                stringAttribute(kAXTitleAttribute, from: candidate),
                stringAttribute(kAXHelpAttribute, from: candidate),
                stringAttribute(kAXPlaceholderValueAttribute, from: candidate)
            ].compactMap { $0 })

            guard remainingAncestors > 0,
                  root.map({ !CFEqual(candidate, $0) }) ?? true,
                  let parent = elementAttribute(kAXParentAttribute, from: candidate) else {
                break
            }
            remainingAncestors -= 1
            current = parent
        }

        return parts.joined(separator: " ")
    }

    private static func rect(for element: AXUIElement) -> NSRect? {
        var positionReference: CFTypeRef?
        var sizeReference: CFTypeRef?

        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionReference) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeReference) == .success,
              let positionReference,
              let sizeReference else {
            return nil
        }

        let positionValue = positionReference as! AXValue
        let sizeValue = sizeReference as! AXValue
        var position = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(positionValue, .cgPoint, &position)
        AXValueGetValue(sizeValue, .cgSize, &size)

        return convertAXRectToAppKitRect(CGRect(origin: position, size: size))
    }

    private static func convertAXRectToAppKitRect(_ rect: CGRect) -> NSRect {
        let maxDisplayY = NSScreen.screens.map(\.frame.maxY).max() ?? NSScreen.main?.frame.maxY ?? rect.maxY
        return NSRect(
            x: rect.minX,
            y: maxDisplayY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    private static func elementAttribute(_ attribute: String, from element: AXUIElement) -> AXUIElement? {
        var reference: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &reference)
        guard result == .success, let reference else {
            return nil
        }
        guard CFGetTypeID(reference) == AXUIElementGetTypeID() else {
            return nil
        }
        return (reference as! AXUIElement)
    }

    private static func childrenAttribute(_ attribute: String, from element: AXUIElement) -> [AXUIElement]? {
        var reference: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &reference)
        guard result == .success else {
            return nil
        }
        return reference as? [AXUIElement]
    }

    private static func stringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var reference: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &reference)
        guard result == .success else {
            return nil
        }
        return reference as? String
    }

    static func isMeaningfulInputText(_ text: String) -> Bool {
        let normalized = text
            .replacingOccurrences(of: "…", with: "...")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard !normalized.isEmpty else {
            return false
        }

        let placeholders = [
            "write a message...",
            "write a message... write a message...",
            "message claude...",
            "ask anything...",
            "message chatgpt...",
            "send a message...",
            "ask chatgpt",
            "ask chatgpt...",
            "问问 chatgpt",
            "问问 chatgpt...",
            "询问 chatgpt",
            "询问 chatgpt...",
            "与 chatgpt 聊天",
            "有问题，尽管问",
            "有问题,尽管问",
            "何でも聞いてください",
            "chatgpt にメッセージを送信する"
        ]

        return !placeholders.contains(normalized)
    }

    static func accessibilityValueProvesInputIsEmpty(_ value: String?) -> Bool {
        guard let value else { return false }
        return trimmedInputText(value) == nil
    }

    static func isTranslatableInputText(_ text: String) -> Bool {
        guard isMeaningfulInputText(text) else {
            return false
        }
        let profile = inputLanguageProfile(in: text)
        return hasMeaningfulCJKAmount(profile)
    }

    static func isTranslatableInputText(_ text: String, to targetLanguage: TargetLanguage) -> Bool {
        guard isMeaningfulInputText(text) else {
            return false
        }

        let profile = inputLanguageProfile(in: text)
        if targetLanguage == .simplifiedChinese {
            let nonHanLetters = max(0, profile.letters - profile.han)
            return profile.kana >= 1 || nonHanLetters >= 2
        }

        guard hasMeaningfulCJKAmount(profile) else {
            return false
        }

        if targetLanguage == .japanese {
            let cjkCount = max(profile.han + profile.kana, 1)
            let kanaRatio = Double(profile.kana) / Double(cjkCount)
            if profile.kana >= 2, kanaRatio >= 0.12 {
                return false
            }
        }

        return true
    }

    static func preferredTranslationSource(
        value: String?,
        selectedText: String?,
        selectedRange: NSRange?
    ) -> InputTranslationSource? {
        let rangedSelection: String? = {
            guard let value,
                  let selectedRange,
                  selectedRange.location != NSNotFound,
                  selectedRange.length > 0,
                  NSMaxRange(selectedRange) <= (value as NSString).length else {
                return nil
            }
            return (value as NSString).substring(with: selectedRange)
        }()
        let effectiveSelectedText = rangedSelection ?? selectedText

        if let effectiveSelectedText,
           let trimmedSelection = trimmedInputText(effectiveSelectedText),
           isMeaningfulInputText(trimmedSelection) {
            if let value,
               trimmedInputText(value) == trimmedSelection {
                return InputTranslationSource(
                    text: trimmedSelection,
                    replacementScope: .all(expectedValue: value)
                )
            }

            let preciseSelection: (range: NSRange?, expectedText: String) = {
                guard let selectedRange,
                      selectedRange.length > 0 else {
                    return (nil, effectiveSelectedText)
                }

                let relativeRange = (effectiveSelectedText as NSString).range(of: trimmedSelection)
                guard relativeRange.location != NSNotFound else {
                    return (selectedRange, effectiveSelectedText)
                }
                return (
                    NSRange(
                        location: selectedRange.location + relativeRange.location,
                        length: relativeRange.length
                    ),
                    trimmedSelection
                )
            }()
            return InputTranslationSource(
                text: trimmedSelection,
                replacementScope: .selection(
                    range: preciseSelection.range,
                    expectedText: preciseSelection.expectedText
                )
            )
        }

        guard let value,
              let trimmedValue = trimmedInputText(value),
              isMeaningfulInputText(trimmedValue) else {
            return nil
        }

        return InputTranslationSource(
            text: trimmedValue,
            replacementScope: .all(expectedValue: value)
        )
    }

    static func debugTextInputCandidates(in app: NSRunningApplication) -> [String] {
        guard AccessibilityPermission.isTrusted else {
            return []
        }

        let root = rootElement(for: app)
        var output: [String] = []
        var visitedNodes = 0

        func visit(_ element: AXUIElement, depth: Int) {
            guard depth <= 18, visitedNodes < 1_800, output.count < 16 else {
                return
            }
            visitedNodes += 1

            let role = stringAttribute(kAXRoleAttribute, from: element) ?? "<nil>"
            let value = stringAttribute(kAXValueAttribute, from: element) ?? ""
            let metadata = inputMetadata(for: element)
            var settable = DarwinBoolean(false)
            let settableResult = AXUIElementIsAttributeSettable(
                element,
                kAXValueAttribute as CFString,
                &settable
            )

            if (settableResult == .success && settable.boolValue
                || [kAXTextFieldRole as String, kAXTextAreaRole as String, kAXComboBoxRole as String].contains(role)),
               let rect = rect(for: element) {
                let shortValue = value
                    .components(separatedBy: .whitespacesAndNewlines)
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                    .prefix(80)
                output.append(
                    "depth=\(depth) role=\(role) settable=\(settableResult == .success && settable.boolValue) rect=x=\(Int(rect.minX)),y=\(Int(rect.minY)),w=\(Int(rect.width)),h=\(Int(rect.height)) metadata=\(metadata.prefix(100)) value=\(shortValue)"
                )
            }

            guard let children = childrenAttribute(kAXChildrenAttribute, from: element) else {
                return
            }

            for child in children {
                visit(child, depth: depth + 1)
            }
        }

        visit(root, depth: 0)
        return output
    }

    static func normalizedInputText(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        var candidate = trimmed
        while let half = exactRepeatedHalf(in: candidate) {
            candidate = half
        }
        return candidate
    }

    private static func trimmedInputText(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func rangeAttribute(_ attribute: String, from element: AXUIElement) -> NSRange? {
        var reference: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &reference)
        guard result == .success,
              let reference,
              CFGetTypeID(reference) == AXValueGetTypeID() else {
            return nil
        }

        let value = reference as! AXValue
        guard AXValueGetType(value) == .cfRange else {
            return nil
        }

        var range = CFRange()
        guard AXValueGetValue(value, .cfRange, &range), range.location >= 0, range.length > 0 else {
            return nil
        }
        return NSRange(location: range.location, length: range.length)
    }

    private static func resolvedSelectionRange(
        in value: String,
        suppliedRange: NSRange?,
        expectedText: String
    ) -> NSRange? {
        let valueNSString = value as NSString
        if let suppliedRange,
           suppliedRange.location != NSNotFound,
           suppliedRange.length > 0,
           NSMaxRange(suppliedRange) <= valueNSString.length,
           valueNSString.substring(with: suppliedRange) == expectedText {
            return suppliedRange
        }

        let firstMatch = valueNSString.range(of: expectedText)
        guard firstMatch.location != NSNotFound else {
            return nil
        }

        let remainingLocation = NSMaxRange(firstMatch)
        if remainingLocation < valueNSString.length {
            let remaining = NSRange(
                location: remainingLocation,
                length: valueNSString.length - remainingLocation
            )
            if valueNSString.range(of: expectedText, range: remaining).location != NSNotFound {
                return nil
            }
        }

        return firstMatch
    }

    private static func inputLanguageProfile(in text: String) -> (han: Int, kana: Int, letters: Int) {
        var han = 0
        var kana = 0
        var letters = 0

        for scalar in text.unicodeScalars {
            if CharacterSet.letters.contains(scalar) {
                letters += 1
            }
            switch scalar.value {
            case 0x3040...0x30FF, // Hiragana and Katakana
                 0xFF66...0xFF9F: // Half-width Katakana
                kana += 1
            case 0x3400...0x4DBF, // CJK Extension A
                 0x4E00...0x9FFF, // CJK Unified Ideographs
                 0xF900...0xFAFF: // CJK Compatibility Ideographs
                han += 1
            default:
                break
            }
        }

        return (han, kana, letters)
    }

    private static func hasMeaningfulCJKAmount(_ profile: (han: Int, kana: Int, letters: Int)) -> Bool {
        let cjkCount = profile.han + profile.kana
        guard cjkCount >= 2 else {
            return false
        }

        let ratio = Double(cjkCount) / Double(max(profile.letters, 1))
        return cjkCount >= 6 || ratio >= 0.12
    }

    private static func exactRepeatedHalf(in text: String) -> String? {
        let scalars = Array(text.unicodeScalars)
        guard scalars.count >= 2, scalars.count.isMultiple(of: 2) else {
            return nil
        }

        let midpoint = scalars.count / 2
        guard scalars[..<midpoint] == scalars[midpoint...] else {
            return nil
        }

        return String(String.UnicodeScalarView(scalars[..<midpoint]))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension NSRect {
    func distance(to other: NSRect) -> CGFloat {
        abs(minX - other.minX)
            + abs(minY - other.minY)
            + abs(width - other.width)
            + abs(height - other.height)
    }

    var isUsableTextInputAnchor: Bool {
        width >= 160 && height >= 14 && height <= 240 && width.isFinite && height.isFinite
    }

    var isUsableInputAnchor: Bool {
        width >= 160 && height >= 24 && width.isFinite && height.isFinite
    }
}
