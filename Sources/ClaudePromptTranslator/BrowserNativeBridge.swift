import Darwin
import Foundation
#if canImport(BrowserNativeBridgeShared)
import BrowserNativeBridgeShared
#endif

struct BrowserNativeBridgeSettings: Equatable, Sendable {
    let autoMode: Bool
    let hoverMode: Bool
    let hideOriginal: Bool

    func permits(_ kind: BrowserNativeMessagingProtocol.MessageKind) -> Bool {
        switch kind {
        case .page, .subtitle:
            return autoMode
        case .hover:
            return hoverMode
        }
    }
}

enum BrowserNativeDomainAuthorizationStore {
    static let defaultsKey = "browserNativeBridge.authorizedOrigins.v1"

    static func load(from defaults: UserDefaults = .standard) -> Set<String> {
        Set(defaults.stringArray(forKey: defaultsKey) ?? [])
            .intersection(BrowserNativeMessagingProtocol.allowedOrigins)
    }

    static func save(
        _ origins: Set<String>,
        to defaults: UserDefaults = .standard
    ) {
        defaults.set(
            origins.intersection(BrowserNativeMessagingProtocol.allowedOrigins).sorted(),
            forKey: defaultsKey
        )
    }
}

@MainActor
final class BrowserNativeRequestHandler {
    typealias SettingsProvider = @MainActor @Sendable (String) -> BrowserNativeBridgeSettings
    typealias TargetResolver = @MainActor @Sendable (String) -> TargetLanguage
    typealias Translator = @MainActor @Sendable (
        String,
        TargetLanguage,
        TranslationWorkKind
    ) async throws -> String

    private let settingsProvider: SettingsProvider
    private let targetResolver: TargetResolver
    private let translator: Translator

    init(
        settingsProvider: @escaping SettingsProvider,
        targetResolver: @escaping TargetResolver,
        translator: @escaping Translator
    ) {
        self.settingsProvider = settingsProvider
        self.targetResolver = targetResolver
        self.translator = translator
    }

    func responseFrame(for requestFrame: Data) async -> Data {
        do {
            let payload = try BrowserNativeSocketTransport.payload(from: requestFrame)
            let message = try BrowserNativeMessagingProtocol.decodeIncomingFrame(payload)
            let response: [String: Any]
            switch message {
            case .settings(let request):
                let settings = settingsProvider(request.origin)
                response = try BrowserNativeMessagingProtocol.extensionSettings(
                    origin: request.origin,
                    autoMode: settings.autoMode,
                    hoverMode: settings.hoverMode,
                    hideOriginal: settings.hideOriginal
                )
            case .translation(let request):
                let settings = settingsProvider(request.origin)
                guard settings.permits(request.kind) else {
                    return errorFrame(code: "notAuthorized")
                }
                let workKind: TranslationWorkKind = switch request.kind {
                case .page: .automaticSelection
                case .hover: .hover
                case .subtitle: .subtitle
                }
                var translatedItems: [(id: String, translation: String)] = []
                translatedItems.reserveCapacity(request.items.count)
                for item in request.items {
                    try Task.checkCancellation()
                    guard settingsProvider(request.origin).permits(request.kind) else {
                        return errorFrame(code: "notAuthorized")
                    }
                    let target = targetResolver(item.text)
                    let translated = try await translator(item.text, target, workKind)
                    guard settingsProvider(request.origin).permits(request.kind) else {
                        return errorFrame(code: "notAuthorized")
                    }
                    guard !translated.isEmpty else {
                        throw TranslationError.emptyTranslation
                    }
                    translatedItems.append((item.id, translated))
                }
                guard settingsProvider(request.origin).permits(request.kind) else {
                    return errorFrame(code: "notAuthorized")
                }
                response = try BrowserNativeMessagingProtocol.translationResult(
                    for: request,
                    translations: translatedItems
                )
            }
            return try BrowserNativeMessagingProtocol.encodeNativeFrame(jsonObject: response)
        } catch BrowserNativeMessagingProtocol.ValidationError.disallowedOrigin {
            return errorFrame(code: "notAuthorized")
        } catch BrowserNativeMessagingProtocol.ValidationError.oversizedFrame {
            return errorFrame(code: "invalidRequest")
        } catch is CancellationError {
            return errorFrame(code: "translationFailed")
        } catch {
            return errorFrame(code: "translationFailed")
        }
    }

