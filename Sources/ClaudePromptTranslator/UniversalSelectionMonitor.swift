import AppKit
import ApplicationServices

enum SelectionMonitorEventPolicy {
    static let minimumDragDistance: CGFloat = 3

    private static let selectionExtendingKeyCodes: Set<UInt16> = [
        115, // Home
        116, // Page Up
        119, // End
        121, // Page Down
        123, // Left Arrow
        124, // Right Arrow
        125, // Down Arrow
        126  // Up Arrow
    ]

    static func shouldDispatchKeyUp(
        keyCode: UInt16,
        shiftPressed: Bool,
        commandPressed: Bool
    ) -> Bool {
        (commandPressed && keyCode == 0) // Command-A
            || (shiftPressed && selectionExtendingKeyCodes.contains(keyCode))
    }

    static func shouldInspectMouseUp(
        dragStart: CGPoint?,
        dragEnd: CGPoint?,
        clickCount: Int,
        extendsExistingSelection: Bool = false,
        minimumDragDistance: CGFloat = minimumDragDistance
    ) -> Bool {
        if clickCount >= 2 || extendsExistingSelection {
            return true
        }
        guard let dragStart, let dragEnd else {
            return false
        }
        return hypot(dragEnd.x - dragStart.x, dragEnd.y - dragStart.y)
            >= max(0, minimumDragDistance)
    }

    static func pointIsInsideHelperWindow(
        quartzPoint: CGPoint,
        helperWindowFrames: [NSRect],
        screenMaxY: CGFloat
    ) -> Bool {
        let appKitPoint = NSPoint(
            x: quartzPoint.x,
            y: screenMaxY - quartzPoint.y
        )
        return helperWindowFrames.contains { $0.contains(appKitPoint) }
    }
}

enum SelectionMonitorPrivacyPolicy {
    static func shouldObserve(
        isHelperApplication: Bool,
        isTerminated: Bool,
        accessibilityTrusted: Bool,
        applicationAllowed: Bool
    ) -> Bool {
        !isHelperApplication
            && !isTerminated
            && accessibilityTrusted
            && applicationAllowed
    }
}

private final class RetainedSelectionAXElement: @unchecked Sendable {
    let value: AXUIElement

    init(_ value: AXUIElement) {
        self.value = value
    }
}

private let universalSelectionAXCallback: AXObserverCallback = {
    _, element, notification, reference in
    guard let reference else { return }
    let monitor = Unmanaged<UniversalSelectionMonitor>
        .fromOpaque(reference)
        .takeUnretainedValue()
    let notificationName = notification as String
    let retainedElement = RetainedSelectionAXElement(element)
    DispatchQueue.main.async {
        monitor.handleAccessibilityNotification(
            notificationName,
            sourceElement: retainedElement.value
        )
    }
}

private let universalSelectionEventTapCallback: CGEventTapCallBack = {
    _, type, event, reference in
    guard let reference else {
        return Unmanaged.passUnretained(event)
    }
    let monitor = Unmanaged<UniversalSelectionMonitor>
        .fromOpaque(reference)
        .takeUnretainedValue()
    let flags = event.flags
    let keyCode = CGKeyCode(
        event.getIntegerValueField(.keyboardEventKeycode)
    )
    if type == .keyUp,
       !SelectionMonitorEventPolicy.shouldDispatchKeyUp(
           keyCode: UInt16(keyCode),
           shiftPressed: flags.contains(.maskShift),
           commandPressed: flags.contains(.maskCommand)
       ) {
        return Unmanaged.passUnretained(event)
    }
    let location = event.location
    let clickCount = Int(event.getIntegerValueField(.mouseEventClickState))
    DispatchQueue.main.async {
        monitor.handleEventTapEvent(
            type: type,
            location: location,
            flags: flags,
            keyCode: keyCode,
            clickCount: clickCount
        )
    }
    return Unmanaged.passUnretained(event)
}

