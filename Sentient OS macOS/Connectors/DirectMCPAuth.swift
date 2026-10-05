//
// DirectMCPAuth.swift
// Native browser OAuth for the shipped remote providers: validated discovery, public-client
// registration, PKCE, token exchange and serialized rotation. Never logs URLs or credentials.
//
// Doc: Documentation - Connectors (Direct MCP).md

import Foundation
import AppKit
import CoreFoundation

nonisolated enum DirectMCPAuth {
    struct Discovery: Sendable {
        let issuer: URL
        let resource: URL
        let authorization: URL
        let token: URL
        let registration: URL?
        let revocation: URL?
        let scopes: [String]
    }

    static func discover(_ provider: DirectMCPProvider) async throws -> Discovery {
        return try await Diagnostics.withOperation("direct_connection") {
            try await Diagnostics.boundary(.connectorFailed, phase: .discovery, reason: "connection_phase", source: "direct_connector") {
                Diagnostics.step(.discovery, source: "direct_connector")
                let probe = try await DirectMCPHTTP.request(provider.endpoint, provider: provider, method: "POST",
                    headers: ["Content-Type": "application/json", "Accept": "application/json, text/event-stream"],
                    body: DirectMCPHTTP.json(DirectMCPSession.initializeBody(id: 1)))
                guard probe.status == 401 else { throw DirectMCPError.unsupportedRegistration }
                let challenge = try challengeParameters(probe.headers["www-authenticate"] ?? "")
                var candidates: [URL] = []
                if let value = challenge["resource_metadata"] {
                    guard let url = URL(string: value) else { throw DirectMCPError.invalidMetadata }
                    candidates = [url]
                } else {
                    var c = URLComponents(url: provider.endpoint, resolvingAgainstBaseURL: false)!
                    c.query = nil
                    let path = c.path
                    c.path = "/.well-known/oauth-protected-resource" + (path == "/" ? "" : path)
                    if let url = c.url { candidates.append(url) }
                    c.path = "/.well-known/oauth-protected-resource"
                    if let url = c.url, !candidates.contains(url) { candidates.append(url) }
                }
                let resourceMetadata = try await firstMetadata(candidates, provider: provider)
                guard let resourceString = resourceMetadata["resource"] as? String, let resource = URL(string: resourceString),
                      resource.query == nil,
                      resource.host == provider.endpoint.host,
                      resource.port == provider.endpoint.port,
                      provider.endpoint.path == resource.path || provider.endpoint.path.hasPrefix(resource.path.hasSuffix("/") ? resource.path : resource.path + "/") || resource.path.isEmpty,
                      let issuers = resourceMetadata["authorization_servers"] as? [String], !issuers.isEmpty,
                      let issuer = URL(string: issuers[0]), issuer.query == nil else { throw DirectMCPError.invalidMetadata }
                try provider.validate(resource)
                try provider.validate(issuer)
                let metadata = try await firstMetadata(metadataURLs(issuer), provider: provider)
                guard metadata["issuer"] as? String == issuer.absoluteString,
                      (metadata["code_challenge_methods_supported"] as? [String])?.contains("S256") == true,
                      (metadata["token_endpoint_auth_methods_supported"] as? [String])?.contains("none") == true else {
                    throw DirectMCPError.invalidMetadata
                }
                func endpoint(_ key: String, required: Bool = true) throws -> URL? {
                    guard let value = metadata[key] as? String, let url = URL(string: value) else {
                        if required { throw DirectMCPError.invalidMetadata }; return nil
                    }
                    try provider.validate(url)
                    return url
                }
                var scopes = challenge["scope"].map { $0.split(separator: " ").map(String.init) }
                    ?? (resourceMetadata["scopes_supported"] as? [String] ?? [])
                if let offline = provider.offlineScope,
                   (metadata["scopes_supported"] as? [String])?.contains(offline) == true { scopes.append(offline) }
                return try Discovery(issuer: issuer, resource: resource,
                    authorization: endpoint("authorization_endpoint")!, token: endpoint("token_endpoint")!,
                    registration: endpoint("registration_endpoint", required: false),
                    revocation: endpoint("revocation_endpoint", required: false), scopes: Array(Set(scopes)).sorted())
            }
        }
    }

    static func metadataURLs(_ issuer: URL) -> [URL] {
        guard var c = URLComponents(url: issuer, resolvingAgainstBaseURL: false) else { return [] }
        let path = c.path == "/" ? "" : c.path
        c.query = nil
        let paths = ["/.well-known/oauth-authorization-server" + path, "/.well-known/openid-configuration" + path]
            + (path.isEmpty ? [] : [path + "/.well-known/openid-configuration"])
        return paths.compactMap { c.path = $0; return c.url }
    }
    private static func firstMetadata(_ candidates: [URL], provider: DirectMCPProvider) async throws -> [String: Any] {
        for url in candidates {
            let response = try await DirectMCPHTTP.request(url, provider: provider, limit: 128_000)
            if response.status == 404 || response.status == 405 { continue }
            return try DirectMCPHTTP.object(response)
        }
        throw DirectMCPError.invalidMetadata
    }

    static func challengeParameters(_ header: String) throws -> [String: String] {
        guard let expression = try? NSRegularExpression(pattern: #"(?i)([a-z_]+)\s*=\s*(?:"((?:[^"\\]|\\.)*)"|([^\s,]+))"#) else { return [:] }
        var parameters: [String: String] = [:]
        let ns = header as NSString
        for match in expression.matches(in: header, range: NSRange(location: 0, length: ns.length)) {
            let key = ns.substring(with: match.range(at: 1)).lowercased()
            guard ["resource_metadata", "scope"].contains(key) else { continue }
            guard parameters[key] == nil else { throw DirectMCPError.invalidMetadata }
            let range = match.range(at: 2).location != NSNotFound ? match.range(at: 2) : match.range(at: 3)
            parameters[key] = ns.substring(with: range).replacingOccurrences(of: #"\""#, with: #"""#)
                .replacingOccurrences(of: #"\\"#, with: #"\"#)
        }
        return parameters
    }

    static func connect(_ connection: DirectMCPConnection,
                        onProgress: @escaping @Sendable (DirectMCPConnectPhase) async -> Void = { _ in },
                        openBrowser: @escaping @Sendable (URL) async -> Bool = { url in
                            await MainActor.run { NSWorkspace.shared.open(url) }
                        }) async throws -> DirectMCPGrant {
        return try await Diagnostics.withOperation("direct_connection") {
            try await Diagnostics.boundary(.connectorFailed, phase: .connect, reason: "connection_phase", source: "direct_connector") {
                guard let provider = connection.provider else { throw DirectMCPError.unsupportedProvider }
                return try await withThrowingTaskGroup(of: DirectMCPGrant.self) { group in
                    group.addTask {
                        let discovery = try await discover(provider)
                        await Log("Direct MCP: discovery complete")
                        Diagnostics.step(.random, source: "direct_connector")
                        let state = try DirectMCPCrypto.random()
                        let verifier = try DirectMCPCrypto.random()
                        Diagnostics.step(.callback, source: "direct_connector")
                        let callback = try DirectMCPCallback(state: state, issuer: discovery.issuer, providerSlug: provider.slug)
                        defer { callback.cancel() }
                        let redirect = try await callback.start()
                        await Log("Direct MCP: callback listener ready")
                        let clientID: String
                        Diagnostics.step(.read, source: "direct_connector")
                        let existingGrant = try DirectMCPStore.optionalGrant(connection.id)
                        // Reuse an existing registration for the same issuer. Loopback ports may change.
                        if let old = existingGrant, old.issuer == discovery.issuer,
                           old.providerSlug == provider.slug, old.authenticationMethod == "none", old.registrationValid != false {
                            clientID = old.clientID
                        } else {
                            Diagnostics.step(.create, source: "direct_connector")
                            guard let registration = discovery.registration else { throw DirectMCPError.unsupportedRegistration }
                            let metadata: [String: Any] = ["client_name": "Sentient OS", "client_uri": "https://sentient-os.ai",
                                "redirect_uris": [redirect.absoluteString], "grant_types": ["authorization_code", "refresh_token"],
                                "response_types": ["code"], "token_endpoint_auth_method": "none", "application_type": "native"]
                            let reply = try await DirectMCPHTTP.request(registration, provider: provider, method: "POST",
                                headers: ["Content-Type": "application/json"], body: DirectMCPHTTP.json(metadata), limit: 128_000)
                            let value = try DirectMCPHTTP.object(reply)
                            guard let id = value["client_id"] as? String, !id.isEmpty,
                                  value["token_endpoint_auth_method"] as? String == "none" else {
                                throw DirectMCPError.unsupportedRegistration
                            }
                            clientID = id
                        }
                        await Log("Direct MCP: client registration ready")
                        var grant = DirectMCPGrant(connectionID: connection.id, generation: connection.generation,
                            providerSlug: provider.slug, issuer: discovery.issuer, resource: discovery.resource,
                            tokenEndpoint: discovery.token, revocationEndpoint: discovery.revocation, clientID: clientID,
                            clientSecret: nil, authenticationMethod: "none", accessToken: "", refreshToken: nil,
                            expiresAt: nil, issuedAt: Date(), scopes: discovery.scopes)
                        if existingGrant == nil {
                            Diagnostics.step(.write, source: "direct_connector")
                            // Save registration before browser interaction so a retry can reuse it.
                            var pending = grant
                            pending.revoked = true
                            let registration = pending
                            try await DirectMCPStore.withGrantLock(connection.id) {
                                if let current = DirectMCPStore.connection(id: connection.id), current.generation != connection.generation {
                                    throw DirectMCPError.connectionChanged
                                }
                                guard try DirectMCPStore.optionalGrant(connection.id) == nil else { throw DirectMCPError.connectionChanged }
                                try DirectMCPStore.saveGrant(registration)
                            }
                        }
                        var url = URLComponents(url: discovery.authorization, resolvingAgainstBaseURL: false)!
                        Diagnostics.step(.validate, source: "direct_connector")
                        // Do not let metadata supply conflicting authorization parameters.
                        guard url.query == nil else { throw DirectMCPError.invalidMetadata }
                        let parameters = ["response_type": "code", "client_id": clientID, "redirect_uri": redirect.absoluteString,
                            "code_challenge": DirectMCPCrypto.challenge(verifier), "code_challenge_method": "S256", "state": state,
                            "resource": discovery.resource.absoluteString]
                        url.queryItems = parameters.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
                        if !discovery.scopes.isEmpty { url.queryItems?.append(.init(name: "scope", value: discovery.scopes.joined(separator: " "))) }
                        Diagnostics.step(.callback, source: "direct_connector")
                        guard let authorizeURL = url.url, await openBrowser(authorizeURL) else { throw DirectMCPError.network }
                        await Log("Direct MCP: waiting for browser sign-in")
                        await onProgress(.waitingForBrowser)
                        let code = try await callback.response()
                        await Log("Direct MCP: browser response verified")
                        Diagnostics.step(.exchange, source: "direct_connector")
                        let reply = try await DirectMCPHTTP.request(discovery.token, provider: provider, method: "POST",
                            headers: ["Content-Type": "application/x-www-form-urlencoded"], body: DirectMCPHTTP.form([
                                "grant_type": "authorization_code", "code": code, "code_verifier": verifier,
                                "redirect_uri": redirect.absoluteString, "client_id": clientID, "resource": discovery.resource.absoluteString]), limit: 128_000)
                        do { grant = try replacingTokens(grant, response: reply) }
                        catch DirectMCPError.registrationExpired {
                            try await DirectMCPStore.withGrantLock(connection.id) {
                                if var stored = try DirectMCPStore.optionalGrant(connection.id), stored.clientID == clientID {
                                    stored.registrationValid = false; stored.revoked = true
                                    try DirectMCPStore.saveGrant(stored)
                                }
                            }
                            throw DirectMCPError.registrationExpired
                        }
                        await Log("Direct MCP: access exchange complete")
                        try Task.checkCancellation()
                        await onProgress(.savingConnection)
                        return grant
                    }
                    group.addTask { try await Task.sleep(for: .seconds(300)); throw DirectMCPError.timedOut }
                    defer { group.cancelAll() }
                    guard let grant = try await group.next() else { throw DirectMCPError.invalidResponse }
                    return grant
                }
            }
        }
    }

    static func accessToken(id: UUID, generation: UUID, refresh: Bool = false) async throws -> String {
        return try await Diagnostics.withOperation("direct_connection") {
            try await Diagnostics.boundary(.connectorFailed, phase: .refresh, reason: "connection_phase", source: "direct_connector") {
                Diagnostics.step(.read, source: "direct_connector")
                return try await DirectMCPStore.withGrantLock(id) {
                    var grant = try DirectMCPStore.readGrant(id)
                    guard grant.generation == generation else { throw DirectMCPError.connectionChanged }
                    guard !grant.revoked else { throw DirectMCPError.reconnectRequired }
                    guard let provider = DirectMCPProvider.find(grant.providerSlug) else { throw DirectMCPError.unsupportedProvider }
                    try provider.validate(grant.tokenEndpoint)
                    try provider.validate(grant.resource)
                    let expiring = grant.expiresAt.map { $0.timeIntervalSinceNow < 120 } ?? true
                    if let refreshToken = grant.refreshToken, expiring || refresh {
                        Diagnostics.step(.refresh, source: "direct_connector")
                        let reply = try await DirectMCPHTTP.request(grant.tokenEndpoint, provider: provider, method: "POST",
                            headers: ["Content-Type": "application/x-www-form-urlencoded"], body: DirectMCPHTTP.form([
                                "grant_type": "refresh_token", "refresh_token": refreshToken,
                                "client_id": grant.clientID, "resource": grant.resource.absoluteString]), limit: 128_000)
                        do { grant = try replacingTokens(grant, response: reply) }
                        catch DirectMCPError.reconnectRequired {
                            grant.revoked = true
                            try DirectMCPStore.saveGrant(grant)
                            throw DirectMCPError.reconnectRequired
                        }
                        catch DirectMCPError.registrationExpired {
                            grant.revoked = true; grant.registrationValid = false
                            try DirectMCPStore.saveGrant(grant)
                            throw DirectMCPError.registrationExpired
                        }
                        // Persist even if cancellation arrived after the provider rotated the token.
                        Diagnostics.step(.write, source: "direct_connector")
                        try DirectMCPStore.saveGrant(grant)
                    } else if grant.expiresAt.map({ $0 <= Date() }) == true {
                        throw DirectMCPError.reconnectRequired
                    }
                    try Task.checkCancellation()
                    guard !grant.accessToken.isEmpty else { throw DirectMCPError.reconnectRequired }
                    return grant.accessToken
                }
            }
        }
    }

    static func replacingTokens(_ old: DirectMCPGrant, response: DirectMCPHTTP.Response, now: Date = Date()) throws -> DirectMCPGrant {
        if !(200..<300).contains(response.status) {
            if let value = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
               let code = value["error"] as? String {
                if code == "invalid_client" { throw DirectMCPError.registrationExpired }
                if code == "invalid_grant" { throw DirectMCPError.reconnectRequired }
            }
            throw DirectMCPError.http(response.status)
        }
        let value = try DirectMCPHTTP.object(response)
        guard let access = value["access_token"] as? String, !access.isEmpty, access.utf8.count <= 32_768,
              access.utf8.allSatisfy({ $0 > 32 && $0 < 127 }),
              (value["token_type"] as? String)?.lowercased() == "bearer" else { throw DirectMCPError.invalidResponse }
        var grant = old
        grant.accessToken = access
        grant.revoked = false
        grant.registrationValid = true
        grant.issuedAt = now
        grant.expiresAt = nil
        if let rawExpiry = value["expires_in"] {
            guard let expiry = rawExpiry as? NSNumber, CFGetTypeID(expiry) != CFBooleanGetTypeID(),
                  expiry.doubleValue.isFinite, expiry.doubleValue > 0, expiry.doubleValue <= 31_536_000 else {
                throw DirectMCPError.invalidResponse
            }
            grant.expiresAt = now.addingTimeInterval(expiry.doubleValue)
        }
        if let token = value["refresh_token"] {
            guard let token = token as? String, !token.isEmpty, token.utf8.count <= 32_768 else { throw DirectMCPError.invalidResponse }
            grant.refreshToken = token
        }
        if let scopes = value["scope"] as? String { grant.scopes = scopes.split(separator: " ").map(String.init) }
        return grant
    }

    static func revokeAndDelete(_ id: UUID) async throws -> Bool {
        try await DirectMCPStore.withGrantLock(id) {
            let existing: DirectMCPGrant?
            do { existing = try DirectMCPStore.optionalGrant(id) }
            catch DirectMCPError.invalidResponse {
                // A malformed saved record cannot authorize remote revocation, but an explicit
                // disconnect/reset must still be able to remove that local record.
                try DirectMCPStore.deleteGrant(id)
                return false
            }
            guard var grant = existing else { return true }
            grant.revoked = true
            try DirectMCPStore.saveGrant(grant) // any waiting helper now fails closed
            var revokedRemotely = false
            if !grant.accessToken.isEmpty, let endpoint = grant.revocationEndpoint, let provider = DirectMCPProvider.find(grant.providerSlug) {
                let reply = try? await DirectMCPHTTP.request(endpoint, provider: provider, method: "POST",
                    headers: ["Content-Type": "application/x-www-form-urlencoded"], body: DirectMCPHTTP.form([
                        "token": grant.refreshToken ?? grant.accessToken, "client_id": grant.clientID,
                        "token_type_hint": grant.refreshToken != nil ? "refresh_token" : "access_token"]), limit: 64_000)
                revokedRemotely = reply.map { (200..<300).contains($0.status) } ?? false
            }
            try DirectMCPStore.deleteGrant(id)
            return revokedRemotely
        }
    }
}
