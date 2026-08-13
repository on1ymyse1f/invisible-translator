import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
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

enum VisionTextRecognitionProfile: Sendable {
    case generalOCR
    case replyOCR
    case liveSubtitle

    var configuration: VisionTextRecognitionConfiguration {
        switch self {
        case .generalOCR:
            return VisionTextRecognitionConfiguration(
                pixelBudget: 2_097_152,
                minimumTextHeight: 0.012,
                accuratePassConfidenceThreshold: 0.64,
                accuratePassCharacterThreshold: 18
            )
        case .replyOCR:
            return VisionTextRecognitionConfiguration(
                pixelBudget: 1_048_576,
                minimumTextHeight: 0.014,
                accuratePassConfidenceThreshold: 0.66,
                accuratePassCharacterThreshold: 24
            )
        case .liveSubtitle:
            return VisionTextRecognitionConfiguration(
                pixelBudget: 786_432,
                minimumTextHeight: 0.018,
                accuratePassConfidenceThreshold: 0.62,
                accuratePassCharacterThreshold: 14
            )
        }
    }
}

/// Shared limits and retry policy for every Vision text-recognition entry point.
/// The pixel budget is also applied to ScreenCaptureKit, so a large selection is
/// never materialized as a full-resolution image before OCR.
struct VisionTextRecognitionConfiguration: Equatable, Sendable {
    let pixelBudget: Int
    let minimumTextHeight: Float
    let accuratePassConfidenceThreshold: Float
    let accuratePassCharacterThreshold: Int

    func fittedPixelSize(width: Int, height: Int) -> (width: Int, height: Int) {
        let safeWidth = max(width, 1)
        let safeHeight = max(height, 1)
        let safePixelBudget = max(pixelBudget, 1)
        let pixels = safeWidth.multipliedReportingOverflow(by: safeHeight)
        guard pixels.overflow || pixels.partialValue > safePixelBudget else {
            return (safeWidth, safeHeight)
        }
        let scale = sqrt(Double(safePixelBudget) / (Double(safeWidth) * Double(safeHeight)))
        return (
            max(Int((Double(safeWidth) * scale).rounded(.down)), 1),
            max(Int((Double(safeHeight) * scale).rounded(.down)), 1)
        )
    }

    func shouldRunAccuratePass(
        lineCount: Int,
        recognizedCharacterCount: Int,
        averageConfidence: Float
    ) -> Bool {
        lineCount == 0
            || recognizedCharacterCount < accuratePassCharacterThreshold
            || averageConfidence < accuratePassConfidenceThreshold
    }
}

enum OCRTilePlanner {
    static let overlapPixels = 32

