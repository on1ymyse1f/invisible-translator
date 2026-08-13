import CryptoKit
import Foundation
import XCTest
@testable import ClaudePromptTranslator

final class ASRModelStoreTests: XCTestCase {
    func testDownloadPolicyRejectsHostAndMismatchedContentLength() throws {
        let allowedHosts: Set<String> = ["models.example.invalid"]
        XCTAssertThrowsError(
            try ASRModelDownloadPolicy.validateURL(
                URL(string: "https://evil.example.invalid/model")!,
                allowedHosts: allowedHosts
            )
        ) { error in
            XCTAssertEqual(error as? ASRModelStoreError, .disallowedDownloadHost)
        }

        let response = HTTPURLResponse(
            url: URL(string: "https://models.example.invalid/model")!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": "63"]
        )!
        XCTAssertThrowsError(
            try ASRModelDownloadPolicy.validateResponse(
                response,
                expectedByteCount: 64,
                allowedHosts: allowedHosts
            )
        ) { error in
            XCTAssertEqual(
                error as? ASRModelStoreError,
                .missingOrMismatchedContentLength(expected: 64, actual: 63)
            )
        }
    }

    func testDownloadPolicyRequiresModelPlusReserveCapacity() {
        XCTAssertThrowsError(
            try ASRModelDownloadPolicy.validateAvailableCapacity(
                70 * 1_024 * 1_024,
                expectedByteCount: 10 * 1_024 * 1_024
            )
        )
        XCTAssertNoThrow(
            try ASRModelDownloadPolicy.validateAvailableCapacity(
                80 * 1_024 * 1_024,
                expectedByteCount: 10 * 1_024 * 1_024
            )
        )
    }

    func testInstalledMetadataDropsDownloadQueryAndFragment() async throws {
        let root = try makeTemporaryDirectory()
        let payload = Data(repeating: 0x42, count: 128)
        let privateKey = Curve25519.Signing.PrivateKey()
        let signed = try signedDescriptor(payload: payload, privateKey: privateKey)
        let descriptor = ASRModelDescriptor(
            identifier: signed.identifier,
            version: signed.version,
            downloadURL: URL(string: "https://models.example.invalid/asr.cptasr?temporary_token=secret#fragment")!,
            expectedByteCount: signed.expectedByteCount,
            sha256Hex: signed.sha256Hex,
            digestSignatureBase64: signed.digestSignatureBase64
        )
        let verifier = try Ed25519ASRModelVerifier(
            publicKeyRawRepresentation: privateKey.publicKey.rawRepresentation
        )
        let store = ASRModelStore(rootDirectory: root, verifier: verifier)
        _ = try await store.install(descriptor, using: chunkedDownloadClient(payload: payload))
        guard case .installed(let persisted, _, _) = await store.status() else {
            return XCTFail("Expected an installed model.")
        }
        XCTAssertNil(URLComponents(url: persisted.downloadURL, resolvingAgainstBaseURL: false)?.query)
        XCTAssertNil(persisted.downloadURL.fragment)
    }