    private func errorFrame(code: String) -> Data {
        let response = BrowserNativeMessagingProtocol.nativeError(code: code)
        return (try? BrowserNativeMessagingProtocol.encodeNativeFrame(jsonObject: response))
            ?? BrowserNativeSocketTransport.nativeErrorFrame(code: "transportFailure")
    }
}

enum BrowserNativeBridgeServerError: Error, Equatable {
    case insecureDirectory
    case occupiedSocket
    case socketFailure
}

final class BrowserNativeBridgeServer: @unchecked Sendable {
    typealias Handler = @Sendable (Data) async -> Data

    private let socketURL: URL
    private let handler: Handler
    private let acceptQueue = DispatchQueue(
        label: "local.codex.ClaudePromptTranslator.browser-native.accept"
    )
    private let workerQueue = DispatchQueue(
        label: "local.codex.ClaudePromptTranslator.browser-native.worker",
        attributes: .concurrent
    )
    private let stateLock = NSLock()
    private var listenDescriptor: Int32 = -1
    private var socketInode: ino_t?
    private var source: DispatchSourceRead?
    private var activeConnections = 0
    private var processingRequest = false

    init(
        socketURL: URL = BrowserNativeSocketTransport.defaultSocketURL(),
        handler: @escaping Handler
    ) {
        self.socketURL = socketURL
        self.handler = handler
    }

    deinit {
        stop()
    }

