//
//  CuaDriverSetup.swift
//  Sentient OS macOS  ·  Driver/
//
//  Puts the pinned cua-driver binary on the user's Mac — step 3 of Codex setup (CodexSetup owns
//  the flow; onboarding arms it in the background two minutes into the first analysis).
//
//  The chain, in order, each step able to say no:
//    1. Download the pinned release tarball straight from Cua's GitHub release (~40 MB).
//    2. SHA-256 the bytes against the pin. Upstream's own installer does not checksum; we do.
//    3. Extract ONLY `cua-driver` from it (the tarball also carries SDK artifacts we never run).
//    4. Verify the extracted Mach-O still satisfies a codesign requirement naming Cua AI's team —
//       so we run their signature, unmodified, or nothing.
//    5. Smoke-run `--version` and require the pinned string back: proof it actually executes here.
//    6. Atomic move into `…/SentientOS/CuaDriver/<version>/`, then sweep older versions.
//  Any failure leaves the previous install untouched and the staging directory swept.
//
//  Key entry points: install(force:onLine:) · removeAll()
//
//

import CryptoKit
import Foundation

enum CuaDriverSetup {

    enum SetupError: LocalizedError {
        case download(String), integrity(String), extract(String), signature(String), smoke(String), install(String)
        var errorDescription: String? {
            switch self {
            case .download(let m):  return "Download failed: \(m)"
            case .integrity(let m): return "The Cua driver download did not match its checksum (\(m))."
            case .extract(let m):   return "Couldn't unpack the Cua driver: \(m)"
            case .signature(let m): return "The Cua driver's signature did not verify (\(m))."
            case .smoke(let m):     return "The Cua driver did not run on this Mac (\(m))."
            case .install(let m):   return "Couldn't put the Cua driver in place: \(m)"
            }
        }
    }

    // MARK: The bootstrap

    /// Download, verify, and install the pinned cua-driver. Idempotent: a no-op when the pinned
    /// version is already in place (pass `force` to re-fetch it). Streams human-readable progress to
    /// `onLine`, the same convention as every other setup step.
    static func install(force: Bool = false, onLine: @escaping @Sendable (String) -> Void) async throws {
        if !force, CuaDriver.isInstalled { onLine("✓ Cua driver already installed"); return }

        let fm = FileManager.default
        let staging = CuaDriver.installRoot.appendingPathComponent(".download-\(UUID().uuidString.prefix(8))",
                                                                   isDirectory: true)
        try? fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        // 1) Download. Whole-file: at ~40 MB a clean retry costs less than resume bookkeeping (the
        //    3.66 GB model is the one that earns chunked resume).
        onLine("Downloading the Cua driver (~\(CuaDriver.tarballBytes / 1_048_576) MB)…")
        let tarball = staging.appendingPathComponent("cua-driver.tar.gz")
        try await download(CuaDriver.tarballURL, to: tarball)

        // 2) The pin. Poisoned bytes stop here, before anything is unpacked or run.
        onLine("Verifying checksum…")
        let digest = try sha256(of: tarball)
        guard digest == CuaDriver.tarballSHA256 else {
            throw SetupError.integrity("expected \(CuaDriver.tarballSHA256.prefix(12))…, got \(digest.prefix(12))…")
        }

        // 3) Just the one member — the SDK dylib and node runtime in the same tarball are for
        //    embedding hosts we are not, and there is no reason to write 48 MB we never load.
        onLine("Unpacking…")
        let extracted = staging.appendingPathComponent("cua-driver")
        let untar = try await sh("/usr/bin/tar", ["-xzf", tarball.path, "-C", staging.path, "cua-driver"])
        guard untar.status == 0, fm.fileExists(atPath: extracted.path) else {
            throw SetupError.extract(untar.out.lastLine)
        }
        // A file we downloaded ourselves carries no quarantine today; strip it anyway so a future
        // macOS that disagrees can't turn this into a mystery "cannot be opened" at fire time.
        _ = try? await sh("/usr/bin/xattr", ["-d", "com.apple.quarantine", extracted.path])

        // 4) Provenance. The hash proves these are the bytes we pinned; this proves Cua signed them
        //    and nothing has touched the binary since.
        onLine("Checking signature…")
        let requirement = "=anchor apple generic and certificate leaf[subject.OU] = \"\(CuaDriver.signingTeamID)\""
        let verify = try await sh("/usr/bin/codesign",
                                  ["--verify", "--strict", "--test-requirement=\(requirement)", extracted.path])
        guard verify.status == 0 else { throw SetupError.signature(verify.out.lastLine) }

        // 5) It exists, it's Cua's, it's intact — but does it RUN here? One cheap exec answers the
        //    architecture, Gatekeeper, and truncation questions at setup time instead of mid-command.
        let probe = try await sh(extracted.path, ["--version"])
        let reported = probe.out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard probe.status == 0, reported.contains(CuaDriver.version) else {
            throw SetupError.smoke(probe.status == 0 ? "reported \"\(reported)\"" : "exit \(probe.status)")
        }

        // 6) Into place. The version directory is built beside the live one and swapped last, so an
        //    interrupted install can never leave a half-written binary where a run would find it.
        let dest = CuaDriver.binaryURL
        do {
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: dest)
            try fm.moveItem(at: extracted, to: dest)
        } catch { throw SetupError.install("\(error)") }
        guard CuaDriver.isInstalled else { throw SetupError.install("post-install check failed") }