    static func tiles(
        in sourceRect: CGRect,
        pixelScale: CGFloat,
        pixelBudget: Int,
        overlap: Int = overlapPixels
    ) -> [CGRect] {
        let scale = max(pixelScale, 1)
        let totalWidth = max(Int(ceil(sourceRect.width * scale)), 1)
        let totalHeight = max(Int(ceil(sourceRect.height * scale)), 1)
        let budget = max(pixelBudget, 1)
        let totalPixels = totalWidth.multipliedReportingOverflow(by: totalHeight)
        guard totalPixels.overflow || totalPixels.partialValue > budget else {
            return [sourceRect]
        }

        let aspect = Double(totalWidth) / Double(totalHeight)
        var tileWidth = min(
            totalWidth,
            max(Int(sqrt(Double(budget) * aspect).rounded(.down)), 1)
        )
        var tileHeight = min(totalHeight, max(budget / max(tileWidth, 1), 1))
        while tileWidth * tileHeight > budget {
            if tileWidth >= tileHeight { tileWidth -= 1 } else { tileHeight -= 1 }
        }

        let overlapWidth = min(max(overlap, 0), max(tileWidth - 1, 0))
        let overlapHeight = min(max(overlap, 0), max(tileHeight - 1, 0))
        let horizontalStep = max(tileWidth - overlapWidth, 1)
        let verticalStep = max(tileHeight - overlapHeight, 1)

        func offsets(total: Int, tile: Int, step: Int) -> [Int] {
            guard total > tile else { return [0] }
            var values: [Int] = []
            var offset = 0
            while offset + tile < total {
                values.append(offset)
                offset += step
            }
            let finalOffset = max(total - tile, 0)
            if values.last != finalOffset { values.append(finalOffset) }
            return values
        }

        var result: [CGRect] = []
        for y in offsets(total: totalHeight, tile: tileHeight, step: verticalStep) {
            for x in offsets(total: totalWidth, tile: tileWidth, step: horizontalStep) {
                let pixelWidth = min(tileWidth, totalWidth - x)
                let pixelHeight = min(tileHeight, totalHeight - y)
                result.append(
                    CGRect(
                        x: sourceRect.minX + CGFloat(x) / scale,
                        y: sourceRect.minY + CGFloat(y) / scale,
                        width: CGFloat(pixelWidth) / scale,
                        height: CGFloat(pixelHeight) / scale
                    )
                )
            }
        }
        return result
    }
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
    static func recognize(
        in image: CGImage,
        profile: VisionTextRecognitionProfile = .generalOCR
    ) throws -> ScreenTextOCRResult {
        try recognize(in: image, configuration: profile.configuration)
    }

    static func recognize(
        in image: CGImage,
        configuration: VisionTextRecognitionConfiguration
    ) throws -> ScreenTextOCRResult {
        try recognize(configuration: configuration) { level, correction, languages in
            perform(
                in: image,
                recognitionLevel: level,
                usesLanguageCorrection: correction,
                recognitionLanguages: languages,
                configuration: configuration
            )
        }
    }

    /// Continuous subtitle capture keeps pixels in their ScreenCaptureKit
    /// surface and hands them directly to Vision. No CGImage is created on this
    /// path.
    static func recognize(
        in pixelBuffer: CVPixelBuffer,
        profile: VisionTextRecognitionProfile = .liveSubtitle
    ) throws -> ScreenTextOCRResult {
        let configuration = profile.configuration
        return try recognize(configuration: configuration) { level, correction, languages in
            perform(
                in: pixelBuffer,
                recognitionLevel: level,
                usesLanguageCorrection: correction,
                recognitionLanguages: languages,
                configuration: configuration
            )
        }
    }

    private static func recognize(
        configuration: VisionTextRecognitionConfiguration,
        performPass: (
            _ recognitionLevel: VNRequestTextRecognitionLevel,
            _ usesLanguageCorrection: Bool,
            _ recognitionLanguages: [String]?
        ) -> OCRPass
    ) throws -> ScreenTextOCRResult {
        let automatic = performPass(.fast, false, nil)
        let best: OCRPass
        if configuration.shouldRunAccuratePass(
            lineCount: automatic.lines.count,
            recognizedCharacterCount: automatic.recognizedCharacterCount,
            averageConfidence: automatic.averageConfidence
        ) {
            let detectedIdentifier = SelectionLanguageRouter.detectedLanguageIdentifier(
                in: automatic.lines.map(\.text).joined(separator: "\n")
            )
            let multilingual = performPass(
                .accurate,
                true,
                automatic.lines.isEmpty
                    ? nil
                    : preferredRecognitionLanguages(for: detectedIdentifier)
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

        var recognizedCharacterCount: Int {
            lines.reduce(0) { $0 + $1.text.count }
        }

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
        recognitionLevel: VNRequestTextRecognitionLevel,
        usesLanguageCorrection: Bool,
        recognitionLanguages: [String]?,
        configuration: VisionTextRecognitionConfiguration
    ) -> OCRPass {
        perform(
            recognitionLevel: recognitionLevel,
            usesLanguageCorrection: usesLanguageCorrection,
            recognitionLanguages: recognitionLanguages,
            configuration: configuration
        ) { request in
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        }
    }

    private static func perform(
        in pixelBuffer: CVPixelBuffer,
        recognitionLevel: VNRequestTextRecognitionLevel,
        usesLanguageCorrection: Bool,
        recognitionLanguages: [String]?,
        configuration: VisionTextRecognitionConfiguration
    ) -> OCRPass {
        perform(
            recognitionLevel: recognitionLevel,
            usesLanguageCorrection: usesLanguageCorrection,
            recognitionLanguages: recognitionLanguages,
            configuration: configuration
        ) { request in
            try VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:]).perform([request])
        }
    }

