import AppKit
import CryptoKit
import SwiftUI

enum SubtitleDisplayMode: String, CaseIterable, Sendable {
    case bilingual
    case translationOnly

    var displayName: String {
        switch self {
        case .bilingual: return "双语"
        case .translationOnly: return "仅译文"
        }
    }
}

enum SubtitleOverlayStyle: String, CaseIterable, Sendable {
    case dark
    case light
    case highContrast

    var displayName: String {
        switch self {
        case .dark: return "深色"
        case .light: return "浅色"
        case .highContrast: return "高对比"
        }
    }
}

enum SubtitleSentenceFormatter {
    static func normalizedCue(from rawText: String) -> String? {
        var lines: [String] = []
        for rawLine in rawText.components(separatedBy: .newlines) {
            let line = rawLine
                .replacingOccurrences(of: "\u{00A0}", with: " ")
                .components(separatedBy: .whitespaces)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard PassiveTextEligibility.normalizedCandidate(
                line,
                minimumLetters: 1,
                maximumCharacters: 600
            ) != nil else {
                continue
            }
            if lines.last != line {
                lines.append(line)
            }
        }
        guard !lines.isEmpty else { return nil }

        var result = ""
        for line in lines {
            guard !result.isEmpty else {
                result = line
                continue
            }
            let needsSpace = latinBoundary(result.last, line.first)
                && !endsWithSentencePunctuation(result)
            result += needsSpace ? " " + line : line
        }
        let capped = String(result.prefix(1_200))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return capped.isEmpty ? nil : capped
    }

    private static func latinBoundary(_ left: Character?, _ right: Character?) -> Bool {
        guard let left, let right else { return false }
        return left.isASCII && right.isASCII && (left.isLetter || left.isNumber)
    }

    private static func endsWithSentencePunctuation(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return ".!?。！？:：;；,—–".contains(last)
    }
}

struct SubtitleCueProcessor: Sendable {
    private(set) var pendingText = ""
    private(set) var pendingFrames = 0
    private(set) var lastEmittedText = ""

    mutating func observe(_ rawText: String) -> String? {
        guard let cue = SubtitleSentenceFormatter.normalizedCue(from: rawText) else {
            pendingText = ""
            pendingFrames = 0
            return nil
        }

        if cue == pendingText {
            pendingFrames += 1
        } else {
            pendingText = cue
            pendingFrames = 1
        }

        guard pendingFrames >= 2,
              cue != lastEmittedText else {
            return nil
        }
        lastEmittedText = cue
        return cue
    }
}

