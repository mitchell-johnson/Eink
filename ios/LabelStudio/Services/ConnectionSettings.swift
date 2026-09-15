import Foundation
import Security

struct ConnectionSettings {
    static let defaultEndpoint = Bundle.main.object(forInfoDictionaryKey: "LabelServiceURL") as? String ?? ""
    static let service = (Bundle.main.bundleIdentifier ?? "com.example.LabelStudio") + ".connection"
    let endpoint: URL
    let token: String

    init(endpoint: String, token: String) throws {
        let clean = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: clean), url.scheme == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/" else { throw ConnectionError.invalidURL }
        guard token.count >= 32, !token.contains(where: { $0.isWhitespace }) else { throw ConnectionError.invalidToken }
        self.endpoint = url
        self.token = token
    }

    static var savedEndpoint: String { UserDefaults.standard.string(forKey: "proxyEndpoint") ?? defaultEndpoint }
    static func tokenFor(endpoint: String, enteredCode: String) throws -> String {
        try tokenFor(endpoint: endpoint, enteredCode: enteredCode, saved: enteredCode.isEmpty ? load() : nil)
    }

    /// Resolve a saved code without accessing Keychain, so origin binding can be verified independently.
    static func tokenFor(endpoint: String, enteredCode: String, saved: ConnectionSettings?) throws -> String {
        if !enteredCode.isEmpty { return enteredCode.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let saved,
              let candidate = try? ConnectionSettings(endpoint: endpoint, token: saved.token),
              candidate.endpoint.scheme == saved.endpoint.scheme,
              candidate.endpoint.host?.lowercased() == saved.endpoint.host?.lowercased(),
              candidate.endpoint.port == saved.endpoint.port else { throw ConnectionError.invalidToken }
        return saved.token
    }
    static func load() -> ConnectionSettings? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: "owner", kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let token = String(data: data, encoding: .utf8) else { return nil }
        return try? ConnectionSettings(endpoint: savedEndpoint, token: token)
    }

    func save() throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service, kSecAttrAccount as String: "owner"]
        let attributes: [String: Any] = [kSecValueData as String: Data(token.utf8), kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updated == errSecItemNotFound {
            let status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
            guard status == errSecSuccess else { throw ConnectionError.keychain }
        } else if updated != errSecSuccess { throw ConnectionError.keychain }
        UserDefaults.standard.set(endpoint.absoluteString, forKey: "proxyEndpoint")
    }

    static func remove() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "owner"] as CFDictionary)
        UserDefaults.standard.removeObject(forKey: "proxyEndpoint")
    }
}

enum ConnectionError: LocalizedError {
    case invalidURL, invalidToken, keychain
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Enter the HTTPS address of your private server, without a path or query."
        case .invalidToken: return "Enter your private connection code. It must have at least 32 characters and no spaces."
        case .keychain: return "The connection code could not be saved securely. Unlock your iPhone and try again."
        }
    }
}
