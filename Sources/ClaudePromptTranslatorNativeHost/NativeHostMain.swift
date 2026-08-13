import Darwin
import Foundation
#if canImport(BrowserNativeBridgeShared)
import BrowserNativeBridgeShared
#endif

@main
enum ClaudePromptTranslatorNativeHostMain {
    static func main() {
        let output: Data
        do {
            let request = try BrowserNativeSocketTransport.readNativeFrame(
                fileDescriptor: STDIN_FILENO
            )
            let binding = try BrowserNativeSocketTransport.requestBinding(from: request)
            let response = try BrowserNativeSocketTransport.exchange(requestFrame: request)
            try BrowserNativeSocketTransport.validateResponse(response, for: binding)
            output = response
        } catch BrowserNativeSocketTransport.TransportError.invalidFrame,
                BrowserNativeSocketTransport.TransportError.oversizedFrame {
            output = BrowserNativeSocketTransport.nativeErrorFrame(code: "invalidRequest")
        } catch BrowserNativeSocketTransport.TransportError.invalidResponse {
            output = BrowserNativeSocketTransport.nativeErrorFrame(code: "invalidResponse")
        } catch {
            output = BrowserNativeSocketTransport.nativeErrorFrame(code: "appUnavailable")
        }

        guard !output.isEmpty,
              (try? BrowserNativeSocketTransport.writeAll(
                output,
                fileDescriptor: STDOUT_FILENO
              )) != nil else {
            Darwin.exit(1)
        }
    }
}
