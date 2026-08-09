import AppKit
import SwiftUI

struct PromptTextView: NSViewRepresentable {
    @Binding var text: String
    let isDisabled: Bool
    let focusTrigger: Int
    let palette: PromptPalette
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSubmit: onSubmit)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = SubmittingTextView()
        textView.delegate = context.coordinator
        textView.font = .systemFont(ofSize: 16)
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.allowsUndo = true
        textView.textContainerInset = NSSize(width: 14, height: 14)
        textView.backgroundColor = palette.textBackground
        textView.insertionPointColor = palette.textForeground
        textView.onReturn = { event in
            if event.modifierFlags.contains(.shift) {
                return false
            }
            onSubmit()
            return true
        }

        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = palette.textBackground
        scrollView.documentView = textView
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else {
            return
        }

        if textView.string != text {
            textView.string = text
        }
        textView.isEditable = !isDisabled
        textView.textColor = isDisabled ? palette.disabledTextForeground : palette.textForeground
        textView.backgroundColor = palette.textBackground
        textView.insertionPointColor = palette.textForeground
        scrollView.backgroundColor = palette.textBackground

        if context.coordinator.lastFocusTrigger != focusTrigger {
            context.coordinator.lastFocusTrigger = focusTrigger
            context.coordinator.focusTextView()
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding private var text: String
        let onSubmit: () -> Void
        weak var textView: NSTextView?
        var lastFocusTrigger = 0

        init(text: Binding<String>, onSubmit: @escaping () -> Void) {
            self._text = text
            self.onSubmit = onSubmit
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else {
                return
            }
            text = textView.string
        }

        func focusTextView() {
            focusTextView(after: 0)
            focusTextView(after: 0.18)
        }

        private func focusTextView(after delay: TimeInterval) {
            guard let textView else {
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak textView] in
                guard let textView else {
                    return
                }
                textView.window?.makeFirstResponder(textView)
            }
        }
    }
}

final class SubmittingTextView: NSTextView {
    var onReturn: ((NSEvent) -> Bool)?

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if isReturn, onReturn?(event) == true {
            return
        }
        super.keyDown(with: event)
    }
}
