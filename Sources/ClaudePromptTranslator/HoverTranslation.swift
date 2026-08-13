import AppKit
import ApplicationServices
import CoreGraphics

enum PassiveTextEligibility {
    static func normalizedCandidate(
        _ rawText: String,
        minimumLetters: Int = 2,
        maximumCharacters: Int = 1_600
    ) -> String? {
        let normalized = rawText
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalized.isEmpty,
              normalized.count <= maximumCharacters,
              !ResponseLanguageDetector.isSkippableLiteral(normalized) else {
            return nil
        }

        let lowercased = normalized.lowercased()
        let looksLikeLocalPath = normalized.hasPrefix("/")
            || normalized.hasPrefix("~/")
            || lowercased.hasPrefix("file://")
            || (normalized.count >= 3
                && normalized[normalized.index(after: normalized.startIndex)] == ":"
                && normalized.dropFirst(2).first.map { $0 == "\\" || $0 == "/" } == true)
        guard !looksLikeLocalPath else {
            return nil
        }

        let letters = normalized.unicodeScalars.reduce(into: 0) { count, scalar in
            if CharacterSet.letters.contains(scalar) {
                count += 1
            }
        }
        guard letters >= minimumLetters else {
            return nil
        }

        let compact = normalized.filter { !$0.isWhitespace }
        guard !compact.isEmpty,
              compact.contains(where: { $0.isLetter }) else {
            return nil
        }
        return normalized
    }
}

enum HoverTextSnippet {
    static func around(
        utf16Location: Int?,
        in text: String,
        maximumCharacters: Int = 420
    ) -> String {
        guard text.count > maximumCharacters else {
            return text
        }

        let nsText = text as NSString
        let safeLocation = min(max(utf16Location ?? 0, 0), max(nsText.length - 1, 0))
        let paragraph = nsText.paragraphRange(for: NSRange(location: safeLocation, length: 0))
        let paragraphText = nsText.substring(with: paragraph)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !paragraphText.isEmpty, paragraphText.count <= maximumCharacters {
            return paragraphText
        }

        let halfWindow = maximumCharacters / 2
        let start = max(0, safeLocation - halfWindow)
        let length = min(maximumCharacters, nsText.length - start)
        return nsText.substring(with: NSRange(location: start, length: length))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum HoverEventDeliveryPolicy {
    static let maximumDeliveriesPerSecond: Double = 10

    static func nextDelay(
        lastDeliveryUptime: TimeInterval,
        currentUptime: TimeInterval,
        maximumDeliveriesPerSecond: Double = maximumDeliveriesPerSecond
    ) -> TimeInterval {
        let boundedRate = max(1, maximumDeliveriesPerSecond)
        let minimumInterval = 1 / boundedRate
        guard lastDeliveryUptime.isFinite else { return 0 }
        return max(0, minimumInterval - max(0, currentUptime - lastDeliveryUptime))
    }
}

/// Coalesces raw mouse movement off the main actor and always delivers the most
/// recent point. At most one trailing main-queue work item is pending.
final class HoverEventCoalescer: @unchecked Sendable {
    typealias Delivery = @MainActor @Sendable (CGPoint) -> Void

    private let lock = NSLock()
    private let maximumDeliveriesPerSecond: Double
    private var lastDeliveryUptime = -TimeInterval.infinity
    private var pendingPoint: CGPoint?
    private var pendingWorkItem: DispatchWorkItem?
    private var generation: UInt64 = 0
    private var acceptsEvents = true

    init(maximumDeliveriesPerSecond: Double = HoverEventDeliveryPolicy.maximumDeliveriesPerSecond) {
        self.maximumDeliveriesPerSecond = max(1, maximumDeliveriesPerSecond)
    }

    func submit(
        _ point: CGPoint,
        currentUptime: TimeInterval = ProcessInfo.processInfo.systemUptime,
        deliver: @escaping Delivery
    ) {
        lock.lock()
        guard acceptsEvents else {
            lock.unlock()
            return
        }
        pendingPoint = point
        guard pendingWorkItem == nil else {
            lock.unlock()
            return
        }

        let delay = HoverEventDeliveryPolicy.nextDelay(
            lastDeliveryUptime: lastDeliveryUptime,
            currentUptime: currentUptime,
            maximumDeliveriesPerSecond: maximumDeliveriesPerSecond
        )
        generation &+= 1
        let ticket = generation
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  let latestPoint = self.takePendingPoint(ticket: ticket) else {
                return
            }
            MainActor.assumeIsolated {
                deliver(latestPoint)
            }
        }
        pendingWorkItem = workItem
        lock.unlock()

        if delay == 0 {
            DispatchQueue.main.async(execute: workItem)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }
    }

    func cancel() {
        lock.lock()
        acceptsEvents = false
        generation &+= 1
        pendingWorkItem?.cancel()
        pendingWorkItem = nil
        pendingPoint = nil
        lastDeliveryUptime = -.infinity
        lock.unlock()
    }

    func resume() {
        lock.lock()
        acceptsEvents = true
        generation &+= 1
        pendingWorkItem?.cancel()
        pendingWorkItem = nil
        pendingPoint = nil
        lastDeliveryUptime = -.infinity
        lock.unlock()
    }

    private func takePendingPoint(ticket: UInt64) -> CGPoint? {
        lock.lock()
        defer { lock.unlock() }
        guard generation == ticket,
              pendingWorkItem?.isCancelled == false,
              let pendingPoint else {
            return nil
        }
        self.pendingPoint = nil
        pendingWorkItem = nil
        lastDeliveryUptime = ProcessInfo.processInfo.systemUptime
        return pendingPoint
    }
}

@MainActor
final class HoverTranslationMonitor {
    typealias Handler = @MainActor (NSRunningApplication, CGPoint) -> Void

