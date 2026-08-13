import AppKit
import Foundation
import SwiftUI

/// Disk locations that are owned by this app. Apple-managed language and speech
/// assets deliberately do not appear here and are never modified by this app.
struct StoragePerformanceLocations: Equatable {
    let appBundleURL: URL
    let cacheDirectoryURL: URL
    let asrModelsDirectoryURL: URL

    static func live(fileManager: FileManager = .default) -> StoragePerformanceLocations {
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClaudePromptTranslator", isDirectory: true)
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClaudePromptTranslator", isDirectory: true)
        return StoragePerformanceLocations(
            appBundleURL: Bundle.main.bundleURL,
            cacheDirectoryURL: caches,
            asrModelsDirectoryURL: support.appendingPathComponent("ASRModels", isDirectory: true)
        )
    }
}

struct StoragePerformanceSnapshot: Equatable {
    let appByteCount: Int64
    let cacheByteCount: Int64
    let asrModelByteCount: Int64

    static let empty = StoragePerformanceSnapshot(
        appByteCount: 0,
        cacheByteCount: 0,
        asrModelByteCount: 0
    )

    var appSizeDescription: String { Self.sizeDescription(appByteCount) }
    var cacheSizeDescription: String { Self.sizeDescription(cacheByteCount) }
    var asrModelSizeDescription: String { Self.sizeDescription(asrModelByteCount) }

    private static func sizeDescription(_ byteCount: Int64) -> String {
        ByteCountFormatter.string(
            fromByteCount: max(byteCount, 0),
            countStyle: .file
        )
    }
}

enum StoragePerformanceError: LocalizedError, Equatable {
    case unsafeModelDirectory
    case modelDirectoryIsSymbolicLink

    var errorDescription: String? {
        switch self {
        case .unsafeModelDirectory:
            return "模型目录不属于无感翻译，已拒绝操作。"
        case .modelDirectoryIsSymbolicLink:
            return "模型目录是符号链接，已拒绝操作。"
        }
    }
}

/// A small, side-effect-free inspector. The only mutation it offers is moving
/// the exact app-owned ASR directory to Trash; callers must obtain user
/// confirmation before invoking it.
struct StoragePerformanceInspector {
    let locations: StoragePerformanceLocations
    private let fileManager: FileManager

    init(
        locations: StoragePerformanceLocations = .live(),
        fileManager: FileManager = .default
    ) {
        self.locations = locations
        self.fileManager = fileManager
    }

    func snapshot() -> StoragePerformanceSnapshot {
        StoragePerformanceSnapshot(
            appByteCount: allocatedBytes(at: locations.appBundleURL),
            cacheByteCount: allocatedBytes(at: locations.cacheDirectoryURL),
            asrModelByteCount: allocatedBytes(at: locations.asrModelsDirectoryURL)
        )
    }

    /// Moves only `…/ClaudePromptTranslator/ASRModels` to the user's Trash.
    /// It never removes files permanently and will not follow a symbolic link.
    @discardableResult
    func moveASRModelsToTrash() throws -> URL? {
        let url = locations.asrModelsDirectoryURL.standardizedFileURL
        guard isExpectedOwnedModelDirectory(url) else {
            throw StoragePerformanceError.unsafeModelDirectory
        }
        guard fileManager.fileExists(atPath: url.path) else { return nil }

        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true else {
            throw StoragePerformanceError.modelDirectoryIsSymbolicLink
        }
        guard values.isDirectory == true else {
            throw StoragePerformanceError.unsafeModelDirectory
        }

        var trashedURL: NSURL?
        try fileManager.trashItem(at: url, resultingItemURL: &trashedURL)
        return trashedURL as URL?
    }

    private func isExpectedOwnedModelDirectory(_ url: URL) -> Bool {
        guard url.lastPathComponent == "ASRModels" else { return false }
        let parent = url.deletingLastPathComponent()
        guard parent.lastPathComponent == "ClaudePromptTranslator" else { return false }
        return url == locations.asrModelsDirectoryURL.standardizedFileURL
    }