    private static func perform(
        recognitionLevel: VNRequestTextRecognitionLevel,
        usesLanguageCorrection: Bool,
        recognitionLanguages: [String]?,
        configuration: VisionTextRecognitionConfiguration,
        requestHandler: (VNRecognizeTextRequest) throws -> Void
    ) -> OCRPass {
        autoreleasepool {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = recognitionLevel
            request.usesLanguageCorrection = usesLanguageCorrection
            request.minimumTextHeight = configuration.minimumTextHeight
            if let recognitionLanguages {
                request.automaticallyDetectsLanguage = false
                request.recognitionLanguages = recognitionLanguages
            } else {
                request.automaticallyDetectsLanguage = true
            }

            do {
                try requestHandler(request)
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
        try await recognize(
            region: region,
            sourceApplication: sourceApplication,
            profile: .generalOCR,
            authorizationCheck: authorizationCheck
        )
    }

    func recognize(
        region: ScreenRegionSelection,
        sourceApplication: NSRunningApplication,
        profile: VisionTextRecognitionProfile,
        authorizationCheck: @MainActor () -> Bool
    ) async throws -> ScreenTextOCRResult {
        let recognitionConfiguration = profile.configuration
        guard authorizationCheck() else { throw CancellationError() }
        if case .generalOCR = profile {
            return try await recognizeTiledRegion(
                region: region,
                sourceApplication: sourceApplication,
                recognitionConfiguration: recognitionConfiguration,
                authorizationCheck: authorizationCheck
            )
        }
        let image = try await capture(
            region: region,
            sourceApplication: sourceApplication,
            recognitionConfiguration: recognitionConfiguration,
            authorizationCheck: authorizationCheck
        )
        try Task.checkCancellation()
        guard authorizationCheck() else { throw CancellationError() }
        let sendableImage = SendableCGImage(value: image)
        let recognitionTask = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try ScreenTextOCRRecognizer.recognize(
                in: sendableImage.value,
                configuration: recognitionConfiguration
            )
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

    private struct CaptureContext {
        let filter: SCContentFilter
        let sourceRect: CGRect
        let pixelScale: CGFloat
    }

    private func recognizeTiledRegion(
        region: ScreenRegionSelection,
        sourceApplication: NSRunningApplication,
        recognitionConfiguration: VisionTextRecognitionConfiguration,
        authorizationCheck: @MainActor () -> Bool
    ) async throws -> ScreenTextOCRResult {
        let context = try await prepareCaptureContext(
            region: region,
            sourceApplication: sourceApplication,
            authorizationCheck: authorizationCheck
        )
        let tiles = OCRTilePlanner.tiles(
            in: context.sourceRect,
            pixelScale: context.pixelScale,
            pixelBudget: recognitionConfiguration.pixelBudget
        )
        var results: [ScreenTextOCRResult] = []
        results.reserveCapacity(min(tiles.count, 16))

        for tile in tiles {
            try Task.checkCancellation()
            guard authorizationCheck() else { throw CancellationError() }
            let image = try await captureImage(
                context: context,
                sourceRect: tile,
                recognitionConfiguration: recognitionConfiguration,
                preservesNativeResolution: true
            )
            try Task.checkCancellation()
            guard authorizationCheck() else { throw CancellationError() }
            let sendableImage = SendableCGImage(value: image)
            do {
                let recognitionTask = Task.detached(priority: .userInitiated) {
                    try Task.checkCancellation()
                    return try ScreenTextOCRRecognizer.recognize(
                        in: sendableImage.value,
                        configuration: recognitionConfiguration
                    )
                }
                let result = try await withTaskCancellationHandler {
                    try await recognitionTask.value
                } onCancel: {
                    recognitionTask.cancel()
                }
                try Task.checkCancellation()
                guard authorizationCheck() else { throw CancellationError() }
                results.append(result)
            } catch ScreenTextOCRError.noTextRecognized {
                continue
            }
        }
        guard authorizationCheck() else { throw CancellationError() }
        return try Self.mergedTileResults(results)
    }

    nonisolated private static func mergedTileResults(
        _ results: [ScreenTextOCRResult]
    ) throws -> ScreenTextOCRResult {
        var lines: [String] = []
        var recentLines: [String] = []
        var confidenceTotal: Float = 0
        var confidenceWeight = 0
        for result in results {
            confidenceTotal += result.averageConfidence * Float(max(result.lineCount, 1))
            confidenceWeight += max(result.lineCount, 1)
            for line in result.text.components(separatedBy: .newlines) {
                let normalized = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !normalized.isEmpty else { continue }
                if recentLines.contains(normalized) { continue }
                lines.append(normalized)
                recentLines.append(normalized)
                if recentLines.count > 4 { recentLines.removeFirst() }
            }
        }
        guard let text = SelectionTextNormalizer.normalizedText(
            from: lines.joined(separator: "\n"),
            maximumCharacters: TranslationLimits.maxOCRCharacters
        ) else {
            throw ScreenTextOCRError.noTextRecognized
        }
        return ScreenTextOCRResult(
            text: text,
            lineCount: lines.count,
            averageConfidence: confidenceWeight > 0
                ? confidenceTotal / Float(confidenceWeight)
                : 0
        )
    }

    /// Starts the continuous, source-App-only subtitle capture path. The
    /// expensive shareable-content lookup and filter creation happen once per
    /// user-approved region, not once per frame.
    func startSubtitleCaptureStream(
        region: ScreenRegionSelection,
        sourceApplication: NSRunningApplication,
        authorizationCheck: @MainActor () -> Bool
    ) async throws -> SubtitleCaptureStream {
        let context = try await prepareCaptureContext(
            region: region,
            sourceApplication: sourceApplication,
            authorizationCheck: authorizationCheck
        )
        // `SCShareableContent` is asynchronous; do not let a permission or
        // privacy-policy change during that await create a stream afterwards.
        guard authorizationCheck() else { throw CancellationError() }
        let sourceRect = context.sourceRect
        let requestedWidth = max(Int(sourceRect.width * context.pixelScale), 1)
        let requestedHeight = max(Int(sourceRect.height * context.pixelScale), 1)
        let captureSize = VisionTextRecognitionProfile.liveSubtitle.configuration.fittedPixelSize(
            width: requestedWidth,
            height: requestedHeight
        )
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = sourceRect
        configuration.width = captureSize.width
        configuration.height = captureSize.height
        configuration.showsCursor = false
        configuration.queueDepth = 2
        // The subtitle fingerprint sampler uses a single packed plane; lock
        // the stream to the same well-supported format Vision accepts.
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        // The stream may receive more display callbacks, but the consumer only
        // takes its latest slot at the adaptive 4/2 fps cadence.
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 4)

        let stream = try SubtitleCaptureStream(
            filter: context.filter,
            configuration: configuration
        )
        guard authorizationCheck() else {
            await stream.stop()
            throw CancellationError()
        }
        do {
            try await stream.start()
            guard authorizationCheck() else {
                await stream.stop()
                throw CancellationError()
            }
            return stream
        } catch {
            await stream.stop()
            throw error
        }
    }

    private func capture(
        region: ScreenRegionSelection,
        sourceApplication: NSRunningApplication,
        recognitionConfiguration: VisionTextRecognitionConfiguration,
        authorizationCheck: @MainActor () -> Bool
    ) async throws -> CGImage {
        let context = try await prepareCaptureContext(
            region: region,
            sourceApplication: sourceApplication,
            authorizationCheck: authorizationCheck
        )
        let image = try await captureImage(
            context: context,
            sourceRect: context.sourceRect,
            recognitionConfiguration: recognitionConfiguration,
            preservesNativeResolution: false
        )
        try Task.checkCancellation()
        guard authorizationCheck() else { throw CancellationError() }
        return image
    }

    private func prepareCaptureContext(
        region: ScreenRegionSelection,
        sourceApplication: NSRunningApplication,
        authorizationCheck: @MainActor () -> Bool
    ) async throws -> CaptureContext {
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
        // The user can revoke permission or change the per-App privacy policy
        // while ScreenCaptureKit enumerates shareable content.
        guard authorizationCheck() else { throw CancellationError() }
        guard let display = content.displays.first(where: { $0.displayID == region.displayID }) else {
            throw ScreenTextOCRError.displayUnavailable
        }

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
        return CaptureContext(
            filter: filter,
            sourceRect: sourceRect,
            pixelScale: max(CGFloat(filter.pointPixelScale), 1)
        )
    }

    private func captureImage(
        context: CaptureContext,
        sourceRect: CGRect,
        recognitionConfiguration: VisionTextRecognitionConfiguration,
        preservesNativeResolution: Bool
    ) async throws -> CGImage {
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = sourceRect
        let requestedWidth = max(Int(sourceRect.width * context.pixelScale), 1)
        let requestedHeight = max(Int(sourceRect.height * context.pixelScale), 1)
        let captureSize = recognitionConfiguration.fittedPixelSize(
            width: requestedWidth,
            height: requestedHeight
        )
        configuration.width = preservesNativeResolution ? requestedWidth : captureSize.width
        configuration.height = preservesNativeResolution ? requestedHeight : captureSize.height
        configuration.showsCursor = false
        configuration.queueDepth = 2

        try Task.checkCancellation()
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: context.filter,
            configuration: configuration
        )
        try Task.checkCancellation()
        return image
    }
}

/// A continuous ScreenCaptureKit bridge for explicit subtitle regions. Its
/// callback owns exactly one latest CVPixelBuffer; old frames are released as
/// soon as a newer frame arrives. It deliberately never makes a CGImage.
enum SubtitleCaptureStreamTerminal: Equatable, Sendable {
    case stopped
    case failed(message: String)

