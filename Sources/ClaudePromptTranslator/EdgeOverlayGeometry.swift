import AppKit

enum EdgeOverlayGeometry {
    static func mainWindowRect(
        for app: NSRunningApplication,
        minimumSize: NSSize = NSSize(width: 320, height: 260)
    ) -> NSRect? {
        mainWindowCandidate(for: app, minimumSize: minimumSize)?.rect
    }

    static func mainWindowID(
        for app: NSRunningApplication,
        minimumSize: NSSize = NSSize(width: 320, height: 260)
    ) -> CGWindowID? {
        mainWindowCandidate(for: app, minimumSize: minimumSize)?.id
    }

    static func visibleFrame(around rect: NSRect) -> NSRect {
        NSScreen.screens
            .first(where: { $0.frame.intersects(rect) })?
            .visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
    }

    static func controlOrigin(
        windowRect: NSRect,
        panelSize: NSSize,
        preferredY: CGFloat,
        margin: CGFloat = 14
    ) -> NSPoint {
        let visibleFrame = visibleFrame(around: windowRect)
        let rightSpace = visibleFrame.maxX - windowRect.maxX - margin
        let leftSpace = windowRect.minX - visibleFrame.minX - margin

        let x: CGFloat
        if rightSpace >= panelSize.width {
            x = windowRect.maxX + margin
        } else if leftSpace >= panelSize.width {
            x = windowRect.minX - panelSize.width - margin
        } else {
            x = windowRect.maxX - panelSize.width - 14
        }

        let y = clamp(
            preferredY - panelSize.height / 2,
            min: visibleFrame.minY + 14,
            max: visibleFrame.maxY - panelSize.height - 14
        )

        return NSPoint(x: x, y: y)
    }

    static func cardFrame(
        windowRect: NSRect,
        desiredSize: NSSize,
        preferredY: CGFloat,
        minimumOutsideWidth: CGFloat = 252,
        margin: CGFloat = 12
    ) -> NSRect {
        let visibleFrame = visibleFrame(around: windowRect)
        let rightSpace = visibleFrame.maxX - windowRect.maxX - margin
        let leftSpace = windowRect.minX - visibleFrame.minX - margin

        let width: CGFloat
        let x: CGFloat
        if rightSpace >= minimumOutsideWidth {
            width = min(desiredSize.width, rightSpace)
            x = windowRect.maxX + margin
        } else if leftSpace >= minimumOutsideWidth {
            width = min(desiredSize.width, leftSpace)
            x = windowRect.minX - width - margin
        } else {
            width = min(desiredSize.width, max(300, windowRect.width * 0.32))
            x = windowRect.maxX - width - 16
        }

        let height = min(desiredSize.height, visibleFrame.height - 32)
        let y = clamp(
            preferredY - height / 2,
            min: visibleFrame.minY + 16,
            max: visibleFrame.maxY - height - 16
        )

        return NSRect(x: x, y: y, width: width, height: height)
    }

    static func isMouseNearWindowEdge(
        windowRect: NSRect,
        activeFrames: [NSRect] = [],
        edgeThickness: CGFloat = 86
    ) -> Bool {
        let mouse = NSEvent.mouseLocation
        if activeFrames.contains(where: { $0.insetBy(dx: -18, dy: -18).contains(mouse) }) {
            return true
        }

        let outer = windowRect.insetBy(dx: -edgeThickness, dy: -edgeThickness)
        let inner = windowRect.insetBy(dx: edgeThickness, dy: edgeThickness)
        return outer.contains(mouse) && !inner.contains(mouse)
    }

    private static func clamp(_ value: CGFloat, min minValue: CGFloat, max maxValue: CGFloat) -> CGFloat {
        Swift.min(Swift.max(value, minValue), maxValue)
    }

    private static func mainWindowCandidate(
        for app: NSRunningApplication,
        minimumSize: NSSize
    ) -> (id: CGWindowID, rect: NSRect)? {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }

        // CGWindowListCopyWindowInfo returns windows front-to-back. Keeping
        // that order selects the active window of a multi-window application;
        // choosing the largest window can attach the bar to a background chat.
        return windows.lazy.compactMap { window -> (id: CGWindowID, rect: NSRect)? in
            let ownerPID = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
            let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue
            guard ownerPID == app.processIdentifier, layer == 0 else {
                return nil
            }

            guard let number = (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let x = numberValue(bounds["X"]),
                  let y = numberValue(bounds["Y"]),
                  let width = numberValue(bounds["Width"]),
                  let height = numberValue(bounds["Height"]),
                  width >= minimumSize.width,
                  height >= minimumSize.height else {
                return nil
            }

            let rect = NSRect(x: x, y: y, width: width, height: height)
            return (CGWindowID(number), rect)
        }
        .first
    }

    private static func numberValue(_ value: Any?) -> CGFloat? {
        if let value = value as? CGFloat {
            return value
        }
        if let value = value as? NSNumber {
            return CGFloat(truncating: value)
        }
        if let value = value as? Double {
            return CGFloat(value)
        }
        if let value = value as? Int {
            return CGFloat(value)
        }
        return nil
    }
}
