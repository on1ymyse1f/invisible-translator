import CryptoKit
import Darwin
import Foundation

/// Validates app-owned directory paths without resolving or following symbolic
/// links. The boundary is fixed by the caller; every existing component from
/// that boundary through the target is inspected with `lstat` before any
/// enumeration, removal, or file creation is allowed.
enum SecureOwnedDirectoryChain {
    enum ValidationError: Error, Equatable {
        case targetOutsideBoundary
        case boundaryMissing
        case symbolicLink(URL)
        case notDirectory(URL)
        case inspectionFailed(URL, Int32)
    }

    static func validateExistingDirectory(
        from boundaryURL: URL,
        through targetURL: URL
    ) throws -> Bool {
        let chain = try directoryChain(from: boundaryURL, through: targetURL)

        for (index, url) in chain.enumerated() {
            switch try itemKind(at: url) {
            case .directory:
                continue
            case .missing where index == 0:
                throw ValidationError.boundaryMissing
            case .missing:
                return false
            case .symbolicLink:
                throw ValidationError.symbolicLink(url)
            case .other:
                throw ValidationError.notDirectory(url)
            }
        }
        return true
    }

    static func createDirectoryIfNeeded(
        from boundaryURL: URL,
        through targetURL: URL,
        fileManager: FileManager,
        permissions: Int16 = 0o700
    ) throws {
        let chain = try directoryChain(from: boundaryURL, through: targetURL)

        for (index, url) in chain.enumerated() {
            switch try itemKind(at: url) {
            case .directory:
                continue
            case .missing where index == 0:
                throw ValidationError.boundaryMissing
            case .missing:
                do {
                    try fileManager.createDirectory(
                        at: url,
                        withIntermediateDirectories: false,
                        attributes: [.posixPermissions: NSNumber(value: permissions)]
                    )
                } catch {
                    // A concurrent creator is acceptable only if a fresh
                    // lstat proves that the exact component is a directory.
                    guard try itemKind(at: url) == .directory else { throw error }
                }
                guard try itemKind(at: url) == .directory else {
                    throw ValidationError.notDirectory(url)
                }
            case .symbolicLink:
                throw ValidationError.symbolicLink(url)
            case .other:
                throw ValidationError.notDirectory(url)
            }
        }

        guard try validateExistingDirectory(from: boundaryURL, through: targetURL) else {
            throw ValidationError.notDirectory(targetURL.standardizedFileURL)
        }
    }

    private enum ItemKind: Equatable {
        case missing
        case directory
        case symbolicLink
        case other
    }

    private static func directoryChain(
        from boundaryURL: URL,
        through targetURL: URL
    ) throws -> [URL] {
        let boundary = boundaryURL.standardizedFileURL
        let target = targetURL.standardizedFileURL
        guard boundary.isFileURL, target.isFileURL else {
            throw ValidationError.targetOutsideBoundary
        }

        let boundaryComponents = boundary.pathComponents
        let targetComponents = target.pathComponents
        guard targetComponents.count >= boundaryComponents.count,
              Array(targetComponents.prefix(boundaryComponents.count)) == boundaryComponents else {
            throw ValidationError.targetOutsideBoundary
        }

        var chain = [boundary]
        var current = boundary
        for component in targetComponents.dropFirst(boundaryComponents.count) {
            current.appendPathComponent(component, isDirectory: true)
            chain.append(current.standardizedFileURL)
        }
        return chain
    }

    private static func itemKind(at url: URL) throws -> ItemKind {
        var information = stat()
        errno = 0
        if lstat(url.path, &information) == 0 {
            switch information.st_mode & S_IFMT {
            case S_IFDIR:
                return .directory
            case S_IFLNK:
                return .symbolicLink
            default:
                return .other
            }
        }

        let failure = errno
        if failure == ENOENT || failure == ENOTDIR {
            return .missing
        }
        throw ValidationError.inspectionFailed(url, failure)
    }
}

enum SubtitleRecognitionMode: String, CaseIterable, Codable, Sendable {
    case regionOCR
    case systemSpeech
    case offlineASRModel
}

enum SystemSpeechAvailability: Equatable, Sendable {
    case unknown
    case unavailable
    case availableOnDevice
    case availableWithNetwork
}

