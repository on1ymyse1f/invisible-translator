#if DEBUG
import AppKit
import CryptoKit
import Foundation

enum SelfTestRunner {
    enum Operation {
        case paste(pid: pid_t, text: String)
        case setInput(pid: pid_t, text: String)
        case inspectInput(pid: pid_t)
        case selection(pid: pid_t)
        case selectedResponse(pid: pid_t)
        case response(pid: pid_t)
        case inline(pid: pid_t)
    }

    struct Configuration {
        let operation: Operation
        let outputURL: URL
    }

    static func configuration(from arguments: [String]) -> Configuration? {
        guard let operation = operation(from: arguments) else {
            return nil
        }
        return Configuration(
            operation: operation,
            outputURL: outputURL(from: arguments)
        )
    }

    private static func operation(from arguments: [String]) -> Operation? {
        if let marker = arguments.firstIndex(of: "--self-test-paste") {
            let remaining = arguments[(marker + 1)...]
            guard remaining.count >= 2, let pid = Int32(remaining[remaining.startIndex]) else {
                return nil
            }
            let textIndex = remaining.index(after: remaining.startIndex)
            let text = remaining[textIndex...]
                .prefix { $0 != "--self-test-output" }
                .joined(separator: " ")
            return text.isEmpty ? nil : .paste(pid: pid, text: text)
        }

        if let marker = arguments.firstIndex(of: "--self-test-set-input") {
            let remaining = arguments[(marker + 1)...]
            guard remaining.count >= 2, let pid = Int32(remaining[remaining.startIndex]) else {
                return nil
            }
            let textIndex = remaining.index(after: remaining.startIndex)
            let text = remaining[textIndex...]
                .prefix { $0 != "--self-test-output" }
                .joined(separator: " ")
            return .setInput(pid: pid, text: text)
        }

        let singleArgumentOperations: [(String, (pid_t) -> Operation)] = [
            ("--self-test-inspect-input", { Operation.inspectInput(pid: $0) }),
            ("--self-test-selection", { Operation.selection(pid: $0) }),
            ("--self-test-selected-response", { Operation.selectedResponse(pid: $0) }),
            ("--self-test-inline", { Operation.inline(pid: $0) }),
            ("--self-test-response", { Operation.response(pid: $0) })
        ]
        for (marker, makeOperation) in singleArgumentOperations {
            guard let index = arguments.firstIndex(of: marker) else { continue }
            let pidIndex = arguments.index(after: index)
            guard pidIndex < arguments.endIndex, let pid = Int32(arguments[pidIndex]) else {
                return nil
            }
            return makeOperation(pid)
        }

        return nil
    }