    private let handler: Handler
    private var eventMonitor: Any?
    private let eventCoalescer = HoverEventCoalescer()
    private let dwellSlot = TaskSlot<CGPoint>()
    private var lastQuartzPoint: CGPoint?

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    var isRunning: Bool { eventMonitor != nil }

    func start() {
        guard eventMonitor == nil else { return }
        let eventCoalescer = self.eventCoalescer
        eventCoalescer.resume()
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            guard let quartzPoint = event.cgEvent?.location else { return }
            eventCoalescer.submit(quartzPoint) { [weak self] quartzPoint in
                self?.scheduleInspection(at: quartzPoint)
            }
        }
    }

    func stop() {
        eventCoalescer.cancel()
        dwellSlot.cancel()
        lastQuartzPoint = nil
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
        eventMonitor = nil
    }

    private func scheduleInspection(at point: CGPoint) {
        if let previous = lastQuartzPoint,
           hypot(previous.x - point.x, previous.y - point.y) < 4 {
            return
        }
        lastQuartzPoint = point
        dwellSlot.replace(operation: {
            try? await Task.sleep(nanoseconds: 650_000_000)
            return point
        }, deliver: { [weak self] deliveredPoint in
            guard let self,
                  let app = NSWorkspace.shared.frontmostApplication,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
                return
            }
            handler(app, deliveredPoint)
        })
    }
}

@MainActor
struct HoverTextReader {
    func capture(
        from app: NSRunningApplication,
        at quartzPoint: CGPoint
    ) -> UniversalTextSelection? {
        guard AccessibilityPermission.isTrusted,
              !app.isTerminated else {
            return nil
        }

        let applicationElement = AXUIElementCreateApplication(app.processIdentifier)
        var hitElement: AXUIElement?
        guard AXUIElementCopyElementAtPosition(
            applicationElement,
            Float(quartzPoint.x),
            Float(quartzPoint.y),
            &hitElement
        ) == .success,
        let hitElement,
        !isProtectedElementOrAncestor(hitElement),
        isReadableDisplayRole(hitElement) else {
            return nil
        }

        let rawValue = stringAttribute(kAXValueAttribute, from: hitElement)
            ?? stringAttribute(kAXDescriptionAttribute, from: hitElement)
            ?? stringAttribute(kAXTitleAttribute, from: hitElement)
        guard let rawValue else { return nil }

        let positionRange = rangeForPosition(quartzPoint, in: hitElement)
        let snippet = HoverTextSnippet.around(
            utf16Location: positionRange?.location,
            in: rawValue
        )
        guard let text = PassiveTextEligibility.normalizedCandidate(snippet) else {
            return nil
        }

        let anchor = appKitRect(for: quartzPoint)
        return UniversalTextSelection(
            app: app,
            rawText: text,
            text: text,
            captureMethod: .hoverAccessibility,
            anchorRect: anchor,
            element: nil,
            selectedRange: nil
        )
    }

    private func isReadableDisplayRole(_ element: AXUIElement) -> Bool {
        let role = stringAttribute(kAXRoleAttribute, from: element) ?? ""
        let subrole = stringAttribute(kAXSubroleAttribute, from: element) ?? ""
        let rejected = ["textfield", "textarea", "searchfield", "secure", "password"]
        let joined = (role + " " + subrole).lowercased()
        guard !rejected.contains(where: joined.contains) else {
            return false
        }
        return role == (kAXStaticTextRole as String)
            || role == (kAXHeadingRole as String)
            || role == "AXLink"
    }

    private func rangeForPosition(_ point: CGPoint, in element: AXUIElement) -> NSRange? {
        var mutablePoint = point
        guard let parameter = AXValueCreate(.cgPoint, &mutablePoint) else {
            return nil
        }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXRangeForPositionParameterizedAttribute as CFString,
            parameter,
            &value
        ) == .success,
        let value,
        CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range),
              range.location >= 0 else {
            return nil
        }
        return NSRange(location: range.location, length: max(range.length, 0))
    }

    private func appKitRect(for quartzPoint: CGPoint) -> NSRect? {
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                    as? NSNumber else {
                continue
            }
            let bounds = CGDisplayBounds(CGDirectDisplayID(number.uint32Value))
            guard bounds.contains(quartzPoint) else { continue }
            let appKitPoint = NSPoint(
                x: screen.frame.minX + quartzPoint.x - bounds.minX,
                y: screen.frame.maxY - (quartzPoint.y - bounds.minY)
            )
            return NSRect(x: appKitPoint.x - 2, y: appKitPoint.y - 2, width: 4, height: 4)
        }
        return nil
    }

    private func isProtectedElementOrAncestor(_ element: AXUIElement) -> Bool {
        var current: AXUIElement? = element
        for _ in 0..<12 {
            guard let candidate = current else { return false }
            if SelectionProtectionClassifier.isProtected(
                role: stringAttribute(kAXRoleAttribute, from: candidate),
                subrole: stringAttribute(kAXSubroleAttribute, from: candidate),
                containsProtectedContent: booleanAttribute("AXContainsProtectedContent", from: candidate)
            ) {
                return true
            }
            current = elementAttribute(kAXParentAttribute, from: candidate)
        }
        return false
    }

    private func stringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private func booleanAttribute(_ attribute: String, from element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return false
        }
        return (value as? NSNumber)?.boolValue ?? false
    }

    private func elementAttribute(_ attribute: String, from element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement)
    }
}
