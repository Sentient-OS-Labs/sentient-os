// Shared endpoint and installation identity for Double Tap and Summarize. Preserves existing
// production preference/Keychain keys. identity() fails if the credential cannot be saved.
// Doc: ../Double Tap/Documentation - Double Tap.md
import Foundation
import Security

enum ScreenRelay {
    static let defaultURL = "https://sentient-doubletap-relay.sentient-doubletap-relay.workers.dev"
    static let urlKey = "doubletap.relayURL"
    static let identityAccount = "doubletap.relay.identity"

    static var url: URL? {
        let override = UserDefaults.standard.string(forKey: urlKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let value = URL(string: override.isEmpty ? defaultURL : override),
              value.user == nil, value.password == nil, value.query == nil, value.fragment == nil else { return nil }
        if value.scheme == "https", value.host != nil { return value }
        #if DEBUG
        if value.scheme == "http", ["localhost", "127.0.0.1", "::1"].contains(value.host ?? "") { return value }
        #endif
        return nil
    }

    static func identity() throws -> String {
        guard let value = Keychain.readOrCreate(identityAccount, make: {
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
            return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }), !value.isEmpty else { throw Failure.identity }
        return value
    }

    enum Failure: LocalizedError {
        case identity
        var errorDescription: String? { "Sentient couldn’t access its saved connection. Unlock your Mac and try again." }
    }
}