protocol SystemSpeechAvailabilityProviding: Sendable {
    func availability(for localeIdentifier: String) async -> SystemSpeechAvailability
}

struct UnavailableSystemSpeechProvider: SystemSpeechAvailabilityProviding {
    func availability(for localeIdentifier: String) async -> SystemSpeechAvailability {
        _ = localeIdentifier
        return .unavailable
    }
}

struct ASRModelDescriptor: Codable, Equatable, Sendable {
    let identifier: String
    let version: String
    let downloadURL: URL
    let expectedByteCount: Int64
    let sha256Hex: String
    /// Ed25519 signature over the 32-byte SHA-256 digest, encoded as Base64.
    let digestSignatureBase64: String
}

enum ASRModelInstallationStatus: Equatable, Sendable {
    case notInstalled
    case downloading(receivedByteCount: Int64, expectedByteCount: Int64)
    case verifying
    case installed(
        descriptor: ASRModelDescriptor,
        lastUsedAt: Date,
        keepDownloaded: Bool
    )
    case failed(message: String)
}

enum ASRModelStoreError: LocalizedError, Equatable {
    case invalidIdentifier
    case invalidVersion
    case invalidHTTPSURL
    case invalidExpectedSize
    case invalidDigest
    case invalidSignature
    case invalidPublicKey
    case downloadedFileMissing
    case downloadedFileIsNotRegular
    case downloadedSizeMismatch(expected: Int64, actual: Int64)
    case disallowedDownloadHost
    case insufficientDiskSpace(required: Int64, available: Int64)
    case invalidHTTPStatus(Int)
    case missingOrMismatchedContentLength(expected: Int64, actual: Int64)
    case digestMismatch
    case signatureMismatch
    case metadataInvalid
    case installationInProgress

    var errorDescription: String? {
        switch self {
        case .invalidIdentifier:
            return "模型标识无效。"
        case .invalidVersion:
            return "模型版本无效。"
        case .invalidHTTPSURL:
            return "模型下载地址必须是无凭据的 HTTPS 地址。"
        case .invalidExpectedSize:
            return "模型大小无效或超过 4 GiB 安全上限。"
        case .invalidDigest:
            return "模型 SHA-256 摘要格式无效。"
        case .invalidSignature:
            return "模型 Ed25519 签名格式无效。"
        case .invalidPublicKey:
            return "模型验签公钥无效。"
        case .downloadedFileMissing:
            return "模型下载未生成文件。"
        case .downloadedFileIsNotRegular:
            return "模型下载结果不是普通文件。"
        case .downloadedSizeMismatch(let expected, let actual):
            return "模型大小不匹配（预期 \(expected)，实际 \(actual) 字节）。"
        case .disallowedDownloadHost:
            return "模型下载主机不在应用白名单中。"
        case .insufficientDiskSpace(let required, let available):
            return "可用空间不足（需要 \(required) 字节，可用 \(available) 字节）。"
        case .invalidHTTPStatus(let code):
            return "模型服务器返回了不安全的 HTTP 状态（\(code)）。"
        case .missingOrMismatchedContentLength(let expected, let actual):
            return "模型响应大小与清单不一致（预期 \(expected)，响应 \(actual) 字节）。"
        case .digestMismatch:
            return "模型 SHA-256 校验失败。"
        case .signatureMismatch:
            return "模型 Ed25519 验签失败。"
        case .metadataInvalid:
            return "模型安装记录无效。"
        case .installationInProgress:
            return "另一个模型安装正在进行；当前操作已拒绝。"
        }
    }
}

struct ASRModelDownloadClient: Sendable {
    typealias ProgressHandler = @Sendable (_ receivedByteCount: Int64) async -> Void
    typealias Operation = @Sendable (
        _ sourceURL: URL,
        _ destinationURL: URL,
        _ expectedByteCount: Int64,
        _ progress: @escaping ProgressHandler
    ) async throws -> Void

    let operation: Operation

    func download(
        from sourceURL: URL,
        to destinationURL: URL,
        expectedByteCount: Int64,
        progress: @escaping ProgressHandler
    ) async throws {
        try await operation(sourceURL, destinationURL, expectedByteCount, progress)
    }
}

enum ASRModelDownloadPolicy {
    static let minimumFreeSpaceReserve: Int64 = 64 * 1_024 * 1_024