actor SubtitleTranslationCache {
    private struct Entry {
        let value: TranslationProviderOutput
        let expiresAt: Date
    }

    private var values: [String: Entry] = [:]
    private var order: [String] = []
    private let capacity: Int
    private let timeToLive: TimeInterval

    init(capacity: Int = 160, timeToLive: TimeInterval = 300) {
        self.capacity = max(capacity, 1)
        self.timeToLive = max(timeToLive, 1)
    }

    func value(
        for text: String,
        target: TargetLanguage,
        now: Date = Date()
    ) -> TranslationProviderOutput? {
        removeExpiredEntries(now: now)
        let key = Self.cacheKey(text: text, target: target)
        guard let entry = values[key] else { return nil }
        order.removeAll { $0 == key }
        order.append(key)
        return entry.value
    }

    func insert(
        _ value: TranslationProviderOutput,
        for text: String,
        target: TargetLanguage,
        now: Date = Date()
    ) {
        removeExpiredEntries(now: now)
        let key = Self.cacheKey(text: text, target: target)
        values[key] = Entry(value: value, expiresAt: now.addingTimeInterval(timeToLive))
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > capacity {
            values.removeValue(forKey: order.removeFirst())
        }
    }

    func removeAll() {
        values.removeAll(keepingCapacity: false)
        order.removeAll(keepingCapacity: false)
    }

    nonisolated static func cacheKey(text: String, target: TargetLanguage) -> String {
        let data = Data((target.rawValue + "\u{1F}" + text).utf8)
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func removeExpiredEntries(now: Date) {
        let expired = values.compactMap { key, entry in
            entry.expiresAt <= now ? key : nil
        }
        guard !expired.isEmpty else { return }
        let expiredSet = Set(expired)
        for key in expiredSet {
            values.removeValue(forKey: key)
        }
        order.removeAll { expiredSet.contains($0) }
    }
}

private final class SubtitleOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class SubtitleOverlayController {
    private unowned let model: AppModel
    private var panel: SubtitleOverlayPanel?
    private var hostingView: NSHostingView<SubtitleOverlayView>?
    private var region: ScreenRegionSelection?

    init(model: AppModel) {
        self.model = model
    }

    var isVisible: Bool { panel?.isVisible == true }

    func show(region: ScreenRegionSelection) {
        self.region = region
        let size = desiredSize
        if panel == nil {
            let host = NSHostingView(rootView: SubtitleOverlayView(model: model))
            let window = SubtitleOverlayPanel(
                contentRect: NSRect(origin: .zero, size: size),
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
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.contentView = host
            panel = window
            hostingView = host
        } else {
            hostingView?.rootView = SubtitleOverlayView(model: model)
        }
        panel?.setContentSize(size)
        panel?.setFrameOrigin(origin(for: size, region: region))
        panel?.orderFrontRegardless()
    }

    func refresh() {
        guard let region else { return }
        show(region: region)
    }

    func hide() {
        panel?.orderOut(nil)
        region = nil
    }

    private var desiredSize: NSSize {
        NSSize(
            width: min(max(region?.appKitRect.width ?? 720, 520), 1_080),
            height: model.subtitleDisplayMode == .bilingual ? 150 : 108
        )
    }

    private func origin(for size: NSSize, region: ScreenRegionSelection) -> NSPoint {
        let screen = NSScreen.screens.first { screen in
            guard let value = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                    as? NSNumber else { return false }
            return value.uint32Value == region.displayID
        }
        let visible = screen?.visibleFrame ?? region.screenFrame
        let x = min(
            max(region.appKitRect.midX - size.width / 2, visible.minX + 8),
            visible.maxX - size.width - 8
        )
        let preferredBelow = region.appKitRect.minY - size.height - 12
        let y = preferredBelow >= visible.minY + 8
            ? preferredBelow
            : min(region.appKitRect.maxY + 12, visible.maxY - size.height - 8)
        return NSPoint(x: x, y: y)
    }
}

private struct SubtitleOverlayView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "captions.bubble.fill")
                Text("实时字幕 · \(model.subtitleTargetLanguageName)")
                    .font(.system(size: 12, weight: .semibold))
                Text(model.subtitleStatus)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button("停止") { model.stopSubtitleTranslation() }
                    .controlSize(.small)
                    .accessibilityIdentifier("cpt.subtitle.stop")
            }

            if model.subtitleDisplayMode == .bilingual {
                Text(model.subtitleSourceText.isEmpty ? "等待字幕稳定出现…" : model.subtitleSourceText)
                    .font(.system(size: max(model.subtitleFontSize - 3, 13)))
                    .foregroundStyle(sourceColor)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .center)
            }

            Text(model.subtitleTranslationText.isEmpty ? "…" : model.subtitleTranslationText)
                .font(.system(size: model.subtitleFontSize, weight: .semibold))
                .foregroundStyle(translationColor)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(borderColor, lineWidth: model.subtitleOverlayStyle == .highContrast ? 2 : 1)
        )
    }

    private var background: Color {
        switch model.subtitleOverlayStyle {
        case .dark: return Color.black.opacity(0.84)
        case .light: return Color.white.opacity(0.94)
        case .highContrast: return Color.black.opacity(0.96)
        }
    }

    private var sourceColor: Color {
        model.subtitleOverlayStyle == .light ? .black.opacity(0.72) : .white.opacity(0.76)
    }

    private var translationColor: Color {
        switch model.subtitleOverlayStyle {
        case .light: return .black
        case .dark: return .white
        case .highContrast: return .yellow
        }
    }

    private var borderColor: Color {
        model.subtitleOverlayStyle == .highContrast ? .yellow : .white.opacity(0.20)
    }
}