/// Event-driven selection monitoring for the active application.
///
/// Accessibility notifications are the primary path. A global mouse/key monitor
/// remains as a compatibility fallback for web views that do not emit
/// `AXSelectedTextChanged`. Neither path reads the clipboard or synthesizes input.
@MainActor
final class UniversalSelectionMonitor {
    typealias Handler = @MainActor (NSRunningApplication, SelectionCaptureHints) -> Void
    typealias ApplicationAllowed = @MainActor (NSRunningApplication) -> Bool

    private let handler: Handler
    private let isApplicationAllowed: ApplicationAllowed
    private var eventMonitor: Any?
    private var eventTap: CFMachPort?
    private var eventTapRunLoopSource: CFRunLoopSource?
    private var activationObserver: NSObjectProtocol?
    private var accessibilityObserver: AXObserver?
    private var observedApplicationElement: AXUIElement?
    private var observedFocusedElement: AXUIElement?
    private var observedProcessIdentifier: pid_t?
    private let debounceSlot = TaskSlot<pid_t>()
    private var pendingProcessIdentifier: pid_t?
    private var pendingSourceElement: AXUIElement?
    private var pendingPointerQuartzPoint: CGPoint?
    private var pendingDragStartQuartzPoint: CGPoint?
    private var pendingDragEndQuartzPoint: CGPoint?
    private var activeDragStartQuartzPoint: CGPoint?
    private var started = false

    init(
        isApplicationAllowed: @escaping ApplicationAllowed,
        handler: @escaping Handler
    ) {
        self.isApplicationAllowed = isApplicationAllowed
        self.handler = handler
    }

    var isRunning: Bool {
        started
    }

    func ownsAccessibilityObserver(for processIdentifier: pid_t) -> Bool {
        started
            && accessibilityObserver != nil
            && observedProcessIdentifier == processIdentifier
    }