    var statusMessage: String {
        switch self {
        case .stopped:
            return "字幕画面捕获已停止。"
        case let .failed(message):
            return "字幕画面捕获已中断：\(message)"
        }
    }

    var requiresApplicationShutdown: Bool {
        if case .failed = self { return true }
        return false
    }
}

final class SubtitleCaptureStream: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private struct SendableStreamReference: @unchecked Sendable {
        let value: SCStream
    }

    private struct CaptureSettings: Sendable {
        let sourceRect: CGRect
        let width: Int
        let height: Int
        let pixelFormat: OSType
        let queueDepth: Int
        let showsCursor: Bool

        func configuration(minimumFrameInterval: CMTime) -> SCStreamConfiguration {
            let value = SCStreamConfiguration()
            value.sourceRect = sourceRect
            value.width = width
            value.height = height
            value.pixelFormat = pixelFormat
            value.queueDepth = queueDepth
            value.showsCursor = showsCursor
            value.minimumFrameInterval = minimumFrameInterval
            return value
        }
    }

    private let lifecycleLock = NSLock()
    private let sampleQueue = DispatchQueue(
        label: "local.codex.ClaudePromptTranslator.subtitle-capture",
        qos: .userInitiated
    )
    private let latestSlot = SubtitleLatestPixelBufferSlot()
    private let capturePermissionCheck: @Sendable () -> Bool
    private let captureSettings: CaptureSettings
    private var currentFrameInterval: TimeInterval
    private var startLifecycle = CaptureStartLifecycle()
    private var terminalState: SubtitleCaptureStreamTerminal?
    private var stream: SCStream?