    private func allocatedBytes(at rootURL: URL) -> Int64 {
        let root = rootURL.standardizedFileURL
        guard fileManager.fileExists(atPath: root.path) else { return 0 }

        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: []
        ) else {
            return 0
        }

        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: keys) else { continue }
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            if values.isRegularFile == true, let size = values.fileSize {
                let (sum, overflow) = total.addingReportingOverflow(Int64(size))
                total = overflow ? Int64.max : sum
            }
        }
        return total
    }
}

@MainActor
private final class StoragePerformanceState: ObservableObject {
    @Published private(set) var snapshot = StoragePerformanceSnapshot.empty
    @Published private(set) var statusMessage = "只统计本应用拥有的目录；不会读取文本或扫描系统模型。"

    private let inspector: StoragePerformanceInspector

    init(inspector: StoragePerformanceInspector) {
        self.inspector = inspector
        refresh()
    }

    func refresh(message: String? = nil) {
        snapshot = inspector.snapshot()
        if let message {
            statusMessage = message
        }
    }

    func confirmAndMoveModelsToTrash(from window: NSWindow?) {
        guard snapshot.asrModelByteCount > 0 else {
            refresh(message: "没有可回收的私有 ASR 模型；基础版不内置模型。")
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "将私有语音模型移入废纸篓？"
        alert.informativeText = "只会移动无感翻译自己的 ASRModels 目录（\(snapshot.asrModelSizeDescription)）。不会删除 Apple 系统语言或语音资产；可从废纸篓恢复。"
        alert.addButton(withTitle: "移入废纸篓")
        alert.addButton(withTitle: "取消")

        let complete: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            do {
                _ = try self.inspector.moveASRModelsToTrash()
                self.refresh(message: "私有模型已移入废纸篓；下次显式下载后才会重新出现。")
            } catch {
                self.refresh(message: (error as? LocalizedError)?.errorDescription ?? "无法移动私有模型。")
            }
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: complete)
        } else {
            complete(alert.runModal())
        }
    }
}

@MainActor
final class StoragePerformanceController: NSObject, NSWindowDelegate {
    private let state: StoragePerformanceState
    private var window: NSWindow?

    init(inspector: StoragePerformanceInspector = StoragePerformanceInspector()) {
        state = StoragePerformanceState(inspector: inspector)
        super.init()
    }

    func show() {
        if window == nil {
            window = makeWindow()
        }
        state.refresh()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }

    private func makeWindow() -> NSWindow {
        let rootView = StoragePerformanceView(
            state: state,
            onRefresh: { [weak self] in self?.state.refresh() },
            onMoveModelsToTrash: { [weak self] in
                self?.state.confirmAndMoveModelsToTrash(from: self?.window)
            }
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 400),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "无感翻译 · 存储与性能"
        window.contentViewController = NSHostingController(rootView: rootView)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setAccessibilityIdentifier("cpt.storage-performance.window")
        return window
    }
}

private struct StoragePerformanceView: View {
    @ObservedObject var state: StoragePerformanceState
    let onRefresh: () -> Void
    let onMoveModelsToTrash: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("存储与性能")
                    .font(.title2.weight(.semibold))
                Text("基础 App 不含模型。私有模型只在你主动下载后占用空间。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
                storageRow("App", state.snapshot.appSizeDescription)
                storageRow("本应用缓存", state.snapshot.cacheSizeDescription)
                storageRow("私有 ASR 模型", state.snapshot.asrModelSizeDescription)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.08)))

            Text("系统管理的 Apple 翻译与语音语言包不会显示、不会删除。模型目录连续 30 天未使用可自动回收；正在使用或标记保留的模型不会自动删除。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(state.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("cpt.storage-performance.status")

            Spacer()

            HStack {
                Button("刷新") { onRefresh() }
                    .accessibilityIdentifier("cpt.storage-performance.refresh")
                Spacer()
                Button("将私有模型移入废纸篓…") { onMoveModelsToTrash() }
                    .disabled(state.snapshot.asrModelByteCount == 0)
                    .accessibilityIdentifier("cpt.storage-performance.trash-models")
            }
        }
        .padding(22)
        .frame(width: 540, height: 400, alignment: .leading)
    }

    @ViewBuilder
    private func storageRow(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value).font(.body.monospacedDigit())
        }
    }
}