    func start() {
        guard !started else {
            return
        }
        started = true
        AccessibilityMessagingPolicy.configureIfNeeded()

        if !installReadOnlyEventTap() {
            eventMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .leftMouseUp, .keyUp]
            ) { [weak self] event in
                if event.type == .keyUp,
                   !SelectionMonitorEventPolicy.shouldDispatchKeyUp(
                       keyCode: event.keyCode,
                       shiftPressed: event.modifierFlags.contains(.shift),
                       commandPressed: event.modifierFlags.contains(.command)
                   ) {
                    return
                }
                self?.handleGlobalEvent(event)
            }
        }

        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication else {
                return
            }
            Task { @MainActor in
                self?.observe(app)
            }
        }

        if let app = NSWorkspace.shared.frontmostApplication {
            observe(app)
        }
    }

    private func installReadOnlyEventTap() -> Bool {
        let mask = CGEventMask(1 << CGEventType.leftMouseDown.rawValue)
            | CGEventMask(1 << CGEventType.leftMouseUp.rawValue)
            | CGEventMask(1 << CGEventType.keyUp.rawValue)
        guard let newTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: universalSelectionEventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            SelectionDiagnostics.record("read-only event tap unavailable; using NSEvent fallback")
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0)
        eventTap = newTap
        eventTapRunLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)
        SelectionDiagnostics.record("read-only event tap installed")
        return true
    }

    private func handleGlobalEvent(_ event: NSEvent) {
        guard started else { return }
        handleSelectionEvent(
            type: event.type,
            pointerQuartzPoint: event.cgEvent?.location,
            modifierFlags: event.modifierFlags,
            keyCode: event.keyCode,
            clickCount: event.clickCount
        )
    }

    fileprivate func handleEventTapEvent(
        type: CGEventType,
        location: CGPoint,
        flags: CGEventFlags,
        keyCode: CGKeyCode,
        clickCount: Int
    ) {
        guard started else { return }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return
        }
        let eventType: NSEvent.EventType
        switch type {
        case .leftMouseDown:
            eventType = .leftMouseDown
        case .leftMouseUp:
            eventType = .leftMouseUp
        case .keyUp:
            eventType = .keyUp
        default:
            return
        }
        var modifierFlags = NSEvent.ModifierFlags()
        if flags.contains(.maskShift) {
            modifierFlags.insert(.shift)
        }
        if flags.contains(.maskCommand) {
            modifierFlags.insert(.command)
        }
        handleSelectionEvent(
            type: eventType,
            pointerQuartzPoint: eventType == .keyUp ? nil : location,
            modifierFlags: modifierFlags,
            keyCode: UInt16(keyCode),
            clickCount: clickCount
        )
    }

    private func handleSelectionEvent(
        type: NSEvent.EventType,
        pointerQuartzPoint: CGPoint?,
        modifierFlags: NSEvent.ModifierFlags,
        keyCode: UInt16,
        clickCount: Int
    ) {
        let shouldInspect: Bool
        let dragStartQuartzPoint: CGPoint?
        switch type {
        case .leftMouseDown:
            activeDragStartQuartzPoint = pointerQuartzPoint
            return
        case .leftMouseUp:
            dragStartQuartzPoint = activeDragStartQuartzPoint
            activeDragStartQuartzPoint = nil
            shouldInspect = SelectionMonitorEventPolicy.shouldInspectMouseUp(
                dragStart: dragStartQuartzPoint,
                dragEnd: pointerQuartzPoint,
                clickCount: clickCount,
                extendsExistingSelection: modifierFlags.contains(.shift)
            )
        case .keyUp:
            dragStartQuartzPoint = nil
            shouldInspect = SelectionMonitorEventPolicy.shouldDispatchKeyUp(
                keyCode: keyCode,
                shiftPressed: modifierFlags.contains(.shift),
                commandPressed: modifierFlags.contains(.command)
            )
        default:
            dragStartQuartzPoint = nil
            shouldInspect = false
        }

        guard shouldInspect else {
            return
        }
        SelectionDiagnostics.record("global event received type=\(type.rawValue)")
        let releasePoint = type == .leftMouseUp ? pointerQuartzPoint : nil
        if let releasePoint,
           pointIsInsideHelperWindow(releasePoint) {
                // Clicking the nonactivating edge bar must not cancel the
                // selection inspection scheduled by the source mouse-up.
                SelectionDiagnostics.record("helper mouse-up ignored")
                return
        }
        guard let app = NSWorkspace.shared.frontmostApplication,
              isApplicationAllowed(app) else { return }
        scheduleInspection(
            for: app,
            sourceElement: nil,
            pointerQuartzPoint: releasePoint,
            dragStartQuartzPoint: dragStartQuartzPoint,
            dragEndQuartzPoint: releasePoint
        )
    }

    private func pointIsInsideHelperWindow(_ quartzPoint: CGPoint) -> Bool {
        let helperWindowFrames = NSApp.windows
            .filter { window in
                window.isVisible
                    && window.isOnActiveSpace
                    && (window is NSPanel || window.level.rawValue > NSWindow.Level.normal.rawValue)
            }
            .map(\.frame)
        let screenMaxY = NSScreen.screens.map(\.frame.maxY).max()
            ?? NSScreen.main?.frame.maxY
            ?? quartzPoint.y
        return SelectionMonitorEventPolicy.pointIsInsideHelperWindow(
            quartzPoint: quartzPoint,
            helperWindowFrames: helperWindowFrames,
            screenMaxY: screenMaxY
        )
    }

    func stop() {
        started = false
        debounceSlot.cancel()
        activeDragStartQuartzPoint = nil
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
        eventMonitor = nil
        if let eventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapRunLoopSource, .commonModes)
        }
        eventTapRunLoopSource = nil
        if let eventTap {
            CFMachPortInvalidate(eventTap)
        }
        eventTap = nil
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        activationObserver = nil
        clearPendingInspection()
        removeAccessibilityObserver()
    }

    func refreshPrivacyPolicy() {
        if let processIdentifier = observedProcessIdentifier,
           let observedApp = NSRunningApplication(processIdentifier: processIdentifier),
           !isApplicationAllowed(observedApp) {
            removeAccessibilityObserver()
        }
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              isApplicationAllowed(frontmost) else {
            return
        }
        observe(frontmost)
    }

    fileprivate func handleAccessibilityNotification(
        _ notification: String,
        sourceElement: AXUIElement
    ) {
        guard started else { return }
        guard let processIdentifier = observedProcessIdentifier,
              let app = NSRunningApplication(processIdentifier: processIdentifier),
              isApplicationAllowed(app) else {
            removeAccessibilityObserver()
            return
        }

        SelectionDiagnostics.record("ax notification received name=\(notification)")
        if notification == (kAXFocusedUIElementChangedNotification as String) {
            refreshFocusedElementNotification()
        }
        scheduleInspection(
            for: app,
            sourceElement: notification == (kAXSelectedTextChangedNotification as String)
                ? sourceElement
                : nil,
            pointerQuartzPoint: nil
        )
    }

    private func observe(_ app: NSRunningApplication) {
        guard SelectionMonitorPrivacyPolicy.shouldObserve(
            isHelperApplication: app.processIdentifier == ProcessInfo.processInfo.processIdentifier,
            isTerminated: app.isTerminated,
            accessibilityTrusted: AccessibilityPermission.isTrusted,
            applicationAllowed: isApplicationAllowed(app)
        ) else {
            removeAccessibilityObserver()
            return
        }
        if observedProcessIdentifier == app.processIdentifier,
           accessibilityObserver != nil {
            refreshFocusedElementNotification()
            return
        }

        removeAccessibilityObserver()
        var newObserver: AXObserver?
        guard AXObserverCreate(
            app.processIdentifier,
            universalSelectionAXCallback,
            &newObserver
        ) == .success,
        let newObserver else {
            SelectionDiagnostics.record(
                "ax observer unavailable app=\(app.bundleIdentifier ?? "unknown")"
            )
            return
        }

        let applicationElement = AXUIElementCreateApplication(app.processIdentifier)
        let reference = Unmanaged.passUnretained(self).toOpaque()
        accessibilityObserver = newObserver
        observedApplicationElement = applicationElement
        observedProcessIdentifier = app.processIdentifier

        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(newObserver),
            .commonModes
        )
        _ = AXObserverAddNotification(
            newObserver,
            applicationElement,
            kAXFocusedUIElementChangedNotification as CFString,
            reference
        )
        _ = AXObserverAddNotification(
            newObserver,
            applicationElement,
            kAXSelectedTextChangedNotification as CFString,
            reference
        )
        refreshFocusedElementNotification()
        SelectionDiagnostics.record(
            "ax observer installed app=\(app.bundleIdentifier ?? "unknown")"
        )
    }

    private func refreshFocusedElementNotification() {
        guard let accessibilityObserver,
              let observedApplicationElement else {
            return
        }
        let reference = Unmanaged.passUnretained(self).toOpaque()

        let nextFocusedElement = elementAttribute(
            kAXFocusedUIElementAttribute,
            from: observedApplicationElement
        )
        if let observedFocusedElement,
           let nextFocusedElement,
           CFEqual(observedFocusedElement, nextFocusedElement) {
            return
        }

        if let observedFocusedElement {
            _ = AXObserverRemoveNotification(
                accessibilityObserver,
                observedFocusedElement,
                kAXSelectedTextChangedNotification as CFString
            )
        }
        observedFocusedElement = nextFocusedElement
        if let observedFocusedElement {
            _ = AXObserverAddNotification(
                accessibilityObserver,
                observedFocusedElement,
                kAXSelectedTextChangedNotification as CFString,
                reference
            )
        }
    }

    private func removeAccessibilityObserver() {
        debounceSlot.cancel()
        if let accessibilityObserver {
            if let observedFocusedElement {
                _ = AXObserverRemoveNotification(
                    accessibilityObserver,
                    observedFocusedElement,
                    kAXSelectedTextChangedNotification as CFString
                )
            }
            if let observedApplicationElement {
                _ = AXObserverRemoveNotification(
                    accessibilityObserver,
                    observedApplicationElement,
                    kAXFocusedUIElementChangedNotification as CFString
                )
                _ = AXObserverRemoveNotification(
                    accessibilityObserver,
                    observedApplicationElement,
                    kAXSelectedTextChangedNotification as CFString
                )
            }
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(accessibilityObserver),
                .commonModes
            )
        }
        accessibilityObserver = nil
        observedApplicationElement = nil
        observedFocusedElement = nil
        observedProcessIdentifier = nil
        clearPendingInspection()
    }

    private func scheduleInspection(
        for app: NSRunningApplication,
        sourceElement: AXUIElement?,
        pointerQuartzPoint: CGPoint?,
        dragStartQuartzPoint: CGPoint? = nil,
        dragEndQuartzPoint: CGPoint? = nil
    ) {
        guard isApplicationAllowed(app) else {
            if observedProcessIdentifier == app.processIdentifier {
                removeAccessibilityObserver()
            }
            return
        }
        let processIdentifier = app.processIdentifier
        if pendingProcessIdentifier != processIdentifier {
            clearPendingInspection()
            pendingProcessIdentifier = processIdentifier
        }
        if let sourceElement, elementBelongsToProcess(sourceElement, processIdentifier) {
            pendingSourceElement = sourceElement
        }
        if let pointerQuartzPoint {
            pendingPointerQuartzPoint = pointerQuartzPoint
        }
        if let dragStartQuartzPoint {
            pendingDragStartQuartzPoint = dragStartQuartzPoint
        }
        if let dragEndQuartzPoint {
            pendingDragEndQuartzPoint = dragEndQuartzPoint
        }
        SelectionDiagnostics.record(
            "inspection scheduled app=\(app.bundleIdentifier ?? "unknown")"
        )

        debounceSlot.replace(operation: {
            try? await Task.sleep(nanoseconds: 180_000_000)
            return processIdentifier
        }, deliver: { [weak self] deliveredProcessIdentifier in
            guard let self else { return }
            guard let currentApp = NSRunningApplication(
                    processIdentifier: deliveredProcessIdentifier
                  ),
                  isApplicationAllowed(currentApp),
                  NSWorkspace.shared.frontmostApplication?.processIdentifier
                    == deliveredProcessIdentifier else {
                clearPendingInspection()
                return
            }
            SelectionDiagnostics.record(
                "inspection dispatched app=\(currentApp.bundleIdentifier ?? "unknown")"
            )
            let hints = SelectionCaptureHints(
                sourceElement: pendingSourceElement,
                pointerQuartzPoint: pendingPointerQuartzPoint,
                dragStartQuartzPoint: pendingDragStartQuartzPoint,
                dragEndQuartzPoint: pendingDragEndQuartzPoint
            )
            clearPendingInspection()
            handler(currentApp, hints)
        })
    }

    private func clearPendingInspection() {
        pendingProcessIdentifier = nil
        pendingSourceElement = nil
        pendingPointerQuartzPoint = nil
        pendingDragStartQuartzPoint = nil
        pendingDragEndQuartzPoint = nil
    }

    private func elementBelongsToProcess(_ element: AXUIElement, _ processIdentifier: pid_t) -> Bool {
        var elementProcessIdentifier: pid_t = 0
        return AXUIElementGetPid(element, &elementProcessIdentifier) == .success
            && elementProcessIdentifier == processIdentifier
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
}
