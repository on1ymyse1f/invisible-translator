import AppKit
import QuartzCore
import SwiftUI

@MainActor
final class PromptPanelController {
    private let model: AppModel
    private lazy var panel: NSPanel = makePanel()
    private var lastRequestedFrame: NSRect?

    init(model: AppModel) {
        self.model = model
    }

    var isVisible: Bool {
        panel.isVisible
    }

    func show() {
        prepareForDisplay()
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
    }

    func showPassive() {
        prepareForDisplay()
        panel.orderFrontRegardless()
    }

    private func prepareForDisplay() {
        if panel.contentViewController == nil {
            panel.contentViewController = NSHostingController(rootView: PromptView(model: model))
        }

        applyAppearance()
        applyPresentation(animated: false)
    }

    func applyAppearance() {
        panel.appearance = model.appTheme.nsAppearance
    }

    func hide() {
        lastRequestedFrame = nil
        panel.orderOut(nil)
    }

    func bringToFront() {
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
    }

    func applyPresentation(animated: Bool) {
        let targetFrame = frameForCurrentPresentation().roundedForWindowPlacement()
        guard lastRequestedFrame?.distance(to: targetFrame) ?? .greatestFiniteMagnitude > 1 else {
            return
        }
        lastRequestedFrame = targetFrame

        let applyFrame = {
            self.panel.setFrame(targetFrame, display: true)
        }

        if animated, panel.isVisible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(targetFrame, display: true)
            }
        } else {
            applyFrame()
        }
    }

    private func makePanel() -> NSPanel {
        let panel = FloatingPromptPanel(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 380),
            styleMask: [.titled, .closable, .fullSizeContentView, .utilityWindow],
            backing: .buffered,
            defer: false
        )

        panel.title = "无感翻译 · 草稿翻译窗"
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        return panel
    }

    private func frameForCurrentPresentation() -> NSRect {
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let preferredSize = Self.size(
            for: model.panelPresentation,
            includesResponseTranslation: model.hasResponseTranslationActivity
        )
        let margin: CGFloat = 24
        let size = NSSize(
            width: min(preferredSize.width, max(520, screenFrame.width - margin * 2)),
            height: min(preferredSize.height, max(240, screenFrame.height - margin * 2))
        )

        let preferredY: CGFloat
        switch model.panelPresentation {
        case .expanded:
            preferredY = screenFrame.maxY - size.height - 80
        case .compact:
            preferredY = screenFrame.minY + (model.hasResponseTranslationActivity ? 72 : 64)
        }

        let minX = screenFrame.minX + margin
        let maxX = screenFrame.maxX - size.width - margin
        let minY = screenFrame.minY + margin
        let maxY = screenFrame.maxY - size.height - margin

        let origin = NSPoint(
            x: min(max(screenFrame.midX - size.width / 2, minX), maxX),
            y: min(max(preferredY, minY), maxY)
        )

        return NSRect(origin: origin, size: size)
    }

    private static func size(
        for presentation: AppModel.PanelPresentation,
        includesResponseTranslation: Bool
    ) -> NSSize {
        switch presentation {
        case .expanded:
            return NSSize(width: includesResponseTranslation ? 820 : 760, height: includesResponseTranslation ? 700 : 420)
        case .compact:
            return NSSize(width: includesResponseTranslation ? 820 : 760, height: includesResponseTranslation ? 430 : 126)
        }
    }
}

final class FloatingPromptPanel: NSPanel {
    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        true
    }
}

private extension NSRect {
    func distance(to other: NSRect) -> CGFloat {
        abs(minX - other.minX)
            + abs(minY - other.minY)
            + abs(width - other.width)
            + abs(height - other.height)
    }

    func roundedForWindowPlacement() -> NSRect {
        NSRect(
            x: minX.rounded(),
            y: minY.rounded(),
            width: width.rounded(),
            height: height.rounded()
        )
    }
}
