import AppKit

struct SummarySource: Sendable {
    var text = ""
    var application: String
    var scope: String
    var image: Data?
}
nonisolated enum SummaryAccessibility {
    struct Target: Sendable {
        let pid: pid_t
        var name = "Test app"
        var windowTitle: String? = "Article"
        var windowFrame: CGRect? = nil
    }
    enum Failure: Error { case permission, unavailable, ownApplication }
    static func read(_ target: Target) throws -> SummarySource {
        if target.pid == 0 { throw Failure.unavailable }
        return SummarySource(text: "The complete offscreen article.", application: target.name, scope: "loaded document")
    }
}
enum Permissions {
    static var allowed = true
    static var requests = 0
    static func hasAccessibility() -> Bool { allowed }
    static func requestAccessibility() { requests += 1 }
}
enum ScreenCapture {
    enum SummaryFailure: Error { case permission, capture, displayGone }
    static var calls = 0
    static var result: Result<Data, Error> = .success(Data([1, 2, 3]))
    static func summaryImage(displayID: CGDirectDisplayID, windowPID: pid_t?, windowTitle: String?, windowFrame: CGRect?) async throws -> Data {
        calls += 1
        return try result.get()
    }
}
func Log(_ text: String) {}

@main enum Tests {
    static func main() async throws {
        var checks = 0
        func check(_ condition: Bool, _ label: String) { precondition(condition, label); checks += 1 }
        let frame = CGRect(x: 0, y: 30, width: 2048, height: 1122)
        let full = "Your iPhone Already Has iPhone Fold Software, but Apple Won’t Let You Use It | WIRED - Microsoft Edge"
        let short = "Your iPhone Already Has iPhone …e Won’t Let You Use It | WIRED"
        typealias Window = SummaryWindowSelection.Candidate
        let article = Window(id: 1, pid: 20, title: short, frame: frame)
        let other = Window(id: 2, pid: 20, title: "New Tab", frame: frame)
        func choose(_ windows: [Window], _ title: String? = full, _ bounds: CGRect? = frame) -> CGWindowID? {
            SummaryWindowSelection.choose(windows, pid: 20, title: title, frame: bounds, appName: "Microsoft Edge")
        }
        check(choose([other, article]) == 1, "abbreviated title disambiguates identical maximized window bounds")
        check(choose([article, other]) == 1, "selection is independent of window list order")
        check(choose([other]) == nil, "same geometry never substitutes a differently titled document")
        check(choose([article, Window(id: 3, pid: 20, title: short, frame: frame)]) == nil,
              "ambiguous abbreviated titles do not choose an arbitrary document")
        check(choose([Window(id: 4, pid: 99, title: full, frame: frame), article]) == 1, "another app cannot match")
        check(choose([Window(id: 4, pid: 20, title: full, frame: frame, layer: 5), article]) == 1, "overlay windows cannot match")
        let moved = frame.offsetBy(dx: 80, dy: 15)
        check(choose([Window(id: 5, pid: 20, title: full, frame: moved)]) == 5, "unique exact title tolerates a window move")
        check(choose([Window(id: 5, pid: 20, title: short, frame: moved)]) == nil, "abbreviation requires matching geometry")
        check(choose([Window(id: 6, pid: 20, title: nil, frame: frame)]) == 6, "unique untitled window can use exact geometry")
        check(choose([Window(id: 7, pid: 20, title: "Your…WIRED", frame: frame)]) == nil, "vague title fragments are rejected")
        check(choose([Window(id: 8, pid: 20, title: "Document", frame: frame)], "Document — Microsoft Edge") == 8,
              "full titles normalize a browser suffix")

        Permissions.allowed = false
        do { _ = try await SummaryCapture.capture(displayID: 1, target: .init(pid: getpid())); fatalError("self capture admitted") }
        catch SummaryAccessibility.Failure.ownApplication { checks += 1 }
        check(Permissions.requests == 0 && ScreenCapture.calls == 0, "self summary cannot request permission or take a screenshot")
        Permissions.allowed = true
        let target = SummaryAccessibility.Target(pid: 20)
        let combined = try await SummaryCapture.capture(displayID: 1, target: target)
        check(!combined.text.isEmpty && combined.image == Data([1, 2, 3]), "normal capture keeps AX and screenshot")
        for failure in [ScreenCapture.SummaryFailure.capture, .displayGone] {
            ScreenCapture.result = .failure(failure)
            let text = try await SummaryCapture.capture(displayID: 1, target: target)
            check(text.text == "The complete offscreen article." && text.image == nil, "failed image retains readable AX")
        }
        ScreenCapture.result = .failure(ScreenCapture.SummaryFailure.capture)
        do { _ = try await SummaryCapture.capture(displayID: 1, target: nil); fatalError("missing both sources must fail") }
        catch ScreenCapture.SummaryFailure.capture { checks += 1 }
        ScreenCapture.result = .failure(ScreenCapture.SummaryFailure.permission)
        do { _ = try await SummaryCapture.capture(displayID: 1, target: target); fatalError("screen permission must remain explicit") }
        catch ScreenCapture.SummaryFailure.permission { checks += 1 }
        ScreenCapture.result = .failure(CancellationError())
        do { _ = try await SummaryCapture.capture(displayID: 1, target: target); fatalError("cancelled capture must not continue") }
        catch is CancellationError { checks += 1 }
        Permissions.allowed = false
        do { _ = try await SummaryCapture.capture(displayID: 1, target: target); fatalError("missing AX permission must prompt") }
        catch SummaryAccessibility.Failure.permission { check(Permissions.requests == 1, "AX prompt retained") }
        print("PASS: \(checks) summary window matching and capture checks")
    }
}
