import Foundation
import Security

/// The label key is supplied by the device owner and never bundled with the app.
struct LabelKeyStore {
    let service: String

    init(service: String = (Bundle.main.bundleIdentifier ?? "com.example.LabelStudio") + ".label-authentication") {
        self.service = service
    }

    static func decode(hex: String) throws -> Data {
        let characters = Array(hex.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        guard characters.count == 32 else { throw LabelKeyError.invalid }
        func nibble(_ value: UInt8) -> UInt8? {
            switch value {
            case 48...57: return value - 48
            case 65...70: return value - 55
            case 97...102: return value - 87
            default: return nil
            }
        }
        var key = Data()
        for index in stride(from: 0, to: characters.count, by: 2) {
            guard let high = nibble(characters[index]), let low = nibble(characters[index + 1]) else {
                throw LabelKeyError.invalid
            }
            key.append(high << 4 | low)
        }
        return key
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "label"]
    }

    func load() throws -> Data {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecItemNotFound { throw LabelKeyError.missing }
        guard status == errSecSuccess else { throw LabelKeyError.keychain }
        guard let key = result as? Data, key.count == 16 else { throw LabelKeyError.invalid }
        return key
    }

    func save(hex: String) throws {
        let key = try Self.decode(hex: hex)
        let attributes: [String: Any] = [kSecValueData as String: key,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updated == errSecItemNotFound {
            let status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
            guard status == errSecSuccess else { throw LabelKeyError.keychain }
        } else if updated != errSecSuccess { throw LabelKeyError.keychain }
    }

    func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw LabelKeyError.keychain }
    }
}

enum LabelKeyError: LocalizedError {
    case missing, invalid, keychain

    var errorDescription: String? {
        switch self {
        case .missing: return "Add your label authentication key in Settings before writing to a label."
        case .invalid: return "Enter the label authentication key as exactly 32 hexadecimal characters (0–9, A–F)."
        case .keychain: return "The label key could not be accessed securely. Unlock your iPhone and try again."
        }
    }
}