    private static func outputURL(from arguments: [String]) -> URL {
        if let marker = arguments.firstIndex(of: "--self-test-output") {
            let valueIndex = arguments.index(after: marker)
            if valueIndex < arguments.endIndex, arguments[valueIndex].hasPrefix("/") {
                return URL(fileURLWithPath: arguments[valueIndex]).standardizedFileURL
            }
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cpt-self-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return directory.appendingPathComponent("result.txt")
    }

    @MainActor
    static func run(_ configuration: Configuration) {
        Task {
            do {
                guard AccessibilityPermission.isTrusted else {
                    throw DeliveryError.accessibilityPermissionRequired
                }

                let fields = try await execute(configuration.operation)
                var reportFields = fields
                reportFields["result"] = "ok"
                try writeReport(reportFields, to: configuration.outputURL)
                NSApp.terminate(nil)
            } catch {
                try? writeReport(
                    [
                        "result": "error",
                        "error_code": errorCode(error),
                        "error_type": String(describing: type(of: error)),
                        "error": sanitized(error.localizedDescription)
                    ],
                    to: configuration.outputURL
                )
                NSApp.terminate(nil)
            }
        }
    }

    @MainActor
    private static func execute(_ operation: Operation) async throws -> [String: String] {
        switch operation {
        case let .paste(pid, text):
            guard let target = NSRunningApplication(processIdentifier: pid) else {
                throw SelfTestError.targetNotFound(pid)
            }
            let output = try await AutomaticTranslationClient().translate(text, to: .english)
            try await TextDeliveryService().deliver(
                output.text,
                to: InputTarget(app: target),
                allowClipboardFallback: true
            )
            return summary(
                operation: "paste",
                source: text,
                output: output.text,
                extra: ["provider": output.providerName]
            )

        case let .setInput(pid, text):
            guard let app = NSRunningApplication(processIdentifier: pid) else {
                throw SelfTestError.targetNotFound(pid)
            }
            try await activateAndWait(for: app)
            guard let target = InputTarget.captureTextTarget(from: app)
                ?? InputTarget.capture(from: app, inferAIInputArea: true) else {
                throw SelfTestError.inputTargetNotFound
            }
            let replacementScope = target.readableConcreteTextValue.map {
                InputReplacementScope.all(expectedValue: $0)
            } ?? .insertAtCursor
            try await TextDeliveryService().replaceCurrentInput(
                with: text,
                in: target,
                scope: replacementScope,
                allowClipboardFallback: true
            )
            return summary(operation: "set_input", source: "", output: text)

        case let .inspectInput(pid):
            guard let app = NSRunningApplication(processIdentifier: pid) else {
                throw SelfTestError.targetNotFound(pid)
            }
            try await activateAndWait(for: app)
            let recognitionStartedAt = CFAbsoluteTimeGetCurrent()
            guard let target = InputTarget.captureTextTarget(from: app)
                ?? InputTarget.capture(from: app, inferAIInputArea: true) else {
                throw SelfTestError.inputTargetNotFound
            }
            let recognitionMilliseconds = Int(
                ((CFAbsoluteTimeGetCurrent() - recognitionStartedAt) * 1_000).rounded()
            )
            let text = target.currentText() ?? ""
            let translationSource = await TextDeliveryService().readCurrentInput(
                from: target,
                allowClipboardFallback: true
            )
            let sourceText = translationSource?.text ?? ""
            let candidateCount = InputTarget.debugTextInputCandidates(in: app).count
            return [
                "operation": "inspect_input",
                "recognition_ms": String(recognitionMilliseconds),
                "window_identity_stable": String(target.matchesCurrentWindow),
                "text_length": String(text.count),
                "text_sha256": digest(text),
                "source_length": String(sourceText.count),
                "source_sha256": digest(sourceText),
                "scope": translationSource?.usesSelection == true ? "selection" : "all",
                "translatable": String(InputTarget.isTranslatableInputText(text)),
                "anchor_available": String(target.anchorRect != nil),
                "candidate_count": String(candidateCount),
                "contains_raw_text": "false"
            ]

        case let .selection(pid):
            guard let app = NSRunningApplication(processIdentifier: pid) else {
                throw SelfTestError.targetNotFound(pid)
            }
            try await activateAndWait(for: app)
            try await Task.sleep(nanoseconds: 100_000_000)
            let pasteboardChangeCount = NSPasteboard.general.changeCount
            guard let selection = try await UniversalSelectionReader().capture(
                from: app,
                scanPolicy: .focusedPath,
                allowClipboardFallback: false
            ) else {
                throw SelfTestError.selectionNotFound
            }
            return [
                "operation": "selection",
                "capture_method": selection.captureMethod.rawValue,
                "source_length": String(selection.text.count),
                "source_sha256": digest(selection.text),
                "anchor_available": String(selection.anchorRect != nil),
                "clipboard_unchanged": String(
                    NSPasteboard.general.changeCount == pasteboardChangeCount
                ),
                "ocr_used": "false",
                "contains_raw_text": "false"
            ]

        case let .response(pid):
            guard let app = NSRunningApplication(processIdentifier: pid) else {
                throw SelfTestError.targetNotFound(pid)
            }
            try await activateAndWait(for: app)
            try await Task.sleep(nanoseconds: 100_000_000)
            guard let response = await AIResponseReader().latestForeignResponse(
                in: app,
                allowOCR: false
            ) else {
                throw SelfTestError.responseNotFound
            }
            return [
                "operation": "response",
                "language": response.language.displayName,
                "capture_source": response.captureSource.rawValue,
                "source_length": String(response.text.count),
                "source_sha256": digest(response.text),
                "ocr_allowed": "false",
                "contains_raw_text": "false"
            ]

        case let .selectedResponse(pid):
            guard let app = NSRunningApplication(processIdentifier: pid) else {
                throw SelfTestError.targetNotFound(pid)
            }
            try await activateAndWait(for: app)
            guard let element = accessibilityElement(
                withIdentifier: "synthetic-assistant-response",
                in: app
            ),
            let fullText = stringAttribute(kAXValueAttribute, from: element) else {
                throw SelfTestError.responseNotFound
            }
            let fullLength = (fullText as NSString).length
            let selectedLength = min(56, fullLength)
            guard selectedLength > 0 else {
                throw SelfTestError.responseNotFound
            }

            _ = AXUIElementSetAttributeValue(
                element,
                kAXFocusedAttribute as CFString,
                kCFBooleanTrue
            )
            try await Task.sleep(nanoseconds: 80_000_000)
            var selectedRange = CFRange(location: 0, length: selectedLength)
            guard let rangeValue = AXValueCreate(.cfRange, &selectedRange),
                  AXUIElementSetAttributeValue(
                    element,
                    kAXSelectedTextRangeAttribute as CFString,
                    rangeValue
                  ) == .success else {
                throw SelfTestError.selectionNotFound
            }
            try await Task.sleep(nanoseconds: 80_000_000)

            let clipboardChangeCount = NSPasteboard.general.changeCount
            guard let response = AIResponseReader().selectedForeignResponse(in: app) else {
                throw SelfTestError.responseNotFound
            }
            return [
                "operation": "selected_response",
                "capture_source": response.captureSource.rawValue,
                "selection_preferred": String(
                    response.text.count < fullText.count
                        && response.text == String(fullText.prefix(response.text.count))
                ),
                "source_length": String(response.text.count),
                "source_sha256": digest(response.text),
                "clipboard_unchanged": String(
                    NSPasteboard.general.changeCount == clipboardChangeCount
                ),
                "ocr_used": "false",
                "contains_raw_text": "false"
            ]

        case let .inline(pid):
            guard let app = NSRunningApplication(processIdentifier: pid) else {
                throw SelfTestError.targetNotFound(pid)
            }
            try await activateAndWait(for: app)
            guard let target = InputTarget.captureTextTarget(from: app)
                ?? InputTarget.capture(from: app, inferAIInputArea: true) else {
                throw SelfTestError.inputTargetNotFound
            }
            guard let source = await TextDeliveryService().readCurrentInput(
                from: target,
                allowClipboardFallback: true
            ) else {
                throw DeliveryError.emptyInput
            }
            guard InputTarget.isTranslatableInputText(source.text, to: .english) else {
                throw DeliveryError.nonTranslatableInput
            }
            let output = try await AutomaticTranslationClient().translate(source.text, to: .english)
            try await TextDeliveryService().replaceCurrentInput(
                with: output.text,
                in: target,
                scope: source.replacementScope,
                allowClipboardFallback: true
            )
            return summary(
                operation: "inline",
                source: source.text,
                output: output.text,
                extra: [
                    "provider": output.providerName,
                    "scope": source.usesSelection ? "selection" : "all",
                    "message_sent": "false"
                ]
            )
        }
    }

    private static func summary(
        operation: String,
        source: String,
        output: String,
        extra: [String: String] = [:]
    ) -> [String: String] {
        [
            "operation": operation,
            "source_length": String(source.count),
            "source_sha256": digest(source),
            "output_length": String(output.count),
            "output_sha256": digest(output),
            "contains_raw_text": "false"
        ].merging(extra) { _, replacement in replacement }
    }

    @MainActor
    private static func activateAndWait(for app: NSRunningApplication) async throws {
        for _ in 0..<12 {
            guard !app.isTerminated else {
                throw SelfTestError.targetNotFound(app.processIdentifier)
            }
            if app.isActive,
               NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier {
                return
            }
            app.activate(options: [.activateIgnoringOtherApps])
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard app.isActive,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
            throw DeliveryError.targetAppChanged
        }
    }

    private static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func accessibilityElement(
        withIdentifier identifier: String,
        in app: NSRunningApplication
    ) -> AXUIElement? {
        var queue = [AXUIElementCreateApplication(app.processIdentifier)]
        var cursor = 0
        var visited = 0
        while cursor < queue.count, visited < 1_200 {
            let element = queue[cursor]
            cursor += 1
            visited += 1
            if stringAttribute(kAXIdentifierAttribute, from: element) == identifier {
                return element
            }
            var childrenValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                element,
                kAXChildrenAttribute as CFString,
                &childrenValue
            ) == .success,
            let children = childrenValue as? [AXUIElement] {
                queue.append(contentsOf: children)
            }
        }
        return nil
    }

