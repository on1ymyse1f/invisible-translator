import AppKit

final class AIResponseHarnessDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var composer: NSTextView?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        let title = NSTextField(labelWithString: "Synthetic ChatGPT Response Test")
        title.font = .systemFont(ofSize: 24, weight: .bold)

        let privacyNote = NSTextField(
            wrappingLabelWithString: "This local-only window contains synthetic text, has no Send action, and never connects to a network."
        )
        privacyNote.textColor = .secondaryLabelColor

        let composerMarker = markerLabel("ChatGPT draft input (no Send button):")
        let composerScrollView = makeComposer()
        let userMarker = markerLabel("You said:")
        let userText = bodyLabel(
            "Please provide a short synthetic reply for a local translation regression test."
        )
        let assistantMarker = markerLabel("ChatGPT said:")
        let assistantResponse = selectableResponse(
            "Translation safety matters because the application must identify only the latest assistant response, keep private data on this Mac, and never mistake the user's prompt for the reply."
        )

        let stack = NSStackView(views: [
            title,
            privacyNote,
            separator(),
            composerMarker,
            composerScrollView,
            separator(),
            userMarker,
            userText,
            separator(),
            assistantMarker,
            assistantResponse
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 28, left: 32, bottom: 28, right: 32)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let contentView = NSView()
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor),
            privacyNote.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -64),
            composerScrollView.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -64),
            composerScrollView.heightAnchor.constraint(equalToConstant: 104),
            userText.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -64),
            assistantResponse.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -64),
            assistantResponse.heightAnchor.constraint(equalToConstant: 92)
        ])

        let window = NSWindow(
            contentRect: NSRect(x: 260, y: 120, width: 760, height: 650),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "ChatGPT Synthetic Response Test"
        window.contentView = contentView
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        if let composer {
            window.makeFirstResponder(composer)
        }
        self.window = window
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func markerLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        return label
    }

    private func bodyLabel(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 17)
        label.maximumNumberOfLines = 0
        return label
    }

    private func selectableResponse(_ text: String) -> NSScrollView {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 640, height: 88))
        textView.font = .systemFont(ofSize: 17)
        textView.string = text
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.setAccessibilityLabel("Synthetic assistant response")
        textView.setAccessibilityIdentifier("synthetic-assistant-response")

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.documentView = textView
        scrollView.setAccessibilityIdentifier("synthetic-assistant-response-scroll")
        return scrollView
    }

    private func makeComposer() -> NSScrollView {
        let syntheticDraft = "请把这段合成草稿翻译成英文，只用于本地回归测试，不要发送。"
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 640, height: 96))
        textView.font = .systemFont(ofSize: 17)
        textView.string = syntheticDraft
        textView.isRichText = false
        textView.allowsUndo = true
        textView.setSelectedRange(NSRange(location: 0, length: (syntheticDraft as NSString).length))
        // Match the strict production composer heuristics ("message chatgpt")
        // instead of succeeding only through the broad infer-AI fallback.
        textView.setAccessibilityLabel("Message ChatGPT — synthetic draft")
        textView.setAccessibilityIdentifier("synthetic-chatgpt-composer")

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.documentView = textView
        scrollView.setAccessibilityIdentifier("synthetic-chatgpt-composer-scroll")
        composer = textView
        return scrollView
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }
}

let application = NSApplication.shared
let delegate = AIResponseHarnessDelegate()
application.delegate = delegate
application.run()