    static func validateURL(_ url: URL, allowedHosts: Set<String>) throws {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              allowedHosts.map({ $0.lowercased() }).contains(host),
              url.user == nil,
              url.password == nil else {
            throw ASRModelStoreError.disallowedDownloadHost
        }
    }

    static func validateAvailableCapacity(
        _ available: Int64,
        expectedByteCount: Int64
    ) throws {
        let (required, overflow) = expectedByteCount.addingReportingOverflow(
            minimumFreeSpaceReserve
        )
        guard !overflow, available >= required else {
            throw ASRModelStoreError.insufficientDiskSpace(
                required: overflow ? Int64.max : required,
                available: max(available, 0)
            )
        }
    }

    static func validateResponse(
        _ response: HTTPURLResponse,
        expectedByteCount: Int64,
        allowedHosts: Set<String>
    ) throws {
        guard (200...299).contains(response.statusCode) else {
            throw ASRModelStoreError.invalidHTTPStatus(response.statusCode)
        }
        if let finalURL = response.url {
            try validateURL(finalURL, allowedHosts: allowedHosts)
        }
        let contentLength = response.expectedContentLength
        guard contentLength == expectedByteCount else {
            throw ASRModelStoreError.missingOrMismatchedContentLength(
                expected: expectedByteCount,
                actual: contentLength
            )
        }
    }
}

/// A production, streaming-to-disk downloader. It uses an ephemeral session,
/// accepts redirects only to explicitly allowed HTTPS hosts, validates the
/// declared Content-Length and disk capacity, and never loads model bytes into
/// one in-memory Data value.
final class URLSessionASRModelDownloader: @unchecked Sendable {
    private let allowedHosts: Set<String>
    private let session: URLSession
    private let fileManager: FileManager

    init(
        allowedHosts: Set<String>,
        fileManager: FileManager = .default
    ) {
        self.allowedHosts = Set(allowedHosts.map { $0.lowercased() })
        self.fileManager = fileManager
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 60 * 60
        session = URLSession(configuration: configuration)
    }

    deinit {
        session.invalidateAndCancel()
    }

    func client() -> ASRModelDownloadClient {
        ASRModelDownloadClient { [weak self] sourceURL, destinationURL, expected, progress in
            guard let self else { throw CancellationError() }
            try await self.download(
                from: sourceURL,
                to: destinationURL,
                expectedByteCount: expected,
                progress: progress
            )
        }
    }

    private func download(
        from sourceURL: URL,
        to destinationURL: URL,
        expectedByteCount: Int64,
        progress: @escaping ASRModelDownloadClient.ProgressHandler
    ) async throws {
        try ASRModelDownloadPolicy.validateURL(sourceURL, allowedHosts: allowedHosts)
        let parent = destinationURL.deletingLastPathComponent()
        let parentValues = try parent.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey
        ])
        guard parentValues.isDirectory == true, parentValues.isSymbolicLink != true else {
            throw ASRModelStoreError.metadataInvalid
        }
        let available: Int64
        if let importantCapacity = parentValues.volumeAvailableCapacityForImportantUsage {
            available = importantCapacity
        } else if let basicCapacity = parentValues.volumeAvailableCapacity {
            available = Int64(basicCapacity)
        } else {
            available = 0
        }
        try ASRModelDownloadPolicy.validateAvailableCapacity(
            available,
            expectedByteCount: expectedByteCount
        )

        var request = URLRequest(url: sourceURL)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let redirectDelegate = ASRModelRedirectDelegate(allowedHosts: allowedHosts)
        let (temporaryURL, response) = try await session.download(
            for: request,
            delegate: redirectDelegate
        )
        try Task.checkCancellation()
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ASRModelStoreError.invalidHTTPStatus(0)
        }
        try ASRModelDownloadPolicy.validateResponse(
            httpResponse,
            expectedByteCount: expectedByteCount,
            allowedHosts: allowedHosts
        )
        let downloadedValues = try temporaryURL.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey
        ])
        guard downloadedValues.isRegularFile == true,
              downloadedValues.isSymbolicLink != true,
              Int64(downloadedValues.fileSize ?? -1) == expectedByteCount else {
            throw ASRModelStoreError.downloadedSizeMismatch(
                expected: expectedByteCount,
                actual: Int64(downloadedValues.fileSize ?? -1)
            )
        }
        guard !fileManager.fileExists(atPath: destinationURL.path) else {
            throw ASRModelStoreError.metadataInvalid
        }
        try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        await progress(expectedByteCount)
    }
}

