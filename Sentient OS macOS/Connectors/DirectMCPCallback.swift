//
// DirectMCPCallback.swift
// Receives one verified browser authorization response on an ephemeral IPv4 loopback listener.
// Unrelated requests do not consume the transaction; cancellation and timeout close all sockets.
//
// Doc: Documentation - Connectors (Direct MCP).md

import Foundation
import Network
import os

nonisolated final class DirectMCPCallback: @unchecked Sendable {
    private struct State {
        var continuation: CheckedContinuation<String, Error>?
        var result: Result<String, Error>?
        var connections: [UUID: NWConnection] = [:]
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let queue = DispatchQueue(label: "ai.sentient-os.oauth-callback")
    private let listener: NWListener
    private let expectedState: String
    private let expectedIssuer: String
    private let path: String

    init(state: String, issuer: URL, providerSlug: String) throws {
        expectedState = state
        expectedIssuer = issuer.absoluteString
        path = "/oauth/" + providerSlug
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }
    deinit { listener.cancel() }

    func start() async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let resumed = OSAllocatedUnfairLock(initialState: false)
                listener.stateUpdateHandler = { [weak self] phase in
                    guard let self else { return }
                    let result: Result<URL, Error>?
                    switch phase {
                    case .ready:
                        result = self.listener.port.flatMap { URL(string: "http://127.0.0.1:\($0.rawValue)\(self.path)") }.map(Result.success)
                    case .failed: result = .failure(DirectMCPError.network)
                    case .cancelled: result = .failure(CancellationError())
                    default: result = nil
                    }
                    if let result, resumed.withLock({ value in if value { return false }; value = true; return true }) {
                        continuation.resume(with: result)
                    }
                }
                listener.newConnectionHandler = { [weak self] in self?.accept($0) }
                listener.start(queue: queue)
                if Task.isCancelled { cancel() }
            }
        } onCancel: { self.cancel() }
    }
    func response() async throws -> String {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let result = state.withLock { value -> Result<String, Error>? in
                    if let result = value.result { return result }
                    value.continuation = continuation
                    return nil
                }
                if let result { continuation.resume(with: result) }
                if Task.isCancelled { cancel() }
            }
        } onCancel: { self.cancel() }
    }
    func cancel() { finish(.failure(CancellationError())) }

    private func finish(_ result: Result<String, Error>) {
        let (continuation, connections) = state.withLock { value -> (CheckedContinuation<String, Error>?, [NWConnection]) in
            guard value.result == nil else { return (nil, []) }
            value.result = result
            let continuation = value.continuation
            value.continuation = nil
            let connections = Array(value.connections.values)
            value.connections = [:]
            return (continuation, connections)
        }
        listener.cancel()
        connections.forEach { $0.cancel() }
        continuation?.resume(with: result)
    }
    private func accept(_ connection: NWConnection) {
        let id = UUID()
        let admitted = state.withLock { value in
            guard value.result == nil, value.connections.count < 8 else { return false }
            value.connections[id] = connection
            return true
        }
        guard admitted else { connection.cancel(); return }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 5) { [weak self] in
            connection.cancel()
            self?.state.withLock { _ = $0.connections.removeValue(forKey: id) }
        }
        receive(connection, id: id, accumulated: Data())
    }
    private func receive(_ connection: NWConnection, id: UUID, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4_096) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var buffer = accumulated
            if let data { buffer.append(data) }
            guard buffer.count <= 16_384, error == nil else { connection.cancel(); return }
            if let request = String(data: buffer, encoding: .utf8), request.contains("\r\n\r\n") {
                let result = Self.parse(request, path: self.path, state: self.expectedState, issuer: self.expectedIssuer)
                let accepted = result != nil
                let html = "<!doctype html><meta charset=utf-8><title>Sentient OS</title><p>Return to Sentient to finish connecting.</p>"
                let reply = "HTTP/1.1 \(accepted ? "200 OK" : "400 Bad Request")\r\nContent-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nContent-Security-Policy: default-src 'none'; frame-ancestors 'none'\r\nConnection: close\r\nContent-Length: \(html.utf8.count)\r\n\r\n\(html)"
                connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in
                    connection.cancel()
                    self.state.withLock { _ = $0.connections.removeValue(forKey: id) }
                    if let result { self.finish(result) }
                })
            } else if !complete { self.receive(connection, id: id, accumulated: buffer) }
            else { connection.cancel() }
        }
    }

    static func parse(_ request: String, path: String, state: String, issuer: String) -> Result<String, Error>? {
        guard let first = request.components(separatedBy: "\r\n").first else { return nil }
        let parts = first.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "GET", parts[2] == "HTTP/1.1",
              parts[1].hasPrefix("/"), !parts[1].hasPrefix("//"),
              let url = URLComponents(string: "http://127.0.0.1" + parts[1]), url.path == path,
              let items = url.queryItems else { return nil }
        let names = items.map(\.name)
        guard Set(names).count == names.count,
              items.first(where: { $0.name == "state" })?.value == state else { return nil }
        if let returnedIssuer = items.first(where: { $0.name == "iss" })?.value, returnedIssuer != issuer {
            return .failure(DirectMCPError.invalidCallback)
        }
        if items.contains(where: { $0.name == "error" }) {
            guard !items.contains(where: { $0.name == "code" }) else { return .failure(DirectMCPError.invalidCallback) }
            return .failure(DirectMCPError.authorizationDenied)
        }
        guard let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty, code.utf8.count < 8_192 else { return nil }
        return .success(code)
    }
}
