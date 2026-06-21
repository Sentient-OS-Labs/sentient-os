//
//  CookieDecryptor.swift
//  Sentient OS macOS
//
//  Proactive Intelligence — PART 3 (the executor), the TRUSTED cookie layer. To let a private,
//  headless Chromium act as the user on the long tail of normal sites, we log it in by decrypting
//  the user's own Chromium-browser cookies ourselves (the app has Full Disk Access + owns the
//  Keychain interaction) and handing them to Playwright as a `storageState` JSON — never touching the
//  user's running browser, never copying a profile (we only READ the cookie DB). We support every
//  Chromium browser that shares the macOS `v10` scheme — today Chrome AND Edge (`Browser` enum); the
//  decryption is byte-identical, only the cookie-DB location + Keychain service name differ. Which
//  browser we act in follows the user's DEFAULT browser (`resolveBrowser`). Browser/Arch receipts:
//  Documentation/Browser Automation & Session Reuse (Proactive Part 3).md §3.4.
//
//  The macOS `v10` recipe (all measured): Keychain "<Browser> Safe Storage" key → PBKDF2-HMAC-SHA1
//  (salt "saltysalt", 1003 iters, 16-byte key) → AES-128-CBC (iv = 16×0x20) per cookie → strip
//  PKCS7 padding → strip a 32-byte SHA256(host_key) domain prefix if present → UTF-8 value.
//
//  Key methods:
//   - CookieDecryptor.resolveBrowser()               → which Chromium to act in (override → default → installed)
//   - CookieDecryptor.makeStorageState(domains:to:)  → resolve + write a Playwright storageState (scoped)
//   - CookieDecryptor.registrableDomain(_:)          → last-two-label domain (cookie scoping)
//
//  Raw cookies + the key NEVER leave this trusted Swift layer (Invariant 1 spirit): only the
//  storageState file path is handed to the browser session, and the executor deletes it after.
//

import Foundation
import CommonCrypto
import AppKit   // NSWorkspace — default-browser query (NSWorkspace isn't UI-actor-isolated; safe off-main)

