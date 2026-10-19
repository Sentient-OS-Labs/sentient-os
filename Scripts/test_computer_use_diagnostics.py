#!/usr/bin/env python3
"""Real diagnostic probe, privacy schema and upload client against inert controls/HTTP.
No helper, credentials, user content, screenshots of the desktop or external network.
"""
from pathlib import Path
import platform
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
app = root / 'Sentient OS macOS'
support = r'''
import Foundation
nonisolated enum MailAccountCloudConfiguration {
    static let url = URL(string: "https://support.invalid")!
    static let publishableKey = "fixture-public-key"
}
nonisolated enum OpenAIComputerUse { struct Configuration: Sendable {} }
actor OpenAIComputerUseSession {
    static func open(_ config: OpenAIComputerUse.Configuration) async throws -> OpenAIComputerUseSession { fatalError("No real helper") }
    func call(_ name: String, arguments: Data) async throws -> Data { fatalError("No real helper") }
    func close() {}
}
nonisolated struct CaptureDiagnostics {
    enum Source { case healthProbe }; enum Outcome { case passed, failed, cancelled }
    init(source: Source) {}
    static func environment() async -> [String: String] { [:] }
    func record(_ outcome: Outcome, failure: NativeComputerUseFailure? = nil, fields: [String: String]) {}
}
'''
tests = r'''
import Foundation
import ImageIO
import UniformTypeIdentifiers

@MainActor final class Surface {
    var current = true, clicked = false, edited = false
    var wrongWindow = false, badImage = false, loseFocus = false, uncertainClick = false
    var reads = 0, clicks = 0, edits = 0
    var statuses: [ComputerUseCheckReport.Check: ComputerUseCheckReport.Status] = [:]
    let image: String
    init() {
        let context = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let bytes = NSMutableData()
        let destination = CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        precondition(CGImageDestinationFinalize(destination))
        image = (bytes as Data).base64EncodedString()
    }
    var target: ComputerUseCheckProbe.Target {
        .init(app: "/fixture.app", marker: "Sentient check ABC", buttonLabel: "Check button ABC",
              fieldLabel: "Check text ABC", expectedText: "Synthetic check",
              isCurrent: { self.current }, wasClicked: { self.clicked }, textMatches: { self.edited })
    }
    func call(_ name: String, _ data: Data) throws -> Data {
        let args = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        precondition(args["app"] as? String == "/fixture.app")
        if name == "get_app_state" {
            reads += 1
            if loseFocus && reads == 2 { current = false }
            let marker = wrongWindow ? "Customer window" : "Sentient check ABC"
            return try JSONSerialization.data(withJSONObject: ["content": [
                ["type": "text", "text": "0 standard window \(marker)\n\t1 button Check button ABC\n\t2 text field Check text ABC"],
                ["type": "image", "data": badImage ? "not-an-image" : image]]])
        }
        if name == "click" {
            precondition(args["element_index"] as? String == "1"); clicks += 1; clicked = true
            if uncertainClick { throw NativeComputerUseFailure(kind: .timeout, code: -10005, detail: .timeoutReached, stage: .action) }
        } else if name == "set_value" {
            precondition(args["element_index"] as? String == "2")
            precondition(args["value"] as? String == "Synthetic check"); edits += 1; edited = true
        } else { fatalError("Unexpected tool") }
        return try JSONSerialization.data(withJSONObject: ["content": [["type": "text", "text": "OK"]]])
    }
    func run() async throws {
        try await ComputerUseCheckProbe.run(target: target, call: { name, data in try await self.call(name, data) },
            update: { check, status, _ in self.statuses[check] = status })
    }
}

final class MockHTTP: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var receipt = UUID()
    nonisolated(unsafe) static var firstUnauthorized = false
    nonisolated(unsafe) static var wrongReceipt = false
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "support.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        let path = request.url!.path
        var status = 200
        let payload: [String: Any]
        if path.hasPrefix("/auth/") {
            payload = ["access_token": "fixture-access", "refresh_token": "fixture-refresh", "expires_in": 3600,
                       "user": ["is_anonymous": true]]
        } else if Self.firstUnauthorized {
            Self.firstUnauthorized = false; status = 401; payload = [:]
        } else { payload = ["id": (Self.wrongReceipt ? UUID() : Self.receipt).uuidString] }
        Self.lock.unlock()
        let data = try! JSONSerialization.data(withJSONObject: payload)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
    static func reset(id: UUID, unauthorized: Bool = false, mismatch: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        requests = []; receipt = id; firstUnauthorized = unauthorized; wrongReceipt = mismatch
    }
    static func snapshot() -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
}

@main struct Tests {
    @MainActor static var checks = 0
    @MainActor static func check(_ value: Bool, _ message: String) {
        guard value else { fatalError(message) }; checks += 1
    }
    @MainActor static func main() async throws {
        check(UUID(uuidString: BuildIdentity.identifier) != nil, "Exact binary identifier must be real")
        let good = Surface(); try await good.run()
        check(good.clicks == 1 && good.edits == 1 && good.reads == 5, "Every owned action uses fresh state and verification")
        check([.accessibility, .capture, .click, .textEntry].allSatisfy { good.statuses[$0] == .passed }, "All actual capabilities verified")
        for scenario in 0..<4 {
            let surface = Surface()
            surface.wrongWindow = scenario == 0; surface.badImage = scenario == 1
            surface.loseFocus = scenario == 2; surface.uncertainClick = scenario == 3
            do { try await surface.run(); fatalError("Failed check claimed success") }
            catch let failure as NativeComputerUseFailure {
                check(surface.edits == 0, "No edit after failed evidence or interruption")
                check(surface.clicks == (scenario == 3 ? 1 : 0), "Uncertain action is never replayed")
                if scenario == 0 || scenario == 2 {
                    check(ComputerUseCheckReport.outcome(for: failure) == .interrupted, "Focus/window changes are not broken infrastructure")
                    check(!ComputerUseCheckReport.allowsConnectionRepair(failure), "Focus/window changes never restart the helper")
                }
            }
        }
        do {
            _ = try ComputerUseCheckProbe.element(in: "1 button Check ABC\n2 button Check ABC", label: "Check ABC", role: "button")
            fatalError("Ambiguous control accepted")
        } catch { checks += 1 }
        for message in ["User changed the app; re-query state", "typing was interrupted", "lost focus", "stale element"] {
            let f = NativeComputerUseFailure.classify(["error": message], stage: .action)
            check(f.kind == .unknown, "Interaction errors must not be labelled missing permissions")
            check(!ComputerUseCheckReport.allowsConnectionRepair(f), "Interaction errors must not reset the helper")
            check(f.modelGuidance.contains("retry") && f.modelGuidance.contains("verify"), "Agent gets recovery guidance and effect verification")
        }
        let declined = NativeComputerUseFailure.classify(["error": ["domain": "SCStreamErrorDomain", "code": -3801,
            "message": "screen capture failed"]])
        check(declined.kind == .permission && !ComputerUseCheckReport.allowsConnectionRepair(declined),
              "An explicit OS capture denial needs a grant, not repeated helper restarts")
        check(ComputerUseCheckReport.outcome(for: declined) == .permissionsNeeded, "OS denial routes to specific permission help")
        for detail in [NativeComputerUseFailure.Detail.senderNotAuthenticated, .approvalDenied, .blockedByPolicy] {
            check(ComputerUseCheckReport.outcome(for: .init(kind: .permission, code: nil, detail: detail)) == .needsAttention,
                  "Client authentication and policy refusals are not proof of a denied macOS grant")
        }
        var report = ComputerUseCheckReport(source: .settings, environment: .init(appVersion: "2.0.2", appBuild: "13",
            binaryID: BuildIdentity.identifier, macOS: "27.2.0", backend: "chatgpt", helperVersion: "26.929.1001365",
            helperBuild: 1001365, cliVersion: "0.160.0"))
        var failure = NativeComputerUseFailure(kind: .capture, code: -10005, detail: .screenshotCaptureFailed,
            stage: .appState, systemDomain: "SCStreamErrorDomain", systemCode: -3807)
        failure.modelError = "PRIVATE_MESSAGE private@example.com /Users/private token-secret"
        report.update(.capture, .needsAttention, failure: failure)
        report.recentEvents = [.init(at: Date(), event: "computer_use.capture", fields: [
            "capture_source": "native", "capture_outcome": "failed", "native_detail": "focusChanged",
            "modelError": "PRIVATE_MESSAGE", "tool": "PRIVATE_ACCOUNT", "system_error_code": "-3807",
            "app": "/Users/private/private.app", "reason": "private@example.com"])!]
        report.outcome = .needsAttention; report.finish()
        let encoded = try report.encoded()
        let text = String(decoding: encoded, as: UTF8.self)
        check(!text.contains("PRIVATE") && !text.contains("private@example") && !text.contains("token-secret"), "No raw error text or customer content in support report")
        check(report.recentEvents[0].fields["native_detail"] == "focusChanged" && report.recentEvents[0].fields["tool"] == nil,
              "Recent failures retain only known categories, numeric codes and generated correlation IDs")
        check(text.contains("SCStreamErrorDomain") && text.contains("-3807"), "Underlying content-free failure evidence preserved")
        check(!report.repairVerified, "A repair attempt is not proof of success")
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MockHTTP.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        MockHTTP.reset(id: report.id)
        let client = ComputerUseReportUpload(transport: session)
        check(MockHTTP.snapshot().isEmpty, "Constructing or previewing reports never uploads")
        check(try await client.send(report) == report.id, "Matching receipt accepted")
        check(try await client.send(report) == report.id, "Explicit retry preserves report identity")
        let requests = MockHTTP.snapshot()
        check(requests.filter { $0.url!.path == "/auth/v1/signup" }.count == 1, "Upload retries reuse support identity")
        let uploads = requests.filter { $0.url!.path.contains("submit_computer_use_report") }
        check(uploads.count == 2, "Two explicit sends, no hidden uploads")
        MockHTTP.reset(id: report.id, unauthorized: true)
        let refreshing = ComputerUseReportUpload(transport: session)
        check(try await refreshing.send(report) == report.id, "Expired authorization can refresh once")
        check(MockHTTP.snapshot().filter { $0.url!.query == "grant_type=refresh_token" }.count == 1, "Refresh does not create a replacement identity")
        MockHTTP.reset(id: report.id, mismatch: true)
        do { _ = try await ComputerUseReportUpload(transport: session).send(report); fatalError("Wrong receipt accepted") }
        catch { checks += 1 }
        print("PASS \(checks) diagnostic safety, recovery, privacy and upload checks")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='sentient-doctor-tests-') as directory:
    folder = Path(directory)
    (folder/'Support.swift').write_text(support)
    (folder/'Tests.swift').write_text(tests)
    sources = ['Diagnostics/NativeComputerUseFailure.swift', 'Diagnostics/ComputerUseCheckReport.swift',
               'Diagnostics/ComputerUseCheckProbe.swift', 'Diagnostics/ComputerUseReportUpload.swift',
               'Diagnostics/BuildIdentity.swift', 'Driver/OpenAIComputerUseProbe.swift']
    executable = folder/'tests'
    subprocess.run(['xcrun','swiftc','-parse-as-library','-swift-version','5','-target',
                    f'{platform.machine()}-apple-macos15.0', str(folder/'Support.swift'), str(folder/'Tests.swift'),
                    *[str(app/p) for p in sources], '-o',str(executable)], check=True, timeout=60)
    subprocess.run([str(executable)], check=True, timeout=30)
