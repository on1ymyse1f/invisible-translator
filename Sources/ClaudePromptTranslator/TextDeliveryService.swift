import AppKit
import Carbon.HIToolbox
import CoreGraphics

enum DeliveryError: LocalizedError {
    case accessibilityPermissionRequired
    case targetInputUnavailable
    case emptyInput
    case nonTranslatableInput
    case inputChanged
    case inputWriteVerificationFailed
    case targetAppChanged
    case clipboardCompatibilityDisabled
    case privacyBlocked

    var errorDescription: String? {
        switch self {
        case .accessibilityPermissionRequired:
            return "Enable Accessibility permission for Claude Prompt Translator, then try again."
        case .targetInputUnavailable:
            return "Focus an AI chat input first, then try again."
        case .emptyInput:
            return "The focused input field is empty."
        case .nonTranslatableInput:
            return "Type Chinese or Japanese in the focused input field first."
        case .inputChanged:
            return "The input changed while it was being translated. Nothing was replaced."
        case .inputWriteVerificationFailed:
            return "The ChatGPT input did not contain the expected text after replacement."
        case .targetAppChanged:
            return "The target app is no longer active. Nothing was replaced."
        case .clipboardCompatibilityDisabled:
            return "剪贴板兼容模式默认关闭；当前应用不支持纯 Accessibility 读写。"
        case .privacyBlocked:
            return "App 隐私名单已取消本次读取或写入。"
        }
    }
}

enum KeyboardInjectionSafety {
    static func canInject(
        expectedProcessIdentifier: pid_t,
        frontmostProcessIdentifier: pid_t?,
        expectedFocusIdentity: Int,
        currentFocusIdentity: Int?
    ) -> Bool {
        frontmostProcessIdentifier == expectedProcessIdentifier
            && currentFocusIdentity == expectedFocusIdentity
    }
}

enum PasteboardOwnershipSafety {
    static func canRestore(expectedChangeCount: Int, currentChangeCount: Int) -> Bool {
        expectedChangeCount == currentChangeCount
    }
}

enum ClipboardPasteSafety {
    static func canProceed(
        initialInputEpoch: UInt64,
        currentInputEpoch: UInt64,
        contextIsCurrent: Bool,
        containsProtectedContent: Bool,
        selectionRangeMatches: Bool
    ) -> Bool {
        initialInputEpoch == currentInputEpoch
            && contextIsCurrent
            && !containsProtectedContent
            && selectionRangeMatches
    }
}

@MainActor
struct KeyboardInjectionContext {
    let processIdentifier: pid_t
    let focusedElement: AXUIElement
    let focusedElementIdentity: Int

    static func capture(for app: NSRunningApplication) -> KeyboardInjectionContext? {
        guard !app.isTerminated,
              let focusedElement = focusedElement(for: app) else {
            return nil
        }
        return KeyboardInjectionContext(
            processIdentifier: app.processIdentifier,
            focusedElement: focusedElement,
            focusedElementIdentity: Int(CFHash(focusedElement))
        )
    }

    func isCurrent(for app: NSRunningApplication) -> Bool {
        guard !app.isTerminated,
              app.processIdentifier == processIdentifier,
              let currentFocusedElement = Self.focusedElement(for: app),
              KeyboardInjectionSafety.canInject(
                  expectedProcessIdentifier: processIdentifier,
                  frontmostProcessIdentifier: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                  expectedFocusIdentity: focusedElementIdentity,
                  currentFocusIdentity: Int(CFHash(currentFocusedElement))
              ) else {
            return false
        }
        return CFEqual(focusedElement, currentFocusedElement)
    }

    private static func focusedElement(for app: NSRunningApplication) -> AXUIElement? {
        let applicationElement = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            applicationElement,
            kAXFocusedUIElementAttribute as CFString,
            &value
        ) == .success,
        let value,
        CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement)
    }
}

private struct ClipboardCopyAttempt {
    let text: String?
    let isAmbiguous: Bool
}