    init(
        filter: SCContentFilter,
        configuration: SCStreamConfiguration,
        capturePermissionCheck: @escaping @Sendable () -> Bool = {
            ScreenRecordingPermission.isGranted
        }
    ) throws {
        captureSettings = CaptureSettings(
            sourceRect: configuration.sourceRect,
            width: configuration.width,
            height: configuration.height,
            pixelFormat: configuration.pixelFormat,
            queueDepth: configuration.queueDepth,
            showsCursor: configuration.showsCursor
        )
        currentFrameInterval = max(configuration.minimumFrameInterval.seconds, 0.25)
        self.capturePermissionCheck = capturePermissionCheck
        super.init()
        let createdStream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try createdStream.addStreamOutput(
            self,
            type: .screen,
            sampleHandlerQueue: sampleQueue
        )
        stream = createdStream
    }

    func start() async throws {
        let startContext: (stream: SCStream, token: CaptureStartToken)? = lifecycleLock.withLock {
            guard let stream,
                  let token = startLifecycle.beginStart() else { return nil }
            return (stream, token)
        }
        guard let startContext else { throw CancellationError() }
        let activeStream = startContext.stream
        let startToken = startContext.token
        do {
            try await activeStream.startCapture()
        } catch {
            let ownedFailedStream = lifecycleLock.withLock { () -> SCStream? in
                guard startLifecycle.failStart(startToken), stream === activeStream else {
                    return nil
                }
                terminalState = .failed(message: error.localizedDescription)
                stream = nil
                return activeStream
            }
            // `startCapture()` may fail after partially activating a stream.
            // Stop only the stream owned by this token and never a newer one.
            if let ownedFailedStream { try? await ownedFailedStream.stopCapture() }
            latestSlot.stopAndDiscard()
            throw error
        }

        let retained = lifecycleLock.withLock {
            stream === activeStream && startLifecycle.markStarted(startToken)
        }
        guard retained else {
            // `stop()` can complete while `startCapture()` is suspended. Its
            // earlier stopCapture call is not sufficient because the start may
            // win afterwards, so stop this local stream once more on return.
            try? await activeStream.stopCapture()
            throw CancellationError()
        }
    }

