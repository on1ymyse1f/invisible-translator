import AppKit
import CoreGraphics
import ScreenCaptureKit
import Vision

struct ScreenRegionSelection: Equatable, Sendable {
    let displayID: CGDirectDisplayID
    let screenFrame: CGRect
    let appKitRect: CGRect

    var sourceRect: CGRect {
        CGRect(
            x: appKitRect.minX - screenFrame.minX,
            y: screenFrame.maxY - appKitRect.maxY,
            width: appKitRect.width,
            height: appKitRect.height
        ).integral
    }

    static func frontmostWindow(of app: NSRunningApplication) -> ScreenRegionSelection? {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }
        let candidates = windowList.compactMap { item -> CGRect? in
            guard (item[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
                    == app.processIdentifier,
                  (item[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let bounds = item[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds),
                  rect.width >= 120,
                  rect.height >= 80 else {
                return nil
            }
            return rect
        }
        guard let windowRect = candidates.max(by: {
            $0.width * $0.height < $1.width * $1.height
        }) else {
            return nil
        }

        var best: (screen: NSScreen, displayID: CGDirectDisplayID, quartzBounds: CGRect, overlap: CGRect)?
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                    as? NSNumber else { continue }
            let displayID = CGDirectDisplayID(number.uint32Value)
            let quartzBounds = CGDisplayBounds(displayID)
            let overlap = windowRect.intersection(quartzBounds)
            guard !overlap.isNull,
                  overlap.width * overlap.height > (best?.overlap.width ?? 0) * (best?.overlap.height ?? 0) else {
                continue
            }
            best = (screen, displayID, quartzBounds, overlap)
        }
        guard let best else { return nil }
        let appKitRect = CGRect(
            x: best.screen.frame.minX + best.overlap.minX - best.quartzBounds.minX,
            y: best.screen.frame.maxY - (best.overlap.maxY - best.quartzBounds.minY),
            width: best.overlap.width,
            height: best.overlap.height
        ).insetBy(dx: 2, dy: 2)
        return ScreenRegionSelection(
            displayID: best.displayID,
            screenFrame: best.screen.frame,
            appKitRect: appKitRect
        )
    }
}

struct ScreenTextOCRResult: Equatable, Sendable {
    let text: String
    let lineCount: Int
    let averageConfidence: Float
}

enum ScreenTextOCRError: LocalizedError {
    case screenRecordingPermissionRequired
    case displayUnavailable
    case selectionTooSmall
    case selectionOutsideSourceApplication
    case noTextRecognized

    var errorDescription: String? {
        switch self {
        case .screenRecordingPermissionRequired:
            return "区域 OCR 需要屏幕录制权限；只截取你框选的区域。"
        case .displayUnavailable:
            return "无法读取所选显示器，请重新框选。"
        case .selectionTooSmall:
            return "框选区域太小，请至少覆盖一行完整文字。"
        case .selectionOutsideSourceApplication:
            return "框选区域未覆盖启动 OCR 的来源 App 窗口；为保护其他 App，已拒绝截取。"
        case .noTextRecognized:
            return "所选区域没有识别到可翻译文字。"
        }
    }
}

enum ScreenRegionSourceWindowPolicy {
    static func intersectsSourceWindow(
        sourceRect: CGRect,
        displayFrame: CGRect,
        sourceWindowFrames: [CGRect]
    ) -> Bool {
        let selectedGlobalRect = CGRect(
            x: displayFrame.minX + sourceRect.minX,
            y: displayFrame.minY + sourceRect.minY,
            width: sourceRect.width,
            height: sourceRect.height
        )
        return sourceWindowFrames.contains { windowFrame in
            let overlap = selectedGlobalRect.intersection(windowFrame)
            return !overlap.isNull && overlap.width >= 4 && overlap.height >= 4
        }
    }
}

enum ScreenTextOCRRecognizer {
    static func recognize(in image: CGImage) throws -> ScreenTextOCRResult {
        let automatic = perform(in: image, recognitionLanguages: nil)
        let best: OCRPass
        if automatic.lines.isEmpty || automatic.averageConfidence < 0.58 {
            let detectedIdentifier = SelectionLanguageRouter.detectedLanguageIdentifier(
                in: automatic.lines.map(\.text).joined(separator: "\n")
            )
            let multilingual = perform(
                in: image,
                recognitionLanguages: preferredRecognitionLanguages(for: detectedIdentifier)
            )
            best = score(multilingual) > score(automatic) ? multilingual : automatic
        } else {
            best = automatic
        }

        let text = render(lines: best.lines)
        guard let normalized = SelectionTextNormalizer.normalizedText(
            from: text,
            maximumCharacters: TranslationLimits.maxOCRCharacters
        ) else {
            throw ScreenTextOCRError.noTextRecognized
        }
        return ScreenTextOCRResult(
            text: normalized,
            lineCount: best.lines.count,
            averageConfidence: best.averageConfidence
        )
    }

    private struct OCRLine {
        let text: String
        let confidence: Float
        let boundingBox: CGRect
    }

    private struct OCRPass {
        let lines: [OCRLine]

        var averageConfidence: Float {
            guard !lines.isEmpty else { return 0 }
            return lines.reduce(0) { $0 + $1.confidence } / Float(lines.count)
        }
    }

    private static func score(_ pass: OCRPass) -> Float {
        pass.averageConfidence + min(Float(pass.lines.count), 16) * 0.01
    }

    private static func preferredRecognitionLanguages(for identifier: String) -> [String] {
        let normalized = identifier.lowercased()
        if normalized.hasPrefix("zh-hant") { return ["zh-Hant"] }
        if normalized.hasPrefix("zh") { return ["zh-Hans"] }
        if normalized.hasPrefix("ja") { return ["ja-JP"] }
        if normalized.hasPrefix("ko") { return ["ko-KR"] }
        if normalized.hasPrefix("en") { return ["en-US"] }
        return ["en-US"]
    }

    private static func perform(
        in image: CGImage,
        recognitionLanguages: [String]?
    ) -> OCRPass {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.minimumTextHeight = 0.012
        if let recognitionLanguages {
            request.automaticallyDetectsLanguage = false
            request.recognitionLanguages = recognitionLanguages
        } else {
            request.automaticallyDetectsLanguage = true
        }

        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            return OCRPass(lines: [])
        }

        let lines = (request.results ?? []).compactMap { observation -> OCRLine? in
            guard let candidate = observation.topCandidates(1).first,
                  candidate.confidence >= 0.35 else {
                return nil
            }
            let text = candidate.string
                .replacingOccurrences(of: "\u{00A0}", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return OCRLine(
                text: text,
                confidence: candidate.confidence,
                boundingBox: observation.boundingBox
            )
        }
        return OCRPass(lines: lines)
    }

    private static func render(lines: [OCRLine]) -> String {
        let sorted = lines.sorted { lhs, rhs in
            if abs(lhs.boundingBox.midY - rhs.boundingBox.midY) > 0.018 {
                return lhs.boundingBox.maxY > rhs.boundingBox.maxY
            }
            return lhs.boundingBox.minX < rhs.boundingBox.minX
        }
        return sorted.map(\.text).joined(separator: "\n")
    }
}

private struct SendableCGImage: @unchecked Sendable {
    let value: CGImage
}

@MainActor
struct ScreenRegionOCRService {
    func recognize(
        region: ScreenRegionSelection,
        sourceApplication: NSRunningApplication,
        authorizationCheck: @MainActor () -> Bool
    ) async throws -> ScreenTextOCRResult {
        guard authorizationCheck() else { throw CancellationError() }
        let image = try await capture(
            region: region,
            sourceApplication: sourceApplication,
            authorizationCheck: authorizationCheck
        )
        try Task.checkCancellation()
        guard authorizationCheck() else { throw CancellationError() }
        let sendableImage = SendableCGImage(value: image)
        let recognitionTask = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try ScreenTextOCRRecognizer.recognize(in: sendableImage.value)
        }
        return try await withTaskCancellationHandler {
            let result = try await recognitionTask.value
            try Task.checkCancellation()
            guard authorizationCheck() else { throw CancellationError() }
            return result
        } onCancel: {
            recognitionTask.cancel()
        }
    }

    private func capture(
        region: ScreenRegionSelection,
        sourceApplication: NSRunningApplication,
        authorizationCheck: @MainActor () -> Bool
    ) async throws -> CGImage {
        guard ScreenRecordingPermission.isGranted else {
            throw ScreenTextOCRError.screenRecordingPermissionRequired
        }
        guard authorizationCheck() else { throw CancellationError() }
        guard region.sourceRect.width >= 12, region.sourceRect.height >= 12 else {
            throw ScreenTextOCRError.selectionTooSmall
        }

        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        guard let display = content.displays.first(where: { $0.displayID == region.displayID }) else {
            throw ScreenTextOCRError.displayUnavailable
        }

        let configuration = SCStreamConfiguration()
        let sourceRect = region.sourceRect.intersection(
            CGRect(origin: .zero, size: region.screenFrame.size)
        )
        guard sourceRect.width >= 12, sourceRect.height >= 12 else {
            throw ScreenTextOCRError.selectionTooSmall
        }
        let sourceWindows = content.windows.filter { window in
            window.owningApplication?.processID == sourceApplication.processIdentifier
                && ScreenRegionSourceWindowPolicy.intersectsSourceWindow(
                    sourceRect: sourceRect,
                    displayFrame: display.frame,
                    sourceWindowFrames: [window.frame]
                )
        }
        guard !sourceWindows.isEmpty else {
            throw ScreenTextOCRError.selectionOutsideSourceApplication
        }
        // Include only windows owned by the App that was foreground when OCR
        // started. Pixels from password managers or any other overlapping App
        // are excluded even if the user drags the rectangle across them.
        let filter = SCContentFilter(display: display, including: sourceWindows)
        configuration.sourceRect = sourceRect
        let scale = max(CGFloat(filter.pointPixelScale), 1)
        configuration.width = max(Int(sourceRect.width * scale), 1)
        configuration.height = max(Int(sourceRect.height * scale), 1)
        configuration.showsCursor = false

        try Task.checkCancellation()
        guard authorizationCheck() else { throw CancellationError() }
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
        try Task.checkCancellation()
        guard authorizationCheck() else { throw CancellationError() }
        return image
    }
}

private final class ScreenRegionSelectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class ScreenRegionSelectionController {
    private var panels: [ScreenRegionSelectionPanel] = []
    private var continuation: CheckedContinuation<ScreenRegionSelection?, Never>?
    private var completed = false