    func testSignedModelInstallsAtomicallyAndHonorsCleanupPreference() async throws {
        let root = try makeTemporaryDirectory()
        let payload = Data(repeating: 0x5A, count: 192 * 1_024)
        let privateKey = Curve25519.Signing.PrivateKey()
        let descriptor = try signedDescriptor(payload: payload, privateKey: privateKey)
        let verifier = try Ed25519ASRModelVerifier(
            publicKeyRawRepresentation: privateKey.publicKey.rawRepresentation
        )
        let store = ASRModelStore(rootDirectory: root, verifier: verifier)
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        let installedURL = try await store.install(
            descriptor,
            using: chunkedDownloadClient(payload: payload),
            now: start
        )

        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: installedURL.path)[.size] as? NSNumber,
            NSNumber(value: payload.count)
        )
        guard case .installed(let installedDescriptor, let lastUsedAt, let keepDownloaded) =
            await store.status(now: start) else {
            return XCTFail("Expected an installed model status.")
        }
        XCTAssertEqual(installedDescriptor, descriptor)
        XCTAssertEqual(lastUsedAt, start)
        XCTAssertFalse(keepDownloaded)

        try await store.setKeepDownloaded(true)
        let retained = try await store.performAutomaticCleanup(
            now: start.addingTimeInterval(31 * 24 * 60 * 60)
        )
        XCTAssertFalse(retained)
        let retainedURL = try await store.installedModelURL(
            now: start.addingTimeInterval(31 * 24 * 60 * 60)
        )
        XCTAssertNotNil(retainedURL)

        try await store.setKeepDownloaded(false)
        let removed = try await store.performAutomaticCleanup(
            now: start.addingTimeInterval(31 * 24 * 60 * 60)
        )
        XCTAssertTrue(removed)
        let removedURL = try await store.installedModelURL(
            now: start.addingTimeInterval(31 * 24 * 60 * 60)
        )
        XCTAssertNil(removedURL)
    }

    func testInstallRejectsHTTPBeforeInvokingDownloader() async throws {
        let root = try makeTemporaryDirectory()
        let privateKey = Curve25519.Signing.PrivateKey()
        let payload = Data("synthetic-model".utf8)
        let valid = try signedDescriptor(payload: payload, privateKey: privateKey)
        let descriptor = ASRModelDescriptor(
            identifier: valid.identifier,
            version: valid.version,
            downloadURL: URL(string: "http://models.example.invalid/asr.cptasr")!,
            expectedByteCount: valid.expectedByteCount,
            sha256Hex: valid.sha256Hex,
            digestSignatureBase64: valid.digestSignatureBase64
        )
        let verifier = try Ed25519ASRModelVerifier(
            publicKeyRawRepresentation: privateKey.publicKey.rawRepresentation
        )
        let store = ASRModelStore(rootDirectory: root, verifier: verifier)
        let recorder = DownloadInvocationRecorder()
        let client = ASRModelDownloadClient { _, _, _, _ in
            await recorder.record()
        }

        do {
            _ = try await store.install(descriptor, using: client)
            XCTFail("An HTTP model URL must be rejected.")
        } catch {
            XCTAssertEqual(error as? ASRModelStoreError, .invalidHTTPSURL)
        }
        let invocationCount = await recorder.count
        XCTAssertEqual(invocationCount, 0)
    }

    func testVerifierRejectsTamperedModelWithoutLoadingItAsAnInstalledModel() async throws {
        let root = try makeTemporaryDirectory()
        let privateKey = Curve25519.Signing.PrivateKey()
        let signedPayload = Data(repeating: 0x11, count: 80 * 1_024)
        let tamperedPayload = Data(repeating: 0x12, count: signedPayload.count)
        let descriptor = try signedDescriptor(payload: signedPayload, privateKey: privateKey)
        let verifier = try Ed25519ASRModelVerifier(
            publicKeyRawRepresentation: privateKey.publicKey.rawRepresentation
        )
        let store = ASRModelStore(rootDirectory: root, verifier: verifier)

        do {
            _ = try await store.install(
                descriptor,
                using: chunkedDownloadClient(payload: tamperedPayload)
            )
            XCTFail("A model with a mismatched digest must be rejected.")
        } catch {
            XCTAssertEqual(error as? ASRModelStoreError, .digestMismatch)
        }
        let installedURL = try await store.installedModelURL()
        XCTAssertNil(installedURL)
    }

    func testStatusDuringDownloadDoesNotCleanUpExpiredInstalledModel() async throws {
        let root = try makeTemporaryDirectory()
        let privateKey = Curve25519.Signing.PrivateKey()
        let oldPayload = Data(repeating: 0x31, count: 64 * 1_024)
        let replacementPayload = Data(repeating: 0x32, count: 64 * 1_024)
        let oldDescriptor = try signedDescriptor(payload: oldPayload, privateKey: privateKey)
        let replacementDescriptor = try signedDescriptor(
            payload: replacementPayload,
            privateKey: privateKey
        )
        let verifier = try Ed25519ASRModelVerifier(
            publicKeyRawRepresentation: privateKey.publicKey.rawRepresentation
        )
        let store = ASRModelStore(rootDirectory: root, verifier: verifier)
        let installedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let oldModelURL = try await store.install(
            oldDescriptor,
            using: chunkedDownloadClient(payload: oldPayload),
            now: installedAt
        )
        let gate = SuspendedDownloadGate()
        let replacementClient = ASRModelDownloadClient {
            _, destinationURL, expectedByteCount, progress in
            await gate.markStarted()
            await gate.waitUntilReleased()
            try replacementPayload.write(to: destinationURL)
            await progress(expectedByteCount)
        }

        let installTask = Task {
            try await store.install(
                replacementDescriptor,
                using: replacementClient,
                now: installedAt.addingTimeInterval(31 * 24 * 60 * 60)
            )
        }
        await gate.waitUntilStarted()

        let inFlightStatus = await store.status(
            now: installedAt.addingTimeInterval(31 * 24 * 60 * 60)
        )
        guard case .downloading = inFlightStatus else {
            await gate.release()
            _ = try? await installTask.value
            return XCTFail("Expected the replacement download to remain in progress.")
        }
        let cleanupResult = try await store.performAutomaticCleanup(
            now: installedAt.addingTimeInterval(31 * 24 * 60 * 60)
        )
        XCTAssertFalse(cleanupResult)
        do {
            _ = try await store.install(
                replacementDescriptor,
                using: chunkedDownloadClient(payload: replacementPayload)
            )
            XCTFail("A concurrent second install must be rejected.")
        } catch {
            XCTAssertEqual(error as? ASRModelStoreError, .installationInProgress)
        }
        do {
            try await store.removeInstalledModel()
            XCTFail("Explicit removal during installation must be rejected.")
        } catch {
            XCTAssertEqual(error as? ASRModelStoreError, .installationInProgress)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldModelURL.path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("current.json").path
            )
        )

        await gate.release()
        let replacementURL = try await installTask.value
        XCTAssertTrue(FileManager.default.fileExists(atPath: replacementURL.path))
    }

    func testAutomaticCleanupDuringVerificationKeepsExpiredInstalledModel() async throws {
        let root = try makeTemporaryDirectory()
        let privateKey = Curve25519.Signing.PrivateKey()
        let oldPayload = Data(repeating: 0x41, count: 32 * 1_024)
        let replacementPayload = Data(repeating: 0x42, count: 32 * 1_024)
        let oldDescriptor = try signedDescriptor(payload: oldPayload, privateKey: privateKey)
        let replacementDescriptor = try signedDescriptor(
            payload: replacementPayload,
            privateKey: privateKey
        )
        let underlyingVerifier = try Ed25519ASRModelVerifier(
            publicKeyRawRepresentation: privateKey.publicKey.rawRepresentation
        )
        let verifier = SuspendingASRModelVerifier(underlying: underlyingVerifier)
        let store = ASRModelStore(rootDirectory: root, verifier: verifier)
        let installedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let oldModelURL = try await store.install(
            oldDescriptor,
            using: chunkedDownloadClient(payload: oldPayload),
            now: installedAt
        )
        await verifier.suspendNextVerification()
        let replacementClient = chunkedDownloadClient(payload: replacementPayload)

        let installTask = Task {
            try await store.install(
                replacementDescriptor,
                using: replacementClient,
                now: installedAt.addingTimeInterval(31 * 24 * 60 * 60)
            )
        }
        await verifier.waitUntilSuspended()

        guard case .verifying = await store.status() else {
            await verifier.release()
            _ = try? await installTask.value
            return XCTFail("Expected replacement verification to remain in progress.")
        }
        let cleanupResult = try await store.performAutomaticCleanup(
            now: installedAt.addingTimeInterval(31 * 24 * 60 * 60)
        )
        XCTAssertFalse(cleanupResult)
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldModelURL.path))

        await verifier.release()
        _ = try await installTask.value
    }

    func testRootSymlinkIsRejectedWithoutFollowingOrDeletingItsTarget() async throws {
        let container = try makeTemporaryDirectory()
        let target = container.appendingPathComponent("outside", isDirectory: true)
        let rootSymlink = container.appendingPathComponent("ASRModels", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        let marker = target.appendingPathComponent("must-survive.txt", isDirectory: false)
        try Data("keep".utf8).write(to: marker)
        try FileManager.default.createSymbolicLink(at: rootSymlink, withDestinationURL: target)
        let privateKey = Curve25519.Signing.PrivateKey()
        let verifier = try Ed25519ASRModelVerifier(
            publicKeyRawRepresentation: privateKey.publicKey.rawRepresentation
        )
        let store = ASRModelStore(rootDirectory: rootSymlink, verifier: verifier)

        do {
            _ = try await store.performAutomaticCleanup()
            XCTFail("A symbolic-link model root must be rejected.")
        } catch {
            XCTAssertEqual(error as? ASRModelStoreError, .metadataInvalid)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertEqual(try Data(contentsOf: marker), Data("keep".utf8))
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: rootSymlink.path),
            target.path
        )
    }

    func testPreexistingAppDirectorySymlinkIsRejectedBeforeExternalModelEnumeration() async throws {
        let container = try makeTemporaryDirectory()
        let applicationSupport = container.appendingPathComponent(
            "Application Support",
            isDirectory: true
        )
        let externalAppDirectory = container.appendingPathComponent(
            "ExternalModelOwner",
            isDirectory: true
        )
        let externalModels = externalAppDirectory.appendingPathComponent(
            "ASRModels",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: applicationSupport,
            withIntermediateDirectories: false
        )
        try FileManager.default.createDirectory(
            at: externalModels,
            withIntermediateDirectories: true
        )
        let marker = externalModels.appendingPathComponent("must-survive.cptasr")
        try Data("external-model-must-not-be-read-or-deleted".utf8).write(to: marker)

        let linkedAppDirectory = applicationSupport.appendingPathComponent(
            "ClaudePromptTranslator",
            isDirectory: true
        )
        try FileManager.default.createSymbolicLink(
            at: linkedAppDirectory,
            withDestinationURL: externalAppDirectory
        )
        let configuredRoot = linkedAppDirectory.appendingPathComponent(
            "ASRModels",
            isDirectory: true
        )
        let privateKey = Curve25519.Signing.PrivateKey()
        let verifier = try Ed25519ASRModelVerifier(
            publicKeyRawRepresentation: privateKey.publicKey.rawRepresentation
        )

        // The symlink already exists before store startup. The fixed lexical
        // Application Support boundary must still reject it.
        let store = ASRModelStore(rootDirectory: configuredRoot, verifier: verifier)
        do {
            _ = try await store.performAutomaticCleanup()
            XCTFail("A preexisting app-directory symlink must be rejected.")
        } catch {
            XCTAssertEqual(error as? ASRModelStoreError, .metadataInvalid)
        }

        XCTAssertEqual(
            try Data(contentsOf: marker),
            Data("external-model-must-not-be-read-or-deleted".utf8)
        )
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: linkedAppDirectory.path),
            externalAppDirectory.path
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CPT-ASRModelStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    private func signedDescriptor(
        payload: Data,
        privateKey: Curve25519.Signing.PrivateKey
    ) throws -> ASRModelDescriptor {
        let digest = Data(SHA256.hash(data: payload))
        let signature = try privateKey.signature(for: digest)
        return ASRModelDescriptor(
            identifier: "synthetic-asr",
            version: "1.0.0",
            downloadURL: URL(string: "https://models.example.invalid/asr.cptasr")!,
            expectedByteCount: Int64(payload.count),
            sha256Hex: digest.map { String(format: "%02x", $0) }.joined(),
            digestSignatureBase64: signature.base64EncodedString()
        )
    }

    private func chunkedDownloadClient(payload: Data) -> ASRModelDownloadClient {
        ASRModelDownloadClient { _, destinationURL, expectedByteCount, progress in
            XCTAssertEqual(expectedByteCount, Int64(payload.count))
            FileManager.default.createFile(atPath: destinationURL.path, contents: nil)
            let handle = try FileHandle(forWritingTo: destinationURL)
            defer { try? handle.close() }

            let chunkSize = 16 * 1_024
            var offset = 0
            while offset < payload.count {
                let end = min(offset + chunkSize, payload.count)
                try handle.write(contentsOf: payload[offset..<end])
                offset = end
                await progress(Int64(offset))
            }
        }
    }
}

