import Foundation

/// Strict, content-redacting validation for the Chromium native-messaging
/// boundary. This file deliberately contains no logging and no network code.
/// Chrome's native host framing is a four-byte little-endian length followed
/// by one UTF-8 JSON object.
enum BrowserNativeMessagingProtocol {
    static let version = 1
    static let maximumFrameBytes = 256 * 1_024
    static let maximumItems = 64
    static let maximumIdentifierBytes = 1_024
    static let hostName = "com.on1ymyse1f.InvisibleTranslator"

    static let allowedOrigins: Set<String> = [
        "https://chatgpt.com",
        "https://chat.openai.com",
        "https://claude.ai",
        "https://x.com",
        "https://twitter.com",
        "https://youtube.com",
        "https://www.youtube.com"
    ]

    enum MessageKind: String, CaseIterable {
        case page
        case hover
        case subtitle
    }

    enum ValidationError: LocalizedError, Equatable {
        case oversizedFrame
        case invalidJSON
        case invalidEnvelope
        case unsupportedVersion
        case disallowedOrigin
        case invalidKind
        case invalidRequestIdentifier
        case invalidItems

        var errorDescription: String? {
            switch self {
            case .oversizedFrame:
                return "本机消息超过 256 KiB 安全上限。"
            case .invalidJSON, .invalidEnvelope:
                return "本机消息格式无效。"
            case .unsupportedVersion:
                return "本机消息协议版本不受支持。"
            case .disallowedOrigin:
                return "此网站未在本机扩展白名单中。"
            case .invalidKind:
                return "翻译请求类型无效。"
            case .invalidRequestIdentifier:
                return "翻译请求标识无效。"
            case .invalidItems:
                return "翻译批次无效或超过安全预算。"
            }
        }
    }

    struct Item: Equatable, Sendable {
        let id: String
        let text: String
    }

    struct TranslationRequest: Equatable, Sendable {
        let requestID: String
        let origin: String
        let kind: MessageKind
        let items: [Item]
    }

    struct SettingsRequest: Equatable, Sendable {
        let origin: String
    }

    enum IncomingMessage: Equatable, Sendable {
        case translation(TranslationRequest)
        case settings(SettingsRequest)
    }

    static func decodeIncomingFrame(_ data: Data) throws -> IncomingMessage {
        guard !data.isEmpty, data.count <= maximumFrameBytes else {
            throw ValidationError.oversizedFrame
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ValidationError.invalidJSON
        }
        guard let envelope = object as? [String: Any],
              envelope.keys.allSatisfy({ $0.utf8.count <= maximumIdentifierBytes }),
              let type = envelope["type"] as? String else {
            throw ValidationError.invalidEnvelope
        }
        guard envelope["version"] as? Int == version else {
            throw ValidationError.unsupportedVersion
        }

        switch type {
        case "translationRequest":
            return .translation(try decodeTranslationRequest(envelope))
        case "settingsRequest":
            guard hasOnlyKeys(envelope, ["type", "version", "origin"]) else {
                throw ValidationError.invalidEnvelope
            }
            return .settings(
                SettingsRequest(origin: try validatedOrigin(envelope["origin"]))
            )
        default:
            throw ValidationError.invalidEnvelope
        }
    }