private final class ASRModelRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let allowedHosts: Set<String>

    init(allowedHosts: Set<String>) {
        self.allowedHosts = allowedHosts
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        _ = session
        _ = task
        guard let url = request.url else {
            completionHandler(nil)
            return
        }
        do {
            try ASRModelDownloadPolicy.validateURL(url, allowedHosts: allowedHosts)
            completionHandler(request)
        } catch {
            completionHandler(nil)
        }
    }
}

protocol ASRModelVerifying: Sendable {
    func verify(fileAt url: URL, descriptor: ASRModelDescriptor) async throws
}

struct Ed25519ASRModelVerifier: ASRModelVerifying {
    private static let readChunkSize = 1_048_576
    private let publicKeyRawRepresentation: Data

    init(publicKeyRawRepresentation: Data) throws {
        guard publicKeyRawRepresentation.count == 32 else {
            throw ASRModelStoreError.invalidPublicKey
        }
        self.publicKeyRawRepresentation = publicKeyRawRepresentation
    }

    func verify(fileAt url: URL, descriptor: ASRModelDescriptor) async throws {
        let actualSize = try Self.regularFileSize(at: url)
        guard actualSize == descriptor.expectedByteCount else {
            throw ASRModelStoreError.downloadedSizeMismatch(
                expected: descriptor.expectedByteCount,
                actual: actualSize
            )
        }

        let digest = try Self.streamingSHA256(of: url)
        guard Self.constantTimeEqual(digest, Self.digestData(from: descriptor.sha256Hex)) else {
            throw ASRModelStoreError.digestMismatch
        }
        guard let signature = Data(base64Encoded: descriptor.digestSignatureBase64),
              signature.count == 64 else {
            throw ASRModelStoreError.invalidSignature
        }

        let publicKey: Curve25519.Signing.PublicKey
        do {
            publicKey = try Curve25519.Signing.PublicKey(
                rawRepresentation: publicKeyRawRepresentation
            )
        } catch {
            throw ASRModelStoreError.invalidPublicKey
        }
        guard publicKey.isValidSignature(signature, for: digest) else {
            throw ASRModelStoreError.signatureMismatch
        }
    }

    private static func regularFileSize(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey
        ])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw ASRModelStoreError.downloadedFileIsNotRegular
        }
        guard let fileSize = values.fileSize else {
            throw ASRModelStoreError.downloadedFileMissing
        }
        return Int64(fileSize)
    }

    private static func streamingSHA256(of url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: readChunkSize) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return Data(hasher.finalize())
    }

    private static func digestData(from hex: String) -> Data {
        let normalized = hex.lowercased()
        guard normalized.count == 64 else { return Data() }

        var bytes = [UInt8]()
        bytes.reserveCapacity(32)
        var index = normalized.startIndex
        for _ in 0..<32 {
            let next = normalized.index(index, offsetBy: 2)
            guard let byte = UInt8(normalized[index..<next], radix: 16) else {
                return Data()
            }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
    }

    private static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return false }
        return zip(lhs, rhs).reduce(UInt8(0)) { partial, pair in
            partial | (pair.0 ^ pair.1)
        } == 0
    }
}