    /// Transfers the one retained latest buffer to Vision. A nil result simply
    /// means no complete screen frame has arrived since the prior poll.
    func takeLatestPixelBuffer() -> CVPixelBuffer? {
        latestSlot.take()
    }

    var isActive: Bool {
        lifecycleLock.withLock {
            stream != nil && startLifecycle.activeToken != nil && terminalState == nil
        }
    }

    var terminal: SubtitleCaptureStreamTerminal? {
        lifecycleLock.withLock { terminalState }
    }

    /// Applies the same adaptive 4/2 fps cadence to ScreenCaptureKit itself,
    /// not merely to the downstream Vision consumer. This avoids producing
    /// discarded 4 fps surfaces while a subtitle region is static.
    func updateMinimumFrameInterval(_ interval: TimeInterval) async throws {
        let boundedInterval = min(max(interval, 0.25), 0.5)
        let update = lifecycleLock.withLock { () -> (SCStream, SCStreamConfiguration)? in
            guard let stream,
                  abs(currentFrameInterval - boundedInterval) > 0.001 else { return nil }
            currentFrameInterval = boundedInterval
            let time = CMTime(seconds: boundedInterval, preferredTimescale: 600)
            return (stream, captureSettings.configuration(minimumFrameInterval: time))
        }
        guard let (activeStream, configuration) = update else { return }
        try await activeStream.updateConfiguration(configuration)
    }