    /// Encodes a Chrome native-messaging frame. The caller writes the returned
    /// data directly to stdout; no source or translation is ever logged.
    static func encodeNativeFrame(jsonObject: [String: Any]) throws -> Data {
        let payload: Data
        do {
            payload = try JSONSerialization.data(
                withJSONObject: jsonObject,
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
        } catch {
            throw ValidationError.invalidJSON
        }
        guard !payload.isEmpty, payload.count <= maximumFrameBytes else {
            throw ValidationError.oversizedFrame
        }
        var length = UInt32(payload.count).littleEndian
        var frame = withUnsafeBytes(of: &length) { Data($0) }
        frame.append(payload)
        return frame
    }

    static func splitNativeFrame(_ frame: Data) throws -> Data {
        guard frame.count >= MemoryLayout<UInt32>.size else {
            throw ValidationError.invalidEnvelope
        }
        let length = frame.prefix(4).withUnsafeBytes { bytes -> UInt32 in
            bytes.loadUnaligned(as: UInt32.self).littleEndian
        }
        guard length > 0, length <= UInt32(maximumFrameBytes),
              frame.count == 4 + Int(length) else {
            throw ValidationError.oversizedFrame
        }
        return frame.dropFirst(4)
    }

    static func translationResult(
        for request: TranslationRequest,
        translations: [(id: String, translation: String)]
    ) throws -> [String: Any] {
        guard translations.count == request.items.count,
              zip(request.items, translations).allSatisfy({ source, output in
                  source.id == output.id && validIdentifier(output.id)
              }) else {
            throw ValidationError.invalidItems
        }
        var response: [String: Any] = [
            "type": "translationResult",
            "version": version,
            "requestId": request.requestID,
            "origin": request.origin,
            "kind": request.kind.rawValue
        ]
        if request.kind == .subtitle, let source = request.items.first,
           let translation = translations.first?.translation {
            response["source"] = source.text
            response["translation"] = translation
        } else {
            response["items"] = translations.map {
                ["id": $0.id, "translation": $0.translation]
            }
        }
        _ = try encodeNativeFrame(jsonObject: response)
        return response
    }

    static func extensionSettings(
        origin: String,
        autoMode: Bool,
        hoverMode: Bool,
        hideOriginal: Bool
    ) throws -> [String: Any] {
        let canonicalOrigin = try validatedOrigin(origin)
        return [
            "type": "extensionSettings",
            "version": version,
            "origin": canonicalOrigin,
            "settings": [
                "autoMode": autoMode,
                "hoverMode": hoverMode,
                "hideOriginal": hideOriginal
            ]
        ]
    }

    static func nativeError(code: String) -> [String: Any] {
        let allowedCodes: Set<String> = [
            "busy", "invalidRequest", "notAuthorized", "translationFailed"
        ]
        return [
            "type": "nativeError",
            "version": version,
            "code": allowedCodes.contains(code) ? code : "translationFailed"
        ]
    }

    private static func decodeTranslationRequest(
        _ envelope: [String: Any]
    ) throws -> TranslationRequest {
        guard hasOnlyKeys(
            envelope,
            ["type", "version", "requestId", "origin", "kind", "payload"]
        ) else {
            throw ValidationError.invalidEnvelope
        }
        guard let requestID = envelope["requestId"] as? String,
              validIdentifier(requestID) else {
            throw ValidationError.invalidRequestIdentifier
        }
        let origin = try validatedOrigin(envelope["origin"])
        guard let rawKind = envelope["kind"] as? String,
              let kind = MessageKind(rawValue: rawKind) else {
            throw ValidationError.invalidKind
        }
        guard let payload = envelope["payload"] as? [String: Any],
              hasOnlyKeys(payload, ["kind", "items"]),
              payload["kind"] as? String == rawKind,
              let rawItems = payload["items"] as? [[String: Any]],
              !rawItems.isEmpty,
              rawItems.count <= maximumItems else {
            throw ValidationError.invalidItems
        }

        var textBytes = 0
        let items: [Item] = try rawItems.map { rawItem in
            guard hasOnlyKeys(rawItem, ["id", "text"]),
                  let id = rawItem["id"] as? String,
                  validIdentifier(id),
                  let text = rawItem["text"] as? String,
                  !text.isEmpty else {
                throw ValidationError.invalidItems
            }
            textBytes += text.utf8.count
            guard textBytes <= maximumFrameBytes else {
                throw ValidationError.invalidItems
            }
            return Item(id: id, text: text)
        }
        return TranslationRequest(
            requestID: requestID,
            origin: origin,
            kind: kind,
            items: items
        )
    }

    private static func validatedOrigin(_ value: Any?) throws -> String {
        guard let origin = value as? String,
              allowedOrigins.contains(origin),
              let components = URLComponents(string: origin),
              components.scheme == "https",
              components.host != nil,
              components.port == nil,
              components.user == nil,
              components.password == nil,
              components.path.isEmpty,
              components.query == nil,
              components.fragment == nil else {
            throw ValidationError.disallowedOrigin
        }
        return origin
    }

    private static func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= maximumIdentifierBytes
    }

    private static func hasOnlyKeys(
        _ dictionary: [String: Any],
        _ allowedKeys: Set<String>
    ) -> Bool {
        Set(dictionary.keys) == allowedKeys
    }
}