        sweepOtherVersions()
        Log("CuaDriverSetup: installed cua-driver \(CuaDriver.version) (verified: sha256 + Cua signature + --version)")
        onLine("✓ Cua driver ready")
    }

    /// Remove every installed driver version — the Uninstall path's explicit sweep. (Uninstall also
    /// removes the whole `SentientOS` support root, so this is belt-and-braces, and the one call a
    /// future "remove the driver" affordance would use.)
    static func removeAll() {
        try? FileManager.default.removeItem(at: CuaDriver.installRoot)
    }

    /// Drop version directories that aren't the pinned one — an app update that bumps the pin
    /// shouldn't leave 60 MB of the previous driver behind forever.
    private static func sweepOtherVersions() {
        let fm = FileManager.default
        let keep = CuaDriver.version
        for name in (try? fm.contentsOfDirectory(atPath: CuaDriver.installRoot.path)) ?? [] where name != keep {
            try? fm.removeItem(at: CuaDriver.installRoot.appendingPathComponent(name))
        }
    }

    // MARK: Plumbing

    /// Download to an exact path. URLSession's async download hands back a temp file the caller owns,
    /// so it moves in the same breath — no window where a finished download is nobody's.
    private static func download(_ url: URL, to dest: URL) async throws {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForResource = 900   // 15 min ceiling for a ~40 MB transfer
        let session = URLSession(configuration: cfg)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (tmp, response) = try await session.download(from: url)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                try? FileManager.default.removeItem(at: tmp)
                throw SetupError.download("HTTP \(http.statusCode)")
            }
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tmp, to: dest)
        } catch let error as SetupError {
            throw error
        } catch {
            throw SetupError.download((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
    }

    /// Streamed SHA-256 — the file never lands in memory whole.
    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Minimal async Process runner (combined stdout+stderr) for the local tar/codesign/probe steps,
    /// off-main via a global queue. Output is small and bounded, so one drain is safe.
    @discardableResult
    private static func sh(_ launch: String, _ args: [String]) async throws -> (status: Int32, out: String) {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: launch)
                p.arguments = args
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = pipe
                do { try p.run() }
                catch { cont.resume(throwing: SetupError.extract("\(launch): \(error)")); return }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                cont.resume(returning: (p.terminationStatus, String(data: data, encoding: .utf8) ?? ""))
            }
        }
    }
}

private extension String {
    /// Last non-empty line — compact error surfacing from multi-line tool output.
    var lastLine: String {
        split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .last(where: { !$0.isEmpty }) ?? self
    }
}