actor ASRModelStore {
    static let automaticCleanupInterval: TimeInterval = 30 * 24 * 60 * 60
    static let maximumModelByteCount: Int64 = 4 * 1_024 * 1_024 * 1_024

    private struct InstalledRecord: Codable, Equatable {
        var descriptor: ASRModelDescriptor
        var fileName: String
        var installedAt: Date
        var lastUsedAt: Date
        var keepDownloaded: Bool
    }

    private let rootDirectory: URL
    private let applicationSupportBoundary: URL
    private let metadataURL: URL
    private let verifier: any ASRModelVerifying
    private let fileManager: FileManager
    private var currentStatus: ASRModelInstallationStatus = .notInstalled
    private var installationInProgress = false

    init(
        rootDirectory: URL = ASRModelStore.defaultRootDirectory(),
        verifier: any ASRModelVerifying,
        fileManager: FileManager = .default
    ) {
        let standardizedRoot = rootDirectory.standardizedFileURL
        self.rootDirectory = standardizedRoot
        if standardizedRoot.lastPathComponent == "ASRModels",
           standardizedRoot.deletingLastPathComponent().lastPathComponent == "ClaudePromptTranslator" {
            self.applicationSupportBoundary = standardizedRoot
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .standardizedFileURL
        } else {
            // Custom roots are used by tests and embedding clients. Their
            // fixed lexical parent is the narrowest boundary available.
            self.applicationSupportBoundary = standardizedRoot
                .deletingLastPathComponent()
                .standardizedFileURL
        }
        self.metadataURL = standardizedRoot
            .appendingPathComponent("current.json", isDirectory: false)
        self.verifier = verifier
        self.fileManager = fileManager
    }

    func status(now: Date = Date()) -> ASRModelInstallationStatus {
        // `install` yields while downloading and verifying. During that actor
        // reentrancy window, status checks must remain observational: cleaning
        // an expired prior model here would break the atomic replacement
        // contract while the new model is still in flight.
        if installationInProgress { return currentStatus }
        do {
            try prepareRootDirectory()
            _ = try cleanupExpired(now: now)
            if case .failed = currentStatus { return currentStatus }
            guard let record = try loadRecord() else {
                currentStatus = .notInstalled
                return currentStatus
            }
            guard try installedFileURL(for: record) != nil else {
                currentStatus = .notInstalled
                return currentStatus
            }
            currentStatus = .installed(
                descriptor: record.descriptor,
                lastUsedAt: record.lastUsedAt,
                keepDownloaded: record.keepDownloaded
            )
        } catch {
            currentStatus = .failed(message: Self.safeMessage(for: error))
        }
        return currentStatus
    }

    @discardableResult
    func install(
        _ descriptor: ASRModelDescriptor,
        using downloadClient: ASRModelDownloadClient,
        now: Date = Date()
    ) async throws -> URL {
        guard !installationInProgress else {
            throw ASRModelStoreError.installationInProgress
        }
        installationInProgress = true
        defer { installationInProgress = false }

        do {
            try Self.validate(descriptor)
            try prepareRootDirectory()

            let incomingURL = rootDirectory.appendingPathComponent(
                ".incoming-\(UUID().uuidString)",
                isDirectory: false
            )
            defer { try? fileManager.removeItem(at: incomingURL) }

            currentStatus = .downloading(
                receivedByteCount: 0,
                expectedByteCount: descriptor.expectedByteCount
            )
            try await downloadClient.download(
                from: descriptor.downloadURL,
                to: incomingURL,
                expectedByteCount: descriptor.expectedByteCount
            ) { [weak self] receivedByteCount in
                await self?.setDownloadProgress(
                    receivedByteCount: receivedByteCount,
                    expectedByteCount: descriptor.expectedByteCount
                )
            }

            guard fileManager.fileExists(atPath: incomingURL.path) else {
                throw ASRModelStoreError.downloadedFileMissing
            }
            currentStatus = .verifying
            try await verifier.verify(fileAt: incomingURL, descriptor: descriptor)
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))],
                ofItemAtPath: incomingURL.path
            )

            let previousRecord = try loadRecord()
            let fileName = "model-\(UUID().uuidString).cptasr"
            let installedURL = rootDirectory.appendingPathComponent(fileName, isDirectory: false)
            try fileManager.moveItem(at: incomingURL, to: installedURL)

            let record = InstalledRecord(
                descriptor: Self.descriptorForPersistence(descriptor),
                fileName: fileName,
                installedAt: now,
                lastUsedAt: now,
                keepDownloaded: false
            )
            do {
                try saveRecord(record)
            } catch {
                try? fileManager.removeItem(at: installedURL)
                throw error
            }

            if let previousRecord,
               let previousURL = try installedFileURL(for: previousRecord),
               previousURL != installedURL {
                try? fileManager.removeItem(at: previousURL)
            }
            try removeOrphanedModels(keeping: fileName)
            currentStatus = .installed(
                descriptor: descriptor,
                lastUsedAt: now,
                keepDownloaded: false
            )
            return installedURL
        } catch {
            currentStatus = .failed(message: Self.safeMessage(for: error))
            throw error
        }
    }

    func installedModelURL(now: Date = Date()) throws -> URL? {
        try prepareRootDirectory()
        if !installationInProgress {
            _ = try cleanupExpired(now: now)
        }
        guard let record = try loadRecord() else { return nil }
        return try installedFileURL(for: record)
    }

    func markUsed(at date: Date = Date()) throws {
        guard !installationInProgress else {
            throw ASRModelStoreError.installationInProgress
        }
        try prepareRootDirectory()
        guard var record = try loadRecord(), try installedFileURL(for: record) != nil else { return }
        record.lastUsedAt = date
        try saveRecord(record)
        currentStatus = .installed(
            descriptor: record.descriptor,
            lastUsedAt: record.lastUsedAt,
            keepDownloaded: record.keepDownloaded
        )
    }

    func setKeepDownloaded(_ keepDownloaded: Bool) throws {
        guard !installationInProgress else {
            throw ASRModelStoreError.installationInProgress
        }
        try prepareRootDirectory()
        guard var record = try loadRecord(), try installedFileURL(for: record) != nil else { return }
        record.keepDownloaded = keepDownloaded
        try saveRecord(record)
        currentStatus = .installed(
            descriptor: record.descriptor,
            lastUsedAt: record.lastUsedAt,
            keepDownloaded: keepDownloaded
        )
    }

    @discardableResult
    func performAutomaticCleanup(now: Date = Date()) throws -> Bool {
        guard !installationInProgress else { return false }
        try prepareRootDirectory()
        return try cleanupExpired(now: now)
    }

    func removeInstalledModel() throws {
        guard !installationInProgress else {
            throw ASRModelStoreError.installationInProgress
        }
        try prepareRootDirectory()
        let record = try loadRecord()
        if let record, let url = try installedFileURL(for: record) {
            try? fileManager.removeItem(at: url)
        }
        if fileManager.fileExists(atPath: metadataURL.path) {
            try fileManager.removeItem(at: metadataURL)
        }
        try removeOrphanedModels(keeping: nil)
        currentStatus = .notInstalled
    }

    private func setDownloadProgress(
        receivedByteCount: Int64,
        expectedByteCount: Int64
    ) {
        currentStatus = .downloading(
            receivedByteCount: min(max(receivedByteCount, 0), expectedByteCount),
            expectedByteCount: expectedByteCount
        )
    }

    @discardableResult
    private func cleanupExpired(now: Date) throws -> Bool {
        guard let record = try loadRecord() else {
            try removeOrphanedModels(keeping: nil)
            return false
        }
        guard try installedFileURL(for: record) != nil else {
            if fileManager.fileExists(atPath: metadataURL.path) {
                try fileManager.removeItem(at: metadataURL)
            }
            try removeOrphanedModels(keeping: nil)
            currentStatus = .notInstalled
            return true
        }
        guard !record.keepDownloaded,
              now.timeIntervalSince(record.lastUsedAt) >= Self.automaticCleanupInterval else {
            try removeOrphanedModels(keeping: record.fileName)
            return false
        }

        if let url = try installedFileURL(for: record) {
            try fileManager.removeItem(at: url)
        }
        try fileManager.removeItem(at: metadataURL)
        try removeOrphanedModels(keeping: nil)
        currentStatus = .notInstalled
        return true
    }

    private func prepareRootDirectory() throws {
        do {
            try SecureOwnedDirectoryChain.createDirectoryIfNeeded(
                from: applicationSupportBoundary,
                through: rootDirectory,
                fileManager: fileManager
            )
        } catch {
            throw ASRModelStoreError.metadataInvalid
        }
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: rootDirectory.path
        )
        do {
            guard try SecureOwnedDirectoryChain.validateExistingDirectory(
                from: applicationSupportBoundary,
                through: rootDirectory
            ) else {
                throw ASRModelStoreError.metadataInvalid
            }
        } catch {
            throw ASRModelStoreError.metadataInvalid
        }
    }

    private func loadRecord() throws -> InstalledRecord? {
        guard let metadataType = try itemTypeIfPresent(at: metadataURL) else { return nil }
        guard metadataType == .typeRegular else {
            throw ASRModelStoreError.metadataInvalid
        }
        let data = try Data(contentsOf: metadataURL, options: [.mappedIfSafe])
        guard data.count <= 64 * 1_024,
              let record = try? JSONDecoder().decode(InstalledRecord.self, from: data),
              Self.safeComponent(record.fileName),
              record.fileName.hasSuffix(".cptasr") else {
            throw ASRModelStoreError.metadataInvalid
        }
        return record
    }

    private func saveRecord(_ record: InstalledRecord) throws {
        let data = try JSONEncoder().encode(record)
        guard data.count <= 64 * 1_024 else {
            throw ASRModelStoreError.metadataInvalid
        }
        if let metadataType = try itemTypeIfPresent(at: metadataURL),
           metadataType != .typeRegular {
            throw ASRModelStoreError.metadataInvalid
        }
        try data.write(to: metadataURL, options: [.atomic])
        guard try itemTypeIfPresent(at: metadataURL) == .typeRegular else {
            throw ASRModelStoreError.metadataInvalid
        }
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: metadataURL.path
        )
    }

    private func installedFileURL(for record: InstalledRecord) throws -> URL? {
        guard Self.safeComponent(record.fileName) else { return nil }
        let url = rootDirectory.appendingPathComponent(record.fileName, isDirectory: false)
        guard let type = try itemTypeIfPresent(at: url) else { return nil }
        guard type == .typeRegular else {
            throw ASRModelStoreError.metadataInvalid
        }
        return url
    }

    private func removeOrphanedModels(keeping fileName: String?) throws {
        let urls = try fileManager.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        for url in urls where url.pathExtension == "cptasr" && url.lastPathComponent != fileName {
            guard try itemTypeIfPresent(at: url) == .typeRegular else { continue }
            try fileManager.removeItem(at: url)
        }
    }

    /// `attributesOfItem` uses lstat-style type reporting for a symbolic link,
    /// unlike `fileExists` and normal URL reads which can follow its target.
    private func itemTypeIfPresent(at url: URL) throws -> FileAttributeType? {
        do {
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            return attributes[.type] as? FileAttributeType
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain,
               [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(nsError.code) {
                return nil
            }
            throw error
        }
    }

    private static func validate(_ descriptor: ASRModelDescriptor) throws {
        guard safeComponent(descriptor.identifier) else {
            throw ASRModelStoreError.invalidIdentifier
        }
        guard safeComponent(descriptor.version) else {
            throw ASRModelStoreError.invalidVersion
        }
        guard descriptor.downloadURL.scheme?.lowercased() == "https",
              descriptor.downloadURL.host != nil,
              descriptor.downloadURL.user == nil,
              descriptor.downloadURL.password == nil else {
            throw ASRModelStoreError.invalidHTTPSURL
        }
        guard descriptor.expectedByteCount > 0,
              descriptor.expectedByteCount <= maximumModelByteCount else {
            throw ASRModelStoreError.invalidExpectedSize
        }
        guard descriptor.sha256Hex.count == 64,
              descriptor.sha256Hex.allSatisfy({ $0.isHexDigit }) else {
            throw ASRModelStoreError.invalidDigest
        }
        guard let signature = Data(base64Encoded: descriptor.digestSignatureBase64),
              signature.count == 64 else {
            throw ASRModelStoreError.invalidSignature
        }
    }

    private static func safeComponent(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 96, value != ".", value != ".." else {
            return false
        }
        return value.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar) || "._-".unicodeScalars.contains(scalar)
        }
    }

    private static func safeMessage(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "模型操作失败；未记录下载地址或本地路径。"
    }

    private static func descriptorForPersistence(
        _ descriptor: ASRModelDescriptor
    ) -> ASRModelDescriptor {
        var components = URLComponents(url: descriptor.downloadURL, resolvingAgainstBaseURL: false)
        components?.query = nil
        components?.fragment = nil
        return ASRModelDescriptor(
            identifier: descriptor.identifier,
            version: descriptor.version,
            downloadURL: components?.url ?? descriptor.downloadURL,
            expectedByteCount: descriptor.expectedByteCount,
            sha256Hex: descriptor.sha256Hex,
            digestSignatureBase64: descriptor.digestSignatureBase64
        )
    }

    private static func defaultRootDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClaudePromptTranslator", isDirectory: true)
            .appendingPathComponent("ASRModels", isDirectory: true)
    }
}