/// Pure utility (crypto + file IO + Process) — `nonisolated` so the off-main ProactiveExecutor actor
/// can call it directly (the project defaults declarations to @MainActor; these don't belong there).
nonisolated enum CookieDecryptor {

    /// A supported Chromium browser. All share the identical macOS `v10` cookie-encryption scheme
    /// (§3.4) — only the cookie-DB location and the Keychain "Safe Storage" service name differ, so
    /// adding a browser is just three strings here.
    enum Browser: String, CaseIterable {
        case chrome
        case edge

        /// `Application Support/<this>` — the browser's user-data root.
        var appSupportSubdir: String {
            switch self {
            case .chrome: return "Google/Chrome"
            case .edge:   return "Microsoft Edge"
            }
        }
        /// Keychain generic-password service holding the AES key.
        var keychainService: String {
            switch self {
            case .chrome: return "Chrome Safe Storage"
            case .edge:   return "Microsoft Edge Safe Storage"
            }
        }
        /// LaunchServices bundle id of the app — for matching the user's default browser.
        var bundleID: String {
            switch self {
            case .chrome: return "com.google.chrome"
            case .edge:   return "com.microsoft.edgemac"
            }
        }
        var displayName: String {
            switch self {
            case .chrome: return "Google Chrome"
            case .edge:   return "Microsoft Edge"
            }
        }
    }

    enum CookieError: LocalizedError {
        case noBrowser
        case cookiesNotFound(Browser)
        case keychain(Browser, String)
        var errorDescription: String? {
            switch self {
            case .noBrowser:
                return "No supported browser found — browser actions need Google Chrome or Microsoft Edge with a signed-in profile."
            case .cookiesNotFound(let b):
                return "No \(b.displayName) cookie database found — browser actions need \(b.displayName) with a signed-in profile."
            case .keychain(let b, let m):
                return "Couldn't read the \(b.displayName) Safe Storage key from the Keychain (\(m.prefix(160)))."
            }
        }
    }

    // MARK: Public

    /// Decrypt the user's cookies for whichever browser `resolveBrowser` picks (optionally scoped to
    /// `domains`) and write a Playwright `storageState` JSON to `fileURL`. Returns which browser was
    /// used + how many cookies decrypted / were written.
    @discardableResult
    static func makeStorageState(domains: [String], to fileURL: URL) throws -> (browser: Browser, decrypted: Int, written: Int) {
        guard let browser = resolveBrowser() else { throw CookieError.noBrowser }
        let counts = try makeStorageState(browser: browser, domains: domains, to: fileURL)
        return (browser, counts.decrypted, counts.written)
    }

    /// Same, for an explicit browser (the dev override / self-test path). Reads the live Cookies DB
    /// WAL-safely and deletes the copy.
    @discardableResult
    static func makeStorageState(browser: Browser, domains: [String], to fileURL: URL) throws -> (decrypted: Int, written: Int) {
        guard let dbPath = cookieDBPath(for: browser) else { throw CookieError.cookiesNotFound(browser) }
        let key = try deriveKey(password: try safeStoragePassword(for: browser))
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

    // MARK: Browser resolution

    /// Which browser to act in: a `SENTIENT_BROWSER` dev override → the user's DEFAULT browser (if it's
    /// a supported Chromium that has a cookie DB) → the first installed supported browser with cookies
    /// (Chrome first). The override is honored even with no cookie DB, so a forced run surfaces a clear
    /// `cookiesNotFound` instead of silently falling through.
    static func resolveBrowser() -> Browser? {
        if let raw = ProcessInfo.processInfo.environment["SENTIENT_BROWSER"]?.lowercased(),
           let forced = Browser(rawValue: raw) {
            return forced
        }
        if let defID = defaultBrowserBundleID(),
           let match = Browser.allCases.first(where: { $0.bundleID == defID }),
           cookieDBPath(for: match) != nil {
            return match
        }
        return Browser.allCases.first { cookieDBPath(for: $0) != nil }
    }

    /// The bundle id of the system default `https` handler (e.g. "com.google.chrome"), lowercased.
    static func defaultBrowserBundleID() -> String? {
        guard let url = URL(string: "https://example.com"),
              let appURL = NSWorkspace.shared.urlForApplication(toOpen: url) else { return nil }
        return Bundle(url: appURL)?.bundleIdentifier?.lowercased()
    }

    // MARK: Browser locations

    /// The Cookies DB for the given browser — prefer the `Default` profile, else any profile that has
    /// one. (nil = that browser isn't installed / has no profile with cookies.)
    static func cookieDBPath(for browser: Browser) -> String? {
        let fm = FileManager.default
        let base = "\(fm.homeDirectoryForCurrentUser.path)/Library/Application Support/\(browser.appSupportSubdir)"
        let preferred = ["Default", "Profile 1", "Profile 2"].map { "\(base)/\($0)/Cookies" }
        if let p = preferred.first(where: { fm.fileExists(atPath: $0) }) { return p }
        if let subs = try? fm.contentsOfDirectory(atPath: base) {
            return subs.map { "\(base)/\($0)/Cookies" }.first { fm.fileExists(atPath: $0) }
        }
        return nil
    }

    // MARK: Keychain key

    /// `security find-generic-password -w -s "<Browser> Safe Storage"` → the 24-char password. The
    /// first read from a non-browser app may prompt the user once ("Always Allow") — that's expected.
    static func safeStoragePassword(for browser: Browser) throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = ["find-generic-password", "-w", "-s", browser.keychainService]
        let outPipe = Pipe(), errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        do { try proc.run() } catch { throw CookieError.keychain(browser, "\(error)") }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        let pw = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard proc.terminationStatus == 0, !pw.isEmpty else {
            let err = String(data: errData, encoding: .utf8) ?? ""
            throw CookieError.keychain(browser, err.isEmpty ? "security exited \(proc.terminationStatus)" : err)
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
        guard status == Int32(kCCSuccess) else { throw CookieError.keychain(.chrome, "PBKDF2 failed (\(status))") }
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
