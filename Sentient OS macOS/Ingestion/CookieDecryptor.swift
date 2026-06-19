//
//  CookieDecryptor.swift
//  Sentient OS macOS
//
//  Proactive Intelligence — PART 3 (the executor), the TRUSTED cookie layer. To let a private,
//  headless Chromium act as the user on the long tail of normal sites, we log it in by decrypting
//  the user's own Chrome cookies ourselves (the app has Full Disk Access + owns the Keychain
//  interaction) and handing them to Playwright as a `storageState` JSON — never touching the user's
//  running browser, never copying a profile (we only READ the cookie DB). Browser/Arch receipts:
//  Documentation/Browser Automation & Session Reuse (Proactive Part 3).md §3.4.
//
//  The macOS `v10` recipe (all measured): Keychain "Chrome Safe Storage" key → PBKDF2-HMAC-SHA1
//  (salt "saltysalt", 1003 iters, 16-byte key) → AES-128-CBC (iv = 16×0x20) per cookie → strip
//  PKCS7 padding → strip a 32-byte SHA256(host_key) domain prefix if present → UTF-8 value.
//
//  Key methods:
//   - CookieDecryptor.makeStorageState(domains:to:)  → write a Playwright storageState (scoped)
//   - CookieDecryptor.registrableDomain(_:)          → last-two-label domain (cookie scoping)
//
//  Raw cookies + the key NEVER leave this trusted Swift layer (Invariant 1 spirit): only the
//  storageState file path is handed to the browser session, and the executor deletes it after.
//

import Foundation
import CommonCrypto