    func stop() async {
        latestSlot.stopAndDiscard()
        let activeStream = lifecycleLock.withLock { () -> SCStream? in
            _ = startLifecycle.invalidate()
            if terminalState == nil { terminalState = .stopped }
            let activeStream = stream
            stream = nil
            return activeStream
        }
        guard let activeStream else { return }
        try? await activeStream.stopCapture()
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard capturePermissionCheck() else {
            terminateForRevokedPermission(stream)
            return
        }
        guard outputType == .screen,
              CMSampleBufferIsValid(sampleBuffer),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }
        _ = latestSlot.offer(pixelBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let wasActive = lifecycleLock.withLock {
            guard self.stream === stream else { return false }
            _ = startLifecycle.invalidate()
            terminalState = .failed(message: error.localizedDescription)
            self.stream = nil
            return true
        }
        if wasActive { latestSlot.stopAndDiscard() }
    }

    private func terminateForRevokedPermission(_ callbackStream: SCStream) {
        let streamToStop = lifecycleLock.withLock { () -> SCStream? in
            guard stream === callbackStream else { return nil }
            _ = startLifecycle.invalidate()
            terminalState = .failed(message: "屏幕录制权限已撤销")
            stream = nil
            return callbackStream
        }
        guard let streamToStop else { return }
        latestSlot.stopAndDiscard()
        let reference = SendableStreamReference(value: streamToStop)
        Task { try? await reference.value.stopCapture() }
    }
}

/// Pure token/state coordinator for ScreenCaptureKit's asynchronous start.
/// `invalidate()` is synchronous so callers can make an in-flight start stale
/// before awaiting `stopCapture()`. A stale completion must stop its local
/// stream instead of publishing it as active.
struct CaptureStartToken: Equatable, Sendable {
    let generation: UInt64
}

struct CaptureStartLifecycle: Sendable {
    private enum Phase: Equatable, Sendable {
        case idle
        case starting(CaptureStartToken)
        case running(CaptureStartToken)
    }

    private var nextGeneration: UInt64 = 0
    private var phase: Phase = .idle

    mutating func beginStart() -> CaptureStartToken? {
        guard phase == .idle else { return nil }
        nextGeneration &+= 1
        let token = CaptureStartToken(generation: nextGeneration)
        phase = .starting(token)
        return token
    }

    mutating func markStarted(_ token: CaptureStartToken) -> Bool {
        guard phase == .starting(token) else { return false }
        phase = .running(token)
        return true
    }

    @discardableResult
    mutating func failStart(_ token: CaptureStartToken) -> Bool {
        guard phase == .starting(token) else { return false }
        phase = .idle
        return true
    }

    @discardableResult
    mutating func invalidate() -> CaptureStartToken? {
        let token: CaptureStartToken?
        switch phase {
        case .idle:
            token = nil
        case let .starting(active), let .running(active):
            token = active
        }
        phase = .idle
        return token
    }

    func accepts(_ token: CaptureStartToken) -> Bool {
        switch phase {
        case .idle:
            return false
        case let .starting(active), let .running(active):
            return active == token
        }
    }

    var activeToken: CaptureStartToken? {
        switch phase {
        case .idle:
            return nil
        case let .starting(token), let .running(token):
            return token
        }
    }

    var isActive: Bool { activeToken != nil }
}

/// The only retained capture payload between ScreenCaptureKit callbacks and
/// Vision. It is deliberately a one-item overwrite slot, and `stopAndDiscard`
/// makes late callbacks no-ops before releasing its final buffer.
final class SubtitleLatestPixelBufferSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var latestPixelBuffer: CVPixelBuffer?
    private var isStopped = false

    @discardableResult
    func offer(_ pixelBuffer: CVPixelBuffer) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isStopped else { return false }
        // Strong assignment retains this callback-owned Core Video surface and
        // atomically releases the prior one, so the slot can never grow.
        latestPixelBuffer = pixelBuffer
        return true
    }

    func take() -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        let buffer = latestPixelBuffer
        latestPixelBuffer = nil
        return buffer
    }

    func stopAndDiscard() {
        lock.withLock {
            isStopped = true
            latestPixelBuffer = nil
        }
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