@MainActor
struct TextDeliveryService {
    func deliver(
        _ text: String,
        to target: InputTarget?,
        allowClipboardFallback: Bool = false,
        authorizationCheck: @MainActor () -> Bool = { true }
    ) async throws {
        guard authorizationCheck() else { throw DeliveryError.privacyBlocked }
        guard let target else {
            throw DeliveryError.targetInputUnavailable
        }
        guard allowClipboardFallback else {
            throw DeliveryError.clipboardCompatibilityDisabled
        }
        guard target.hasConcreteTextInput,
              target.prepareForPaste(),
              let injectionContext = KeyboardInjectionContext.capture(for: target.app),
              !IsSecureEventInputEnabled(),
              !isProtectedElementOrAncestor(injectionContext.focusedElement) else {
            throw DeliveryError.targetInputUnavailable
        }

        let inputGuard = ClipboardFallbackInputGuard()
        guard inputGuard.isMonitoring else {
            throw DeliveryError.targetInputUnavailable
        }
        defer { inputGuard.stop() }
        let initialInputEpoch = inputGuard.epoch

        try await Task.sleep(nanoseconds: 260_000_000)
        try Task.checkCancellation()
        try await Task.sleep(nanoseconds: 150_000_000)
        try Task.checkCancellation()
        guard authorizationCheck() else { throw DeliveryError.privacyBlocked }

        guard let pasteSelectionRange = selectedRange(in: injectionContext.focusedElement),
              pasteContextIsCurrent(
                  injectionContext,
                  selectedRange: pasteSelectionRange,
                  initialInputEpoch: initialInputEpoch,
                  inputGuard: inputGuard,
                  target: target
              ) else {
            throw DeliveryError.inputChanged
        }

        let snapshot = PasteboardSnapshot.capture()
        let baselineChangeCount = snapshot.changeCountAtCapture
        guard NSPasteboard.general.changeCount == baselineChangeCount else {
            throw DeliveryError.inputChanged
        }
        guard authorizationCheck() else { throw DeliveryError.privacyBlocked }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        let ownedChangeCount = NSPasteboard.general.changeCount
        defer { snapshot.restoreIfChangeCount(is: ownedChangeCount) }

        guard pasteContextIsCurrent(
            injectionContext,
            selectedRange: pasteSelectionRange,
            initialInputEpoch: initialInputEpoch,
            inputGuard: inputGuard,
            target: target
        ), NSPasteboard.general.changeCount == ownedChangeCount else {
            throw DeliveryError.inputChanged
        }
        guard authorizationCheck() else { throw DeliveryError.privacyBlocked }
        try sendPasteCommand(to: target, context: injectionContext)
        try await Task.sleep(nanoseconds: 1_200_000_000)
    }