    private static func stringAttribute(
        _ attribute: String,
        from element: AXUIElement
    ) -> String? {
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

    private static func sanitized(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .prefix(240)
            .description
    }

    private static func errorCode(_ error: Error) -> String {
        if let deliveryError = error as? DeliveryError {
            switch deliveryError {
            case .accessibilityPermissionRequired:
                return "accessibility_permission_required"
            case .targetInputUnavailable:
                return "target_input_unavailable"
            case .emptyInput:
                return "empty_input"
            case .nonTranslatableInput:
                return "non_translatable_input"
            case .inputChanged:
                return "input_changed"
            case .inputWriteVerificationFailed:
                return "input_write_verification_failed"
            case .targetAppChanged:
                return "target_app_changed"
            case .clipboardCompatibilityDisabled:
                return "clipboard_compatibility_disabled"
            }
        }
        if let unavailableError = error as? TranslationProviderUnavailableError {
            switch unavailableError {
            case .languageCouldNotBeDetermined:
                return "language_could_not_be_determined"
            case .languagePairNotInstalled:
                return "language_pair_not_installed"
            case .unsupportedLanguagePair:
                return "unsupported_language_pair"
            case .localOnlyModeUnsupported:
                return "local_only_mode_unsupported"
            }
        }
        if let selfTestError = error as? SelfTestError {
            switch selfTestError {
            case .targetNotFound:
                return "target_not_found"
            case .inputTargetNotFound:
                return "input_target_not_found"
            case .selectionNotFound:
                return "selection_not_found"
            case .responseNotFound:
                return "response_not_found"
            }
        }
        if error is CancellationError {
            return "cancelled"
        }
        return "unexpected_error"
    }

    private static func writeReport(_ fields: [String: String], to outputURL: URL) throws {
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let report = fields.keys.sorted()
            .map { "\($0)=\(sanitized(fields[$0] ?? ""))" }
            .joined(separator: "\n") + "\n"
        try report.write(to: outputURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: outputURL.path
        )
    }
}

enum SelfTestError: LocalizedError {
    case targetNotFound(pid_t)
    case inputTargetNotFound
    case selectionNotFound
    case responseNotFound

    var errorDescription: String? {
        switch self {
        case .targetNotFound(let pid):
            return "Target process \(pid) was not found."
        case .inputTargetNotFound:
            return "No editable input target was found."
        case .selectionNotFound:
            return "No Accessibility selection was found; clipboard and OCR remained disabled."
        case .responseNotFound:
            return "No Accessibility response was found; OCR remained disabled."
        }
    }
}
#endif
