import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSTextViewDelegate {
    private var window: NSWindow?
    private lazy var outputURL: URL = {
        if let path = ProcessInfo.processInfo.environment["CPT_PASTE_CAPTURE_OUTPUT"],
           path.hasPrefix("/") {
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cpt-paste-capture-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return directory.appendingPathComponent("capture.txt")
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 560, height: 260))
        textView.delegate = self
        textView.font = .systemFont(ofSize: 18)
        textView.string = ""
        textView.isRichText = false
        textView.allowsUndo = true

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 560, height: 260))
        scrollView.hasVerticalScroller = true
        scrollView.documentView = textView

        let window = NSWindow(
            contentRect: NSRect(x: 220, y: 220, width: 560, height: 260),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Paste Capture"
        window.contentView = scrollView
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        window.makeFirstResponder(textView)

        self.window = window
        write("")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func textDidChange(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView else {
            return
        }
        write(textView.string)
    }

    private func write(_ text: String) {
        try? FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? text.write(to: outputURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: outputURL.path
        )
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