    func readCurrentInput(
        from target: InputTarget?,
        allowClipboardFallback: Bool = false,
        authorizationCheck: @MainActor () -> Bool = { true }
    ) async -> InputTranslationSource? {
        guard AccessibilityPermission.isTrusted, authorizationCheck() else {
            return nil
        }

        debugLog("read:start target=\(target?.appName ?? "<nil>")")
        guard let target,
              target.hasConcreteTextInput,
              let preparedInjectionContext = KeyboardInjectionContext.capture(for: target.app),
              target.matchesCurrentFocusedInput(preparedInjectionContext.focusedElement),
              !IsSecureEventInputEnabled(),
              !isProtectedElementOrAncestor(preparedInjectionContext.focusedElement) else {
            debugLog("read:no concrete accessible input")
            return nil
        }
        try? await Task.sleep(nanoseconds: 120_000_000)
        guard !Task.isCancelled,
              authorizationCheck(),
              preparedInjectionContext.isCurrent(for: target.app),
              target.matchesCurrentFocusedInput(preparedInjectionContext.focusedElement),
              !IsSecureEventInputEnabled(),
              !isProtectedElementOrAncestor(preparedInjectionContext.focusedElement) else {
            debugLog("read:input context changed during stabilization")
            return nil
        }

        let directSource = target.currentTranslationSource().flatMap { source in
            source.text.count <= TranslationLimits.maxInputCharacters ? source : nil
        }
        if let directSource {
            debugLog("read:direct count=\(directSource.text.count) selected=\(directSource.usesSelection)")
            return directSource
        }

        // A readable empty AXValue is authoritative. Continuing with Cmd+A/C
        // from an empty composer can escape the field and copy the entire chat
        // transcript, which was previously misreported as input text.
        if InputTarget.accessibilityValueProvesInputIsEmpty(
            target.readableConcreteTextValue
        ) {
            debugLog("read:concrete input is empty")
            return nil
        }

        guard allowClipboardFallback else {
            debugLog("read:clipboard compatibility disabled")
            return nil
        }

        guard authorizationCheck(),
              preparedInjectionContext.isCurrent(for: target.app) else {
            debugLog("read:target or focus changed before keyboard fallback")
            return nil
        }
        let injectionContext = preparedInjectionContext

        debugLog("read:keyboard copy from confirmed accessible input")
        let selectedAttempt = await copyFocusedText(
            selectAll: false,
            target: target,
            context: injectionContext,
            authorizationCheck: authorizationCheck
        )
        guard !selectedAttempt.isAmbiguous else {
            debugLog("read:selected copy ownership ambiguous")
            return nil
        }
        if let selectedText = selectedAttempt.text,
           let selectedSource = clipboardSource(selectedText, scope: .selection(range: nil, expectedText: selectedText)) {
            debugLog("read:selected count=\(selectedSource.text.count)")
            return selectedSource
        }

        let focusedAttempt = await copyFocusedText(
            selectAll: true,
            target: target,
            context: injectionContext,
            authorizationCheck: authorizationCheck
        )
        guard !focusedAttempt.isAmbiguous else {
            debugLog("read:focused copy ownership ambiguous")
            return nil
        }
        if let focusedText = focusedAttempt.text,
           let focusedSource = clipboardSource(focusedText, scope: .all(expectedValue: focusedText)) {
            debugLog("read:focused count=\(focusedSource.text.count)")
            if injectionContext.isCurrent(for: target.app) {
                target.collapseSelectionToEnd()
            }
            return focusedSource
        }

        if injectionContext.isCurrent(for: target.app) {
            target.collapseSelectionToEnd()
        }
        debugLog("read:confirmed input copy rejected")
        return nil
    }

    func readCurrentInputText(
        from target: InputTarget?,
        allowClipboardFallback: Bool = false,
        authorizationCheck: @MainActor () -> Bool = { true }
    ) async -> String? {
        await readCurrentInput(
            from: target,
            allowClipboardFallback: allowClipboardFallback,
            authorizationCheck: authorizationCheck
        )?.text
    }

