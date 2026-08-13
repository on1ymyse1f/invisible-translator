import Darwin
import Foundation

public enum BrowserNativeSocketTransport {
    public static let maximumFrameBytes = 256 * 1_024
    public static let protocolVersion = 1
    public static let socketFileName = "bridge.sock"

    public enum TransportError: Error, Equatable {
        case invalidFrame
        case oversizedFrame
        case insecureSocket
        case socketUnavailable
        case ioFailure
        case invalidResponse
    }

    public struct RequestBinding: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            case settings
            case translation(requestID: String, kind: String)
        }

        public let origin: String
        public let kind: Kind
    }

    public static func defaultSocketURL() -> URL {
#if DEBUG
        if let testPath = ProcessInfo.processInfo.environment["CPT_TEST_BROWSER_NATIVE_SOCKET"],
           testPath.hasPrefix("/"),
           !testPath.isEmpty {
            return URL(fileURLWithPath: testPath)
        }
#endif
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return applicationSupport
            .appendingPathComponent("ClaudePromptTranslator", isDirectory: true)
            .appendingPathComponent("BrowserNativeBridge", isDirectory: true)
            .appendingPathComponent(socketFileName)
    }

    public static func readNativeFrame(
        fileDescriptor: Int32,
        maximumBytes: Int = maximumFrameBytes
    ) throws -> Data {
        let header = try readExactly(
            count: MemoryLayout<UInt32>.size,
            fileDescriptor: fileDescriptor
        )
        let length = header.withUnsafeBytes {
            $0.loadUnaligned(as: UInt32.self).littleEndian
        }
        guard length > 0 else { throw TransportError.invalidFrame }
        guard length <= UInt32(maximumBytes) else { throw TransportError.oversizedFrame }
        var frame = header
        frame.append(try readExactly(count: Int(length), fileDescriptor: fileDescriptor))
        return frame
    }

    public static func writeAll(_ data: Data, fileDescriptor: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                throw TransportError.ioFailure
            }
            var written = 0
            while written < rawBuffer.count {
                let result = Darwin.write(
                    fileDescriptor,
                    baseAddress.advanced(by: written),
                    rawBuffer.count - written
                )
                if result > 0 {
                    written += result
                } else if result < 0, errno == EINTR {
                    continue
                } else {
                    throw TransportError.ioFailure
                }
            }
        }
    }

    public static func payload(from frame: Data) throws -> Data {
        guard frame.count >= 4 else { throw TransportError.invalidFrame }
        let length = frame.prefix(4).withUnsafeBytes {
            $0.loadUnaligned(as: UInt32.self).littleEndian
        }
        guard length > 0, length <= UInt32(maximumFrameBytes) else {
            throw TransportError.oversizedFrame
        }
        guard frame.count == 4 + Int(length) else { throw TransportError.invalidFrame }
        return frame.dropFirst(4)
    }

    public static func frame(payload: Data) throws -> Data {
        guard !payload.isEmpty else { throw TransportError.invalidFrame }
        guard payload.count <= maximumFrameBytes else { throw TransportError.oversizedFrame }
        var length = UInt32(payload.count).littleEndian
        var result = withUnsafeBytes(of: &length) { Data($0) }
        result.append(payload)
        return result
    }

    public static func nativeErrorFrame(code: String) -> Data {
        let allowedCodes: Set<String> = [
            "appUnavailable", "busy", "invalidRequest", "invalidResponse",
            "notAuthorized", "translationFailed", "transportFailure"
        ]
        let safeCode = allowedCodes.contains(code) ? code : "transportFailure"
        let payload = try? JSONSerialization.data(withJSONObject: [
            "type": "nativeError",
            "version": protocolVersion,
            "code": safeCode
        ], options: [.sortedKeys])
        return (try? frame(payload: payload ?? Data())) ?? Data()
    }

    public static func requestBinding(from frame: Data) throws -> RequestBinding {
        let object = try JSONSerialization.jsonObject(with: payload(from: frame))
        guard let message = object as? [String: Any],
              message["version"] as? Int == protocolVersion,
              let type = message["type"] as? String,
              let origin = message["origin"] as? String,
              !origin.isEmpty else {
            throw TransportError.invalidFrame
        }
        switch type {
        case "settingsRequest":
            return RequestBinding(origin: origin, kind: .settings)
        case "translationRequest":
            guard let requestID = message["requestId"] as? String,
                  !requestID.isEmpty,
                  let kind = message["kind"] as? String,
                  !kind.isEmpty else {
                throw TransportError.invalidFrame
            }
            return RequestBinding(
                origin: origin,
                kind: .translation(requestID: requestID, kind: kind)
            )
        default:
            throw TransportError.invalidFrame
        }
    }

    public static func validateResponse(
        _ responseFrame: Data,
        for request: RequestBinding
    ) throws {
        let object = try JSONSerialization.jsonObject(with: payload(from: responseFrame))
        guard let response = object as? [String: Any],
              response["version"] as? Int == protocolVersion,
              let type = response["type"] as? String else {
            throw TransportError.invalidResponse
        }
        if type == "nativeError" {
            guard response.keys.sorted() == ["code", "type", "version"],
                  response["code"] is String else {
                throw TransportError.invalidResponse
            }
            return
        }
        guard response["origin"] as? String == request.origin else {
            throw TransportError.invalidResponse
        }
        switch request.kind {
        case .settings:
            guard type == "extensionSettings" else { throw TransportError.invalidResponse }
        case .translation(let requestID, let kind):
            guard type == "translationResult",
                  response["requestId"] as? String == requestID,
                  response["kind"] as? String == kind else {
                throw TransportError.invalidResponse
            }
        }
    }

    public static func exchange(
        requestFrame: Data,
        socketURL: URL = defaultSocketURL()
    ) throws -> Data {
        guard secureSocketNode(at: socketURL, owner: geteuid()) else {
            throw TransportError.insecureSocket
        }
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw TransportError.socketUnavailable }
        defer { Darwin.close(descriptor) }
        setNoSigPipe(descriptor)
        setTimeouts(descriptor)
        let result = try withSocketAddress(path: socketURL.path) { address, length in
            Darwin.connect(descriptor, address, length)
        }
        guard result == 0 else { throw TransportError.socketUnavailable }
        try writeAll(requestFrame, fileDescriptor: descriptor)
        return try readNativeFrame(fileDescriptor: descriptor)
    }

    public static func secureSocketNode(at url: URL, owner: uid_t) -> Bool {
        var status = stat()
        guard lstat(url.path, &status) == 0 else { return false }
        let type = status.st_mode & mode_t(S_IFMT)
        return type == mode_t(S_IFSOCK)
            && status.st_uid == owner
            && status.st_mode & 0o077 == 0
    }

    public static func secureParentDirectory(of url: URL, owner: uid_t) -> Bool {
        var status = stat()
        let parent = url.deletingLastPathComponent().path
        guard lstat(parent, &status) == 0 else { return false }
        let type = status.st_mode & mode_t(S_IFMT)
        return type == mode_t(S_IFDIR)
            && status.st_uid == owner
            && status.st_mode & 0o022 == 0
    }

    public static func withSocketAddress<T>(
        path: String,
        _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T
    ) throws -> T {
        var address = sockaddr_un()
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw TransportError.socketUnavailable
        }
        address.sun_family = sa_family_t(AF_UNIX)
        let pathOffset = MemoryLayout<sockaddr_un>.offset(of: \.sun_path) ?? 0
        bytes.withUnsafeBytes { source in
            withUnsafeMutableBytes(of: &address) { destination in
                destination[pathOffset..<(pathOffset + bytes.count)].copyBytes(from: source)
            }
        }
        let length = socklen_t(pathOffset + bytes.count)
        address.sun_len = UInt8(length)
        return try withUnsafePointer(to: &address) {
            try $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                try body($0, length)
            }
        }
    }

    public static func setNoSigPipe(_ descriptor: Int32) {
        var enabled: Int32 = 1
        _ = setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &enabled,
            socklen_t(MemoryLayout<Int32>.size)
        )
    }

    public static func setTimeouts(_ descriptor: Int32) {
        var timeout = timeval(tv_sec: 15, tv_usec: 0)
        _ = setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        )
        _ = setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_SNDTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        )
    }

    private static func readExactly(count: Int, fileDescriptor: Int32) throws -> Data {
        var data = Data(count: count)
        var offset = 0
        try data.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                throw TransportError.ioFailure
            }
            while offset < count {
                let result = Darwin.read(
                    fileDescriptor,
                    baseAddress.advanced(by: offset),
                    count - offset
                )
                if result > 0 {
                    offset += result
                } else if result < 0, errno == EINTR {
                    continue
                } else {
                    throw TransportError.ioFailure
                }
            }
        }
        return data
    }
}