    func start() throws {
        try prepareSecureSocketDirectory()
        guard BrowserNativeSocketTransport.secureParentDirectory(
            of: socketURL,
            owner: geteuid()
        ) else {
            throw BrowserNativeBridgeServerError.insecureDirectory
        }

        if FileManager.default.fileExists(atPath: socketURL.path) {
            guard BrowserNativeSocketTransport.secureSocketNode(
                at: socketURL,
                owner: geteuid()
            ) else {
                throw BrowserNativeBridgeServerError.occupiedSocket
            }
            if socketAcceptsConnection(at: socketURL) {
                throw BrowserNativeBridgeServerError.occupiedSocket
            }
            guard unlink(socketURL.path) == 0 else {
                throw BrowserNativeBridgeServerError.socketFailure
            }
        }

        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw BrowserNativeBridgeServerError.socketFailure }
        BrowserNativeSocketTransport.setNoSigPipe(descriptor)
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)

        do {
            let bindResult = try BrowserNativeSocketTransport.withSocketAddress(
                path: socketURL.path
            ) { address, length in
                Darwin.bind(descriptor, address, length)
            }
            guard bindResult == 0,
                  chmod(socketURL.path, 0o600) == 0,
                  Darwin.listen(descriptor, 8) == 0 else {
                Darwin.close(descriptor)
                _ = unlink(socketURL.path)
                throw BrowserNativeBridgeServerError.socketFailure
            }
        } catch {
            Darwin.close(descriptor)
            _ = unlink(socketURL.path)
            throw error
        }

        var status = stat()
        guard lstat(socketURL.path, &status) == 0 else {
            Darwin.close(descriptor)
            _ = unlink(socketURL.path)
            throw BrowserNativeBridgeServerError.socketFailure
        }

        stateLock.lock()
        listenDescriptor = descriptor
        socketInode = status.st_ino
        stateLock.unlock()

        let source = DispatchSource.makeReadSource(
            fileDescriptor: descriptor,
            queue: acceptQueue
        )
        source.setEventHandler { [weak self] in
            self?.acceptConnection()
        }
        self.source = source
        source.resume()
    }

    func stop() {
        stateLock.lock()
        let descriptor = listenDescriptor
        listenDescriptor = -1
        let expectedInode = socketInode
        socketInode = nil
        let source = self.source
        self.source = nil
        stateLock.unlock()

        source?.cancel()
        if descriptor >= 0 {
            Darwin.close(descriptor)
        }
        var status = stat()
        if let expectedInode,
           lstat(socketURL.path, &status) == 0,
           status.st_uid == geteuid(),
           status.st_ino == expectedInode,
           status.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK) {
            _ = unlink(socketURL.path)
        }
    }

    private func acceptConnection() {
        stateLock.lock()
        let descriptor = listenDescriptor
        stateLock.unlock()
        guard descriptor >= 0 else { return }

        let client = Darwin.accept(descriptor, nil, nil)
        guard client >= 0 else { return }
        BrowserNativeSocketTransport.setNoSigPipe(client)
        BrowserNativeSocketTransport.setTimeouts(client)
        _ = fcntl(client, F_SETFD, FD_CLOEXEC)
        guard reserveConnection() else {
            Darwin.close(client)
            return
        }
        workerQueue.async { [weak self] in
            guard let self else {
                Darwin.close(client)
                return
            }
            self.readAndHandle(client: client)
        }
    }

    private func readAndHandle(client: Int32) {
        var peerUID: uid_t = 0
        var peerGID: gid_t = 0
        guard getpeereid(client, &peerUID, &peerGID) == 0,
              peerUID == geteuid() else {
            Darwin.close(client)
            releaseConnection()
            return
        }

        let requestFrame: Data
        do {
            requestFrame = try BrowserNativeSocketTransport.readNativeFrame(
                fileDescriptor: client
            )
        } catch {
            try? BrowserNativeSocketTransport.writeAll(
                BrowserNativeSocketTransport.nativeErrorFrame(code: "invalidRequest"),
                fileDescriptor: client
            )
            Darwin.close(client)
            releaseConnection()
            return
        }

        guard reserveProcessing() else {
            try? BrowserNativeSocketTransport.writeAll(
                BrowserNativeSocketTransport.nativeErrorFrame(code: "busy"),
                fileDescriptor: client
            )
            Darwin.close(client)
            releaseConnection()
            return
        }

        Task { [weak self] in
            guard let self else {
                Darwin.close(client)
                return
            }
            let response = await handler(requestFrame)
            try? BrowserNativeSocketTransport.writeAll(response, fileDescriptor: client)
            Darwin.close(client)
            releaseProcessing()
            releaseConnection()
        }
    }

    private func reserveConnection() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard activeConnections < 4 else { return false }
        activeConnections += 1
        return true
    }

    private func releaseConnection() {
        stateLock.lock()
        activeConnections = max(0, activeConnections - 1)
        stateLock.unlock()
    }

    private func reserveProcessing() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !processingRequest else { return false }
        processingRequest = true
        return true
    }

    private func releaseProcessing() {
        stateLock.lock()
        processingRequest = false
        stateLock.unlock()
    }

    private func socketAcceptsConnection(at url: URL) -> Bool {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }
        let result = try? BrowserNativeSocketTransport.withSocketAddress(
            path: url.path
        ) { address, length in
            Darwin.connect(descriptor, address, length)
        }
        return result == 0
    }

    private func prepareSecureSocketDirectory() throws {
        let directory = socketURL.deletingLastPathComponent()
        let parent = directory.deletingLastPathComponent()
        let applicationSupport = parent.deletingLastPathComponent()
        try validateOwnedDirectory(applicationSupport, requiresPrivateMode: false)
        var parentStatus = stat()
        if lstat(parent.path, &parentStatus) != 0 {
            guard errno == ENOENT else {
                throw BrowserNativeBridgeServerError.insecureDirectory
            }
            do {
                try FileManager.default.createDirectory(
                    at: parent,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                throw BrowserNativeBridgeServerError.insecureDirectory
            }
        }
        try validateOwnedDirectory(parent, requiresPrivateMode: false)

        var status = stat()
        if lstat(directory.path, &status) != 0 {
            guard errno == ENOENT else {
                throw BrowserNativeBridgeServerError.insecureDirectory
            }
            do {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                throw BrowserNativeBridgeServerError.insecureDirectory
            }
        }
        try validateOwnedDirectory(directory, requiresPrivateMode: true)
    }

    private func validateOwnedDirectory(
        _ directory: URL,
        requiresPrivateMode: Bool
    ) throws {
        var status = stat()
        guard lstat(directory.path, &status) == 0,
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              status.st_uid == geteuid(),
              status.st_mode & 0o022 == 0 else {
            throw BrowserNativeBridgeServerError.insecureDirectory
        }
        if requiresPrivateMode, status.st_mode & 0o077 != 0 {
            throw BrowserNativeBridgeServerError.insecureDirectory
        }
    }
}
