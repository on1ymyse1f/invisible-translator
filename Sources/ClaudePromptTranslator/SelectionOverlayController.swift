import AppKit
import SwiftUI

enum SelectionTranslationPhase: Equatable {
    case idle
    case detected
    case reading
    case translating
    case translated
    case failed
}

private final class SelectionOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class SelectionOverlayController {
    private unowned let model: AppModel
    private var panel: SelectionOverlayPanel?
    private var hostingView: NSHostingView<SelectionOverlayView>?
    private var outsideClickMonitor: Any?
    private var lastAnchorRect: NSRect?

    init(model: AppModel) {
        self.model = model
    }

    var isVisible: Bool {
        panel?.isVisible == true
    }

    func show(anchorRect: NSRect?) {
        lastAnchorRect = anchorRect
        let desiredSize = size(for: model.selectionPhase)

        if panel == nil {
            let host = NSHostingView(rootView: SelectionOverlayView(model: model))
            let window = SelectionOverlayPanel(
                contentRect: NSRect(origin: .zero, size: desiredSize),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
            window.level = .floating
            window.isFloatingPanel = true
            window.hidesOnDeactivate = false
            window.becomesKeyOnlyIfNeeded = true
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            window.contentView = host
            panel = window
            hostingView = host
        } else {
            hostingView?.rootView = SelectionOverlayView(model: model)
        }

        guard let panel else {
            return
        }
        panel.setContentSize(desiredSize)
        panel.setFrameOrigin(origin(for: desiredSize, anchorRect: anchorRect))
        panel.orderFrontRegardless()
        installOutsideClickMonitorIfNeeded()
    }

    func refresh() {
        show(anchorRect: lastAnchorRect)
    }

#if DEBUG
    func activateForDebugAutomation() {
        guard SelectionDiagnostics.isEnabled else {
            return
        }
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
#endif

    func hide() {
        panel?.orderOut(nil)
        removeOutsideClickMonitor()
    }

    private func installOutsideClickMonitorIfNeeded() {
        guard outsideClickMonitor == nil else {
            return
        }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            let clickPoint = NSEvent.mouseLocation
            let wasInsideVisiblePanel = self?.panel.map {
                $0.isVisible && $0.frame.contains(clickPoint)
            } ?? false
            guard !wasInsideVisiblePanel else {
                return
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.panel?.isVisible == true else {
                    return
                }
                SelectionDiagnostics.record("overlay dismissed by outside click")
                self.model.dismissSelectionOverlay()
            }
        }
    }

    private func removeOutsideClickMonitor() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
        }
        outsideClickMonitor = nil
    }

    private func size(for phase: SelectionTranslationPhase) -> NSSize {
        switch phase {
        case .detected:
            return NSSize(width: 420, height: 58)
        case .idle:
            return NSSize(width: 360, height: 80)
        case .reading, .translating, .translated, .failed:
            return NSSize(
                width: 430,
                height: model.selectionDisplayMode == .bilingual ? 286 : 218
            )
        }
    }

    private func origin(for size: NSSize, anchorRect: NSRect?) -> NSPoint {
        let mousePoint = NSEvent.mouseLocation
        let usableAnchor: NSRect? = anchorRect.flatMap { rect in
            guard rect.width.isFinite,
                  rect.height.isFinite,
                  rect.width > 0,
                  rect.height > 0,
                  rect.width < 900,
                  rect.height < 420 else {
                return nil
            }
            return rect
        }
        let referencePoint = usableAnchor.map { NSPoint(x: $0.midX, y: $0.minY) } ?? mousePoint
        let screen = NSScreen.screens.first(where: { $0.frame.contains(referencePoint) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1_440, height: 900)

        var x = usableAnchor.map { $0.minX } ?? (referencePoint.x + 12)
        var y = usableAnchor.map { $0.minY - size.height - 10 } ?? (referencePoint.y - size.height - 14)

        if y < visibleFrame.minY + 6 {
            y = (usableAnchor?.maxY ?? referencePoint.y) + 10
        }
        x = min(max(x, visibleFrame.minX + 6), visibleFrame.maxX - size.width - 6)
        y = min(max(y, visibleFrame.minY + 6), visibleFrame.maxY - size.height - 6)
        return NSPoint(x: x, y: y)
    }
}

private struct SelectionOverlayView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Group {
            if model.selectionPhase == .detected {
                detectedPill
            } else {
                translationCard
            }
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.14), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 18, x: 0, y: 8)
    }

    private var detectedPill: some View {
        HStack(spacing: 10) {
            Image(systemName: "translate")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(model.selectionSourceLanguageName) → \(model.selectionTargetLanguageName)")
                    .font(.system(size: 12, weight: .semibold))
                Text("已选择 \(model.selectionSourceText.count) 个字符 · \(model.selectionSourceAppName)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            Button("翻译") {
                model.translateDetectedSelection()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .accessibilityIdentifier("cpt.selection.translate")

            Button {
                model.dismissSelectionOverlay()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("关闭")
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
            .accessibilityLabel("关闭翻译浮层")
            .accessibilityIdentifier("cpt.selection.close")
        }
        .padding(.horizontal, 14)
        .frame(width: 420, height: 58)
    }

    private var translationCard: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 8) {
                Image(systemName: "translate")
                    .foregroundStyle(.tint)
                Text("\(model.selectionSourceLanguageName) → \(model.selectionTargetLanguageName)")
                    .font(.system(size: 13, weight: .semibold))
                Text("· \(model.selectionSourceAppName)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button {
                    model.dismissSelectionOverlay()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
                .accessibilityLabel("关闭翻译浮层")
                .accessibilityIdentifier("cpt.selection.close")
            }

            if model.selectionDisplayMode == .bilingual {
                VStack(alignment: .leading, spacing: 5) {
                    Text("原文")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ScrollView {
                        RichTranslationText(text: model.selectionSourceText, fontSize: 12)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 54)
                }

                Divider()
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("译文")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                if model.selectionPhase == .reading || model.selectionPhase == .translating {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(model.selectionStatus)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                } else {
                    ScrollView {
                        RichTranslationText(
                            text: model.selectionTranslationText.isEmpty
                                ? model.selectionStatus
                                : model.selectionTranslationText,
                            fontSize: 13
                        )
                            .foregroundStyle(model.selectionPhase == .failed ? .red : .primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(height: 72)

            HStack(spacing: 9) {
                Text(model.selectionStatus)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(model.selectionStatus)
                    .accessibilityIdentifier("cpt.selection.status")

                Spacer()

                if model.selectionPhase == .failed {
                    Button("重试") {
                        model.translateDetectedSelection()
                    }
                    .accessibilityIdentifier("cpt.selection.retry")
                }

                Button("复制译文") {
                    model.copySelectionTranslation()
                }
                .disabled(model.selectionTranslationText.isEmpty)
                .accessibilityIdentifier("cpt.selection.copy")

                if model.selectionCanReplace {
                    Button("替换选区") {
                        model.replaceSelectionWithTranslation()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.selectionTranslationText.isEmpty)
                    .accessibilityIdentifier("cpt.selection.replace")
                }
            }
        }
        .padding(15)
        .frame(
            width: 430,
            height: model.selectionDisplayMode == .bilingual ? 286 : 218
        )
    }
}

private struct RichTranslationText: View {
    let text: String
    let fontSize: CGFloat

    var body: some View {
        if text.count <= 12_000,
           let attributed = try? AttributedString(markdown: text) {
            Text(attributed).font(.system(size: fontSize))
        } else {
            Text(text).font(.system(size: fontSize))
        }
    }
}