    func selectRegion(suggestedRegion: ScreenRegionSelection? = nil) async -> ScreenRegionSelection? {
        cancel()
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            self.completed = false
            self.presentPanels(suggestedRegion: suggestedRegion)
        }
    }

    func cancel() {
        guard continuation != nil || !panels.isEmpty else { return }
        finish(nil)
    }

    private func presentPanels(suggestedRegion: ScreenRegionSelection?) {
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                    as? NSNumber else {
                continue
            }
            let displayID = CGDirectDisplayID(number.uint32Value)
            let view = ScreenRegionSelectionView(
                screen: screen,
                displayID: displayID,
                suggestedRegion: suggestedRegion?.displayID == displayID ? suggestedRegion : nil,
                onFinish: { [weak self] selection in self?.finish(selection) },
                onCancel: { [weak self] in self?.finish(nil) }
            )
            let panel = ScreenRegionSelectionPanel(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            panel.level = .screenSaver
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.contentView = view
            panel.makeKeyAndOrderFront(nil)
            panels.append(panel)
        }
        NSApp.activate()
    }

    private func finish(_ selection: ScreenRegionSelection?) {
        guard !completed else { return }
        completed = true
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
        let continuation = self.continuation
        self.continuation = nil
        continuation?.resume(returning: selection)
    }
}

