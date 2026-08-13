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