private actor DownloadInvocationRecorder {
    private(set) var count = 0

    func record() {
        count += 1
    }
}

private actor SuspendedDownloadGate {
    private var started = false
    private var released = false
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func markStarted() {
        started = true
        let waiters = startedWaiters
        startedWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startedWaiters.append(continuation)
        }
    }

    func waitUntilReleased() async {
        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private actor SuspendingASRModelVerifier: ASRModelVerifying {
    private let underlying: Ed25519ASRModelVerifier
    private var shouldSuspendNext = false
    private var suspended = false
    private var released = false
    private var suspendedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    init(underlying: Ed25519ASRModelVerifier) {
        self.underlying = underlying
    }

    func suspendNextVerification() {
        shouldSuspendNext = true
        released = false
    }

    func verify(fileAt url: URL, descriptor: ASRModelDescriptor) async throws {
        if shouldSuspendNext {
            shouldSuspendNext = false
            suspended = true
            let waiters = suspendedWaiters
            suspendedWaiters.removeAll()
            waiters.forEach { $0.resume() }
            if !released {
                await withCheckedContinuation { continuation in
                    releaseWaiters.append(continuation)
                }
            }
        }
        try await underlying.verify(fileAt: url, descriptor: descriptor)
    }

    func waitUntilSuspended() async {
        guard !suspended else { return }
        await withCheckedContinuation { continuation in
            suspendedWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}