    func replaceCurrentInput(
        with text: String,
        in target: InputTarget?,
        scope: InputReplacementScope = .all(expectedValue: nil),
        allowClipboardFallback: Bool = false,
        authorizationCheck: @MainActor () -> Bool = { true }
    ) async throws {
        guard AccessibilityPermission.isTrusted else {
            throw DeliveryError.accessibilityPermissionRequired
        }
        guard authorizationCheck() else { throw DeliveryError.privacyBlocked }
        guard let target else {
            throw DeliveryError.targetInputUnavailable
        }
        guard target.hasConcreteTextInput else {
            throw DeliveryError.targetInputUnavailable
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.app.processIdentifier,
              !target.app.isTerminated else {
            throw DeliveryError.targetAppChanged
        }

        guard let preparedInjectionContext = KeyboardInjectionContext.capture(for: target.app),
              target.matchesCurrentFocusedInput(preparedInjectionContext.focusedElement),
              !IsSecureEventInputEnabled(),
              !isProtectedElementOrAncestor(preparedInjectionContext.focusedElement) else {
            throw DeliveryError.inputChanged
        }
        let transactionInputGuard = allowClipboardFallback
            ? ClipboardFallbackInputGuard()
            : nil
        let initialInputEpoch = transactionInputGuard?.epoch
        defer { transactionInputGuard?.stop() }
        try await Task.sleep(nanoseconds: 180_000_000)
        try Task.checkCancellation()
        guard authorizationCheck() else { throw DeliveryError.privacyBlocked }

        guard preparedInjectionContext.isCurrent(for: target.app),
              target.matchesCurrentFocusedInput(preparedInjectionContext.focusedElement),
              target.replacementScopeIsCurrent(scope),
              !IsSecureEventInputEnabled(),
              !isProtectedElementOrAncestor(preparedInjectionContext.focusedElement) else {
            throw DeliveryError.inputChanged
        }

        if await target.replaceTextDirectly(
            text,
            scope: scope,
            authorizationCheck: authorizationCheck
        ) {
            return
        }
        guard allowClipboardFallback else {
            throw DeliveryError.clipboardCompatibilityDisabled
        }
        let injectionContext = preparedInjectionContext
        guard let inputGuard = transactionInputGuard,
              inputGuard.isMonitoring,
              let initialInputEpoch,
              pastePreparationContextIsCurrent(
                  injectionContext,
                  initialInputEpoch: initialInputEpoch,
                  inputGuard: inputGuard,
                  target: target
              ) else {
            throw DeliveryError.targetAppChanged
        }

        switch scope {
        case .insertAtCursor:
            break

        case .all(let expectedValue):
            if let expectedValue, target.currentTextExactlyMatches(expectedValue) == false {
                throw DeliveryError.inputChanged
            }

            guard authorizationCheck() else { throw DeliveryError.privacyBlocked }
            target.selectAllText()
            try await Task.sleep(nanoseconds: 50_000_000)
            try sendSelectAllCommand(to: target, context: injectionContext)
            try await Task.sleep(nanoseconds: 100_000_000)

        case .selection(let range, let expectedText):
            if let range {
                guard authorizationCheck() else { throw DeliveryError.privacyBlocked }
                guard target.restoreSelection(range: range, expectedText: expectedText) else {
                    throw DeliveryError.inputChanged
                }
            } else {
                let selectedAttempt = await copyFocusedText(
                    selectAll: false,
                    target: target,
                    context: injectionContext,
                    authorizationCheck: authorizationCheck
                )
                guard !selectedAttempt.isAmbiguous,
                      let selectedText = selectedAttempt.text,
                      selectedText == expectedText else {
                    throw DeliveryError.inputChanged
                }
            }

        }

        guard let pasteSelectionRange = selectedRange(in: injectionContext.focusedElement),
              pasteContextIsCurrent(
                  injectionContext,
                  selectedRange: pasteSelectionRange,
                  initialInputEpoch: initialInputEpoch,
                  inputGuard: inputGuard,
                  target: target
              ) else {
            throw DeliveryError.inputChanged
        }

        let snapshot = PasteboardSnapshot.capture()
        let baselineChangeCount = snapshot.changeCountAtCapture
        guard NSPasteboard.general.changeCount == baselineChangeCount else {
            throw DeliveryError.inputChanged
        }
        guard authorizationCheck() else { throw DeliveryError.privacyBlocked }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        let ownedChangeCount = NSPasteboard.general.changeCount
        defer { snapshot.restoreIfChangeCount(is: ownedChangeCount) }

        try Task.checkCancellation()
        guard pasteContextIsCurrent(
            injectionContext,
            selectedRange: pasteSelectionRange,
            initialInputEpoch: initialInputEpoch,
            inputGuard: inputGuard,
            target: target
        ), NSPasteboard.general.changeCount == ownedChangeCount else {
            throw DeliveryError.inputChanged
        }
        guard authorizationCheck() else { throw DeliveryError.privacyBlocked }
        try sendPasteCommand(to: target, context: injectionContext)
        try await Task.sleep(nanoseconds: 1_200_000_000)

        if let actualValue = target.readableConcreteTextValue {
            let matches: Bool
            switch scope {
            case .insertAtCursor:
                matches = actualValue.contains(text)
            case .all:
                matches = actualValue == text
            case .selection:
                matches = actualValue.contains(text)
            }
            guard matches else {
                throw DeliveryError.inputWriteVerificationFailed
            }
        }
    }

    private func sendPasteCommand(
        to target: InputTarget,
        context: KeyboardInjectionContext
    ) throws {
        try sendKeyboardCommand(keyCode: 9, to: target, context: context)
    }

    private func sendCopyCommand(
        to target: InputTarget,
        context: KeyboardInjectionContext
    ) throws {
        try sendKeyboardCommand(keyCode: 8, to: target, context: context)
    }

    private func sendSelectAllCommand(
        to target: InputTarget,
        context: KeyboardInjectionContext
    ) throws {
        try sendKeyboardCommand(keyCode: 0, to: target, context: context)
    }

    private func copyFocusedText(
        selectAll: Bool,
        target: InputTarget,
        context: KeyboardInjectionContext,
        authorizationCheck: @MainActor () -> Bool
    ) async -> ClipboardCopyAttempt {
        guard authorizationCheck(),
              context.isCurrent(for: target.app),
              !IsSecureEventInputEnabled(),
              !isProtectedElementOrAncestor(context.focusedElement) else {
            return ClipboardCopyAttempt(text: nil, isAmbiguous: true)
        }

        let inputGuard = ClipboardFallbackInputGuard()
        guard inputGuard.isMonitoring else {
            return ClipboardCopyAttempt(text: nil, isAmbiguous: true)
        }
        defer { inputGuard.stop() }
        let initialInputEpoch = inputGuard.epoch

        if selectAll {
            do {
                guard authorizationCheck() else {
                    return ClipboardCopyAttempt(text: nil, isAmbiguous: true)
                }
                try sendSelectAllCommand(to: target, context: context)
            } catch {
                return ClipboardCopyAttempt(text: nil, isAmbiguous: true)
            }
            try? await Task.sleep(nanoseconds: 120_000_000)
        }

        let copiedSelectionRange = selectedRange(in: context.focusedElement)
        guard inputGuard.epoch == initialInputEpoch,
              clipboardCopyContextIsCurrent(
                  context,
                  selectedRange: copiedSelectionRange,
                  target: target
              ) else {
            return ClipboardCopyAttempt(text: nil, isAmbiguous: true)
        }

        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot.capture()
        let baselineChangeCount = snapshot.changeCountAtCapture
        guard pasteboard.changeCount == baselineChangeCount else {
            return ClipboardCopyAttempt(text: nil, isAmbiguous: true)
        }

        do {
            guard authorizationCheck() else {
                return ClipboardCopyAttempt(text: nil, isAmbiguous: true)
            }
            try sendCopyCommand(to: target, context: context)
        } catch {
            return ClipboardCopyAttempt(text: nil, isAmbiguous: true)
        }

        var observedChangeCount: Int?
        for _ in 0..<24 {
            if Task.isCancelled {
                return ClipboardCopyAttempt(text: nil, isAmbiguous: true)
            }
            try? await Task.sleep(nanoseconds: 25_000_000)
            guard authorizationCheck(),
                  inputGuard.epoch == initialInputEpoch,
                  clipboardCopyContextIsCurrent(
                      context,
                      selectedRange: copiedSelectionRange,
                      target: target
                  ) else {
                return ClipboardCopyAttempt(text: nil, isAmbiguous: true)
            }
            let currentChangeCount = pasteboard.changeCount
            guard currentChangeCount != baselineChangeCount else {
                continue
            }
            observedChangeCount = currentChangeCount
            break
        }

        guard let observedChangeCount else {
            return ClipboardCopyAttempt(text: nil, isAmbiguous: false)
        }
        let copiedValue = pasteboard.string(forType: .string)

        try? await Task.sleep(nanoseconds: 90_000_000)
        let contextIsCurrent = clipboardCopyContextIsCurrent(
            context,
            selectedRange: copiedSelectionRange,
            target: target
        )
        guard authorizationCheck(),
              ClipboardFallbackSafety.canAcceptCopy(
            baselineChangeCount: baselineChangeCount,
            observedChangeCount: observedChangeCount,
            quietChangeCount: pasteboard.changeCount,
            initialInputEpoch: initialInputEpoch,
            currentInputEpoch: inputGuard.epoch,
            contextIsCurrent: contextIsCurrent,
            selectionRangeMatches: selectedRange(in: context.focusedElement) == copiedSelectionRange
        ) else {
            return ClipboardCopyAttempt(text: nil, isAmbiguous: true)
        }

        guard authorizationCheck(),
              ClipboardFallbackSafety.canRestore(
            acceptedChangeCount: observedChangeCount,
            currentChangeCount: pasteboard.changeCount,
            initialInputEpoch: initialInputEpoch,
            currentInputEpoch: inputGuard.epoch,
            contextIsCurrent: clipboardCopyContextIsCurrent(
                context,
                selectedRange: copiedSelectionRange,
                target: target
            ),
            copiedValueStillMatches: pasteboard.string(forType: .string) == copiedValue
        ) else {
            return ClipboardCopyAttempt(text: nil, isAmbiguous: true)
        }

        snapshot.restoreIfChangeCount(is: observedChangeCount)
        return ClipboardCopyAttempt(
            text: copiedValue,
            isAmbiguous: false
        )
    }

    private func clipboardCopyContextIsCurrent(
        _ context: KeyboardInjectionContext,
        selectedRange: NSRange?,
        target: InputTarget
    ) -> Bool {
        guard context.isCurrent(for: target.app),
              !IsSecureEventInputEnabled(),
              !isProtectedElementOrAncestor(context.focusedElement) else {
            return false
        }
        return self.selectedRange(in: context.focusedElement) == selectedRange
    }

    private func pastePreparationContextIsCurrent(
        _ context: KeyboardInjectionContext,
        initialInputEpoch: UInt64,
        inputGuard: ClipboardFallbackInputGuard,
        target: InputTarget
    ) -> Bool {
        ClipboardPasteSafety.canProceed(
            initialInputEpoch: initialInputEpoch,
            currentInputEpoch: inputGuard.epoch,
            contextIsCurrent: context.isCurrent(for: target.app),
            containsProtectedContent: IsSecureEventInputEnabled()
                || isProtectedElementOrAncestor(context.focusedElement),
            selectionRangeMatches: true
        )
    }

    private func pasteContextIsCurrent(
        _ context: KeyboardInjectionContext,
        selectedRange: NSRange,
        initialInputEpoch: UInt64,
        inputGuard: ClipboardFallbackInputGuard,
        target: InputTarget
    ) -> Bool {
        pastePreparationContextIsCurrent(
            context,
            initialInputEpoch: initialInputEpoch,
            inputGuard: inputGuard,
            target: target
        ) && self.selectedRange(in: context.focusedElement) == selectedRange
    }

    private func selectedRange(in element: AXUIElement) -> NSRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &value
        ) == .success,
        let value,
        CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range),
              range.location >= 0,
              range.length >= 0 else {
            return nil
        }
        return NSRange(location: range.location, length: range.length)
    }

    private func isProtectedElementOrAncestor(_ element: AXUIElement) -> Bool {
        var current: AXUIElement? = element
        for _ in 0..<12 {
            guard let candidate = current else { return false }
            if SelectionProtectionClassifier.isProtected(
                role: stringAttribute(kAXRoleAttribute, from: candidate),
                subrole: stringAttribute(kAXSubroleAttribute, from: candidate),
                containsProtectedContent: booleanAttribute(
                    "AXContainsProtectedContent",
                    from: candidate
                )
            ) {
                return true
            }
            current = elementAttribute(kAXParentAttribute, from: candidate)
        }
        return false
    }

    private func stringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success else {
            return nil
        }
        return value as? String
    }

    private func booleanAttribute(_ attribute: String, from element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success else {
            return false
        }
        return (value as? NSNumber)?.boolValue ?? false
    }

    private func elementAttribute(_ attribute: String, from element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success,
        let value,
        CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement)
    }

    private func clipboardSource(
        _ copiedText: String,
        scope: InputReplacementScope
    ) -> InputTranslationSource? {
        guard let normalized = InputTarget.normalizedInputText(copiedText),
              normalized.count <= TranslationLimits.maxInputCharacters,
              InputTarget.isMeaningfulInputText(normalized) else {
            return nil
        }
        return InputTranslationSource(text: normalized, replacementScope: scope)
    }

    private func sendKeyboardCommand(
        keyCode: CGKeyCode,
        to target: InputTarget,
        context: KeyboardInjectionContext
    ) throws {
        guard context.isCurrent(for: target.app) else {
            throw DeliveryError.targetAppChanged
        }
        let source = CGEventSource(stateID: .privateState)
        guard let commandDown = CGEvent(
            keyboardEventSource: source,
            virtualKey: 55,
            keyDown: true
        ),
        let keyDown = CGEvent(
            keyboardEventSource: source,
            virtualKey: keyCode,
            keyDown: true
        ),
        let keyUp = CGEvent(
            keyboardEventSource: source,
            virtualKey: keyCode,
            keyDown: false
        ),
        let commandUp = CGEvent(
            keyboardEventSource: source,
            virtualKey: 55,
            keyDown: false
        ) else {
            throw DeliveryError.targetInputUnavailable
        }

        let events = [commandDown, keyDown, keyUp, commandUp]
        for event in events {
            event.setIntegerValueField(
                .eventSourceUserData,
                value: ClipboardFallbackInputGuard.syntheticCopyEventTag
            )
        }
        commandDown.flags = .maskCommand
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        commandUp.flags = []

        for event in events {
            event.postToPid(context.processIdentifier)
        }
    }

    private func debugLog(_ message: @autoclosure () -> String) {
#if DEBUG
        guard ProcessInfo.processInfo.environment["CPT_DEBUG_DELIVERY"] == "1" else {
            return
        }

        let line = "\(Date()) \(message())\n"
        let url = URL(fileURLWithPath: "/tmp/claude_prompt_translator_delivery_debug.log")
        guard let data = line.data(using: .utf8) else {
            return
        }

        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
#endif
    }
}