private final class ScreenRegionSelectionView: NSView {
    private let screen: NSScreen
    private let displayID: CGDirectDisplayID
    private let suggestedRegion: ScreenRegionSelection?
    private let onFinish: (ScreenRegionSelection) -> Void
    private let onCancel: () -> Void
    private var dragStart: NSPoint?
    private var selectionRect: NSRect = .zero

    init(
        screen: NSScreen,
        displayID: CGDirectDisplayID,
        suggestedRegion: ScreenRegionSelection?,
        onFinish: @escaping (ScreenRegionSelection) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.screen = screen
        self.displayID = displayID
        self.suggestedRegion = suggestedRegion
        self.onFinish = onFinish
        self.onCancel = onCancel
        super.init(frame: NSRect(origin: .zero, size: screen.frame.size))
        wantsLayer = true
        if suggestedRegion != nil {
            let useWindowButton = NSButton(
                title: "使用当前窗口区域",
                target: self,
                action: #selector(useSuggestedRegion)
            )
            useWindowButton.bezelStyle = .rounded
            useWindowButton.controlSize = .large
            useWindowButton.setAccessibilityIdentifier("cpt.ocr.use-window")
            addSubview(useWindowButton)
        }
        let cancelButton = NSButton(title: "取消", target: self, action: #selector(cancelSelection))
        cancelButton.bezelStyle = .rounded
        cancelButton.controlSize = .large
        cancelButton.setAccessibilityIdentifier("cpt.ocr.cancel")
        addSubview(cancelButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }

    override func layout() {
        super.layout()
        let buttons = subviews.compactMap { $0 as? NSButton }
        var x = bounds.midX - CGFloat(buttons.count) * 82
        for button in buttons {
            button.sizeToFit()
            let width = max(button.frame.width + 22, 120)
            button.frame = NSRect(x: x, y: bounds.maxY - 92, width: width, height: 34)
            x += width + 12
        }
    }

    @objc private func useSuggestedRegion() {
        if let suggestedRegion {
            onFinish(suggestedRegion)
        }
    }

    @objc private func cancelSelection() {
        onCancel()
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = convert(event.locationInWindow, from: nil)
        selectionRect = .zero
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStart else { return }
        selectionRect = rect(from: dragStart, to: convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let dragStart else { return }
        selectionRect = rect(from: dragStart, to: convert(event.locationInWindow, from: nil))
        self.dragStart = nil
        guard selectionRect.width >= 12, selectionRect.height >= 12 else {
            NSSound.beep()
            needsDisplay = true
            return
        }
        let globalRect = selectionRect.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
        onFinish(
            ScreenRegionSelection(
                displayID: displayID,
                screenFrame: screen.frame,
                appKitRect: globalRect
            )
        )
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel()
        } else {
            super.keyDown(with: event)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.36).setFill()
        bounds.fill()

        if !selectionRect.isEmpty {
            NSGraphicsContext.saveGraphicsState()
            NSColor.clear.setFill()
            selectionRect.fill(using: .copy)
            NSColor.systemBlue.setStroke()
            let path = NSBezierPath(rect: selectionRect)
            path.lineWidth = 2
            path.stroke()
            NSGraphicsContext.restoreGraphicsState()
        }

        let message = "拖动框选文字或字幕区域 · Esc 取消"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 16, weight: .semibold),
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.black.withAlphaComponent(0.72)
        ]
        let size = message.size(withAttributes: attributes)
        let rect = NSRect(
            x: bounds.midX - size.width / 2 - 12,
            y: bounds.maxY - size.height - 36,
            width: size.width + 24,
            height: size.height + 12
        )
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
        message.draw(
            at: NSPoint(x: rect.minX + 12, y: rect.minY + 6),
            withAttributes: attributes
        )
    }

    private func rect(from start: NSPoint, to end: NSPoint) -> NSRect {
        NSRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        ).intersection(bounds)
    }
}