/// Pure utility (crypto + file IO + Process) — `nonisolated` so the off-main ProactiveExecutor actor
/// can call it directly (the project defaults declarations to @MainActor; these don't belong there).
nonisolated enum CookieDecryptor {

    enum CookieError: LocalizedError {
        case chromeNotFound
        case keychain(String)
        var errorDescription: String? {
            switch self {
            case .chromeNotFound:  return "No Google Chrome cookie database found — browser actions need your default browser to be Google Chrome."
            case .keychain(let m): return "Couldn't read the Chrome Safe Storage key from the Keychain (\(m.prefix(160)))."
            }
        }
    }

    // MARK: Public

    /// Decrypt the user's Chrome cookies (optionally scoped to `domains`, registrable-domain match;
    /// empty = all) and write a Playwright `storageState` JSON to `fileURL`. Returns how many cookies
    /// decrypted and how many were written. Reads the live Cookies DB WAL-safely and deletes the copy.
    @discardableResult
    static func makeStorageState(domains: [String], to fileURL: URL) throws -> (decrypted: Int, written: Int) {
        guard let dbPath = cookieDBPath() else { throw CookieError.chromeNotFound }
        let key = try deriveKey(password: try safeStoragePassword())
        let scope = Set(domains.map(registrableDomain))

        let (dbURL, tempDir) = try SQLiteDB.walSafeCopy(of: dbPath)
        defer { try? FileManager.default.removeItem(at: tempDir) }   // no plaintext copy lingers

        var cookies: [PWCookie] = []
        var decrypted = 0
        let reader = try SQLiteReader(path: dbURL.path)
        try reader.forEachRow("""
            SELECT host_key, name, value, encrypted_value, path, expires_utc, is_secure, is_httponly, samesite FROM cookies
            """) { row in
            let hostKey = row.text(0) ?? ""
            guard !hostKey.isEmpty else { return }
            if !scope.isEmpty {
                let stripped = hostKey.hasPrefix(".") ? String(hostKey.dropFirst()) : hostKey
                guard scope.contains(registrableDomain(stripped)) else { return }
            }
            let name = row.text(1) ?? ""
            let plainCol = row.text(2) ?? ""
            let enc = row.blob(3) ?? Data()

            let value: String
            if enc.count > 3, enc[enc.startIndex] == 0x76, enc[enc.startIndex + 1] == 0x31, enc[enc.startIndex + 2] == 0x30 {
                guard let v = decryptValue(enc, key: key, hostKey: hostKey) else { return }
                value = v
                decrypted += 1
            } else if !plainCol.isEmpty {
                value = plainCol            // rare unencrypted cookie
            } else {
                return
            }

            cookies.append(PWCookie(
                name: name,
                value: value,
                domain: hostKey,
                path: row.text(4) ?? "/",
                expires: chromeTimeToUnix(row.int(5)),
                httpOnly: row.int(7) != 0,
                secure: row.int(6) != 0,
                sameSite: sameSite(row.int(8))))
        }

        let state = PWStorageState(cookies: cookies, origins: [])
        let data = try JSONEncoder().encode(state)
        try data.write(to: fileURL, options: .atomic)
        return (decrypted, cookies.count)
    }

    /// The registrable (eTLD+1-ish) domain — last two labels. Good enough for cookie scoping; we
    /// don't try to be correct about multi-label public suffixes (`co.uk`) here.
    static func registrableDomain(_ host: String) -> String {
        let parts = host.split(separator: ".")
        guard parts.count >= 2 else { return host }
        return parts.suffix(2).joined(separator: ".")
    }

    // MARK: Chrome locations

    /// The Cookies DB for the user's Chrome — prefer the `Default` profile, else any profile that
    /// has one. (Other Chromium browsers / Safe-Storage keys are future work — §7.)
    static func cookieDBPath() -> String? {
        let fm = FileManager.default
        let base = "\(fm.homeDirectoryForCurrentUser.path)/Library/Application Support/Google/Chrome"
        let preferred = ["Default", "Profile 1", "Profile 2"].map { "\(base)/\($0)/Cookies" }
        if let p = preferred.first(where: { fm.fileExists(atPath: $0) }) { return p }
        if let subs = try? fm.contentsOfDirectory(atPath: base) {
            return subs.map { "\(base)/\($0)/Cookies" }.first { fm.fileExists(atPath: $0) }
        }
        return nil
    }

    // MARK: Keychain key

    /// `security find-generic-password -w -s "Chrome Safe Storage"` → the 24-char password. The
    /// first read from a non-Chrome app may prompt the user once ("Always Allow") — that's expected.
    static func safeStoragePassword() throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = ["find-generic-password", "-w", "-s", "Chrome Safe Storage"]
        let outPipe = Pipe(), errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        do { try proc.run() } catch { throw CookieError.keychain("\(error)") }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        let pw = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard proc.terminationStatus == 0, !pw.isEmpty else {
            let err = String(data: errData, encoding: .utf8) ?? ""
            throw CookieError.keychain(err.isEmpty ? "security exited \(proc.terminationStatus)" : err)
        }
        return pw
    }

    // MARK: Crypto

    /// PBKDF2-HMAC-SHA1(password, "saltysalt", 1003, 16) — the Chromium-on-macOS key derivation.
    static func deriveKey(password: String) throws -> [UInt8] {
        let pw = Array(password.utf8).map { Int8(bitPattern: $0) }
        let salt = Array("saltysalt".utf8)
        var derived = [UInt8](repeating: 0, count: 16)
        let status = pw.withUnsafeBufferPointer { pwPtr in
            salt.withUnsafeBufferPointer { saltPtr in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                     pwPtr.baseAddress, pwPtr.count,
                                     saltPtr.baseAddress, saltPtr.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                                     1003,
                                     &derived, derived.count)
            }
        }
        guard status == Int32(kCCSuccess) else { throw CookieError.keychain("PBKDF2 failed (\(status))") }
        return derived
    }

    /// Decrypt one `v10` cookie value: AES-128-CBC (iv = 16 spaces), strip PKCS7, strip a 32-byte
    /// `SHA256(host_key)` domain-binding prefix (Chrome ≥ ~130) if present, UTF-8 decode.
    static func decryptValue(_ encrypted: Data, key: [UInt8], hostKey: String) -> String? {
        let cipher = encrypted.dropFirst(3)                  // strip the "v10" tag
        guard cipher.count >= 16, cipher.count % 16 == 0 else { return nil }
        guard var plain = aesCBCDecrypt(Data(cipher), key: key) else { return nil }
        // strip PKCS7 padding
        if let pad = plain.last, pad >= 1, pad <= 16, plain.count >= Int(pad) {
            plain = plain.prefix(plain.count - Int(pad))
        }
        // strip the SHA256(host_key) domain prefix if present
        if plain.count >= 32, Data(plain.prefix(32)) == sha256(Data(hostKey.utf8)) {
            plain = Data(plain.dropFirst(32))
        }
        return String(data: Data(plain), encoding: .utf8)
    }

    private static func aesCBCDecrypt(_ cipher: Data, key: [UInt8]) -> Data? {
        let iv = [UInt8](repeating: 0x20, count: 16)
        var out = [UInt8](repeating: 0, count: cipher.count + kCCBlockSizeAES128)
        var moved = 0
        let status = cipher.withUnsafeBytes { cin -> CCCryptorStatus in
            key.withUnsafeBufferPointer { kp in
                iv.withUnsafeBufferPointer { ivp in
                    CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES128), CCOptions(0),
                            kp.baseAddress, kp.count,
                            ivp.baseAddress,
                            cin.baseAddress, cipher.count,
                            &out, out.count, &moved)
                }
            }
        }
        guard status == Int32(kCCSuccess) else { return nil }
        return Data(out.prefix(moved))
    }

    private static func sha256(_ data: Data) -> Data {
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &hash) }
        return Data(hash)
    }

    // MARK: Field mapping

    /// Chrome `expires_utc` (µs since 1601) → Playwright `expires` (unix seconds; -1 = session).
    private static func chromeTimeToUnix(_ expiresUTC: Int64) -> Double {
        expiresUTC == 0 ? -1 : Double(expiresUTC) / 1_000_000 - 11_644_473_600
    }

    /// Chrome `samesite` enum → Playwright string. (2 Strict · 1 Lax · 0 None · -1 → Lax)
    private static func sameSite(_ v: Int64) -> String {
        switch v {
        case 2:  return "Strict"
        case 0:  return "None"
        default: return "Lax"
        }
    }

    // MARK: Playwright storageState shape  ({ "cookies": [...], "origins": [] })

    private struct PWCookie: Encodable {
        let name: String
        let value: String
        let domain: String
        let path: String
        let expires: Double
        let httpOnly: Bool
        let secure: Bool
        let sameSite: String
    }
    private struct PWStorageState: Encodable {
        let cookies: [PWCookie]
        let origins: [String]   // localStorage export is Tier-2 future work (§7) — empty for now
    }
}