struct PasteboardSnapshot {
    private typealias ItemRepresentation = [(NSPasteboard.PasteboardType, Data)]

    private let items: [ItemRepresentation]
    let changeCountAtCapture: Int

    static func capture() -> PasteboardSnapshot {
        let copiedItems = NSPasteboard.general.pasteboardItems?.map { item -> ItemRepresentation in
            var representations: ItemRepresentation = []
            for type in item.types {
                if let data = item.data(forType: type) {
                    representations.append((type, data))
                }
            }
            return representations
        } ?? []
        return PasteboardSnapshot(
            items: copiedItems,
            changeCountAtCapture: NSPasteboard.general.changeCount
        )
    }

    func restoreIfChangeCount(is expectedChangeCount: Int) {
        guard PasteboardOwnershipSafety.canRestore(
            expectedChangeCount: expectedChangeCount,
            currentChangeCount: NSPasteboard.general.changeCount
        ) else {
            return
        }
        restore()
    }

    func restore() {
        NSPasteboard.general.clearContents()
        if !items.isEmpty {
            let pasteboardItems = items.map { representations in
                let item = NSPasteboardItem()
                for (type, data) in representations {
                    item.setData(data, forType: type)
                }
                return item
            }
            NSPasteboard.general.writeObjects(pasteboardItems)
        }
    }
}
