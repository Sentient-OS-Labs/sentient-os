#!/usr/bin/env python3
"""Check optional writing setup using real cycle wrappers and real diagnostic parent semantics.
Only collection/publication I/O and telemetry sinks are inert. No files, preferences, sources,
models, keychain, network, or GUI are accessed.
"""
from pathlib import Path
import subprocess
import tempfile
APP=Path(__file__).resolve().parents[1]/'Sentient OS macOS'

def member(source,signature):
    start=source.index(signature);end=source.index('{',start)+1;depth=1
    while depth:
        depth+=(source[end]=='{')-(source[end]=='}');end+=1
    return source[start:end]

cycle=(APP/'Proactive/ProactiveCycle.swift').read_text()
diag=(APP/'Diagnostics/Diagnostics.swift').read_text()
run=(APP/'Ingestion/ProcessingRun.swift').read_text()
fixture=r'''
import Foundation
import Synchronization
nonisolated enum ModelBackend:String{case chatgpt;static var current:Self{.chatgpt}}
nonisolated enum DoubleTapProvider:String{case fixture}
nonisolated enum FixtureFailure:Error{case collect,publish,required}
nonisolated enum Fixture {
    struct State:Sendable {
        var failCollect=false,failPublish=false,existing=false,initial=true
        var collected=0,published=0,reports=0
    }
    static let state=Mutex(State())
    static func reset(){state.withLock{$0=State()}}
}
nonisolated enum Diagnostics {
    enum Phase:String{case read,publish}
    @TaskLocal static var current:Operation?
    static func causeKey(_ error:Error)->String{"fixture"}
    static func isCancellation(_ error:Error)->Bool{error is CancellationError}
    static func isExpected(_ error:Error)->Bool{isCancellation(error)}
    static func report(){Fixture.state.withLock{$0.reports+=1};_=current?.claim("local_report")}
// REAL_DIAGNOSTICS
}
nonisolated enum CrashReporting {static func diagnosticBreadcrumb(_ name:String,data:[String:String]){}}
nonisolated enum ConnectorClassificationDiagnostics {static var ownsFailures:Bool{false}}
nonisolated enum ChildProcessDiagnostics {
    static func observe<T>(_ operation:()async throws->T)async rethrows->T{try await operation()}
}
@MainActor enum WritingStyle {
    static func exists()->Bool{Fixture.state.withLock{$0.existing}}
    static func collect()async throws->String{
        try await Diagnostics.withOperation("writing_style") {
            try Task.checkCancellation()
            let failed=Fixture.state.withLock{s in s.collected+=1;return s.failCollect}
            if failed{Diagnostics.report();throw FixtureFailure.collect}
            return "synthetic samples"
        }
    }
    static func publishIfNeeded(_ content:String)throws{
        try Task.checkCancellation()
        let failed=Fixture.state.withLock{s in s.published+=1;return s.failPublish}
        if failed{Diagnostics.report();throw FixtureFailure.publish}
    }
}
@MainActor enum ProcessingPlan {static func initialCompletedAt()->Date?{Fixture.state.withLock{$0.initial ? nil:Date(timeIntervalSince1970:1)}}}
func Log(_ text:String){}
func ErrorLabel(_ error:Error)->String{"fixture"}
@MainActor enum ProactiveCycle {
// REAL_WRAPPERS
}
struct RunProgress {
    var diskFull=false,mailIncomplete=false
    var sourceReadFailures:[String:String]=[:]
    var failed=0,extractionFailed=0,parseFailures=0,mailDeferred=0
}
struct CycleFailure:Error{}
enum ProcessingRun {
// REAL_RESULT
}
@main struct Test {
    @MainActor static func main()async{
        var checks=0
        func check(_ result:Bool,_ label:String){precondition(result,label);checks+=1;print("PASS "+label);fflush(stdout)}
        // Demonstrate this harness has production child->parent failure propagation. The
        // isolation assertions below would be meaningless if the stub simply swallowed it.
        Fixture.reset();Fixture.state.withLock{$0.failCollect=true}
        let baseline=Diagnostics.Operation("required_analysis")
        await Diagnostics.$current.withValue(baseline){_=try? await WritingStyle.collect()}
        check(baseline.hasFailure,"unisolated child diagnostic failures really propagate to required analysis")

        Fixture.reset();Fixture.state.withLock{$0.failCollect=true}
        let collectionParent=Diagnostics.Operation("required_analysis")
        let collected=await Diagnostics.$current.withValue(collectionParent){await ProactiveCycle.collectWritingStyle()}
        check(collected==nil && Fixture.state.withLock{$0.reports}==1,"failed optional collection is still reported locally")
        check(!collectionParent.hasFailure,"failed optional collection does not taint required-analysis diagnostics")
        check(ProcessingRun.Result(progress:RunProgress(),hadDiagnostics:collectionParent.hasFailure).complete,
              "successful required analysis remains completable after optional collection failure")

        Fixture.reset();Fixture.state.withLock{$0.failPublish=true}
        let publicationParent=Diagnostics.Operation("required_analysis")
        Diagnostics.$current.withValue(publicationParent){ProactiveCycle.publishWritingStyle("synthetic samples")}
        check(Fixture.state.withLock{$0.reports}==1 && Fixture.state.withLock{$0.published}==1,
              "failed optional publication is attempted once and reported locally")
        check(!publicationParent.hasFailure,"failed optional publication does not taint required-analysis diagnostics")
        check(ProcessingRun.Result(progress:RunProgress(),hadDiagnostics:publicationParent.hasFailure).complete,
              "successful required analysis remains completable after optional publication failure")

        Fixture.reset()
        let successParent=Diagnostics.Operation("required_analysis")
        await Diagnostics.$current.withValue(successParent){
            ProactiveCycle.publishWritingStyle(await ProactiveCycle.collectWritingStyle())
            check(Diagnostics.current === successParent,"optional wrappers restore the parent's task-local context")
        }
        check(Fixture.state.withLock{$0.collected}==1 && Fixture.state.withLock{$0.published}==1
            && !successParent.hasFailure,"successful optional setup still collects and publishes exactly once")
        Diagnostics.$current.withValue(successParent){Diagnostics.report()}
        check(successParent.hasFailure && !ProcessingRun.Result(progress:RunProgress(),hadDiagnostics:successParent.hasFailure).complete,
              "later required-stage failure is still visible and prevents completion")

        Fixture.reset()
        let cancellationParent=Diagnostics.Operation("required_analysis")
        let cancelled=Task { @MainActor in
            await Diagnostics.$current.withValue(cancellationParent){
                let content=await ProactiveCycle.collectWritingStyle()
                ProactiveCycle.publishWritingStyle(content)
                ProactiveCycle.publishWritingStyle("must not publish after cancellation")
                return Task.isCancelled
            }
        }
        cancelled.cancel()
        check(await cancelled.value,"optional isolation preserves caller cancellation")
        check(Fixture.state.withLock{$0.published}==0 && Fixture.state.withLock{$0.reports}==0,
              "cancelled optional work publishes nothing and creates no failure diagnostic")
        check(!cancellationParent.hasFailure,"cancellation does not mark successful required work failed")

        Fixture.reset();Fixture.state.withLock{$0.existing=true}
        _=await ProactiveCycle.collectWritingStyle()
        ProactiveCycle.publishWritingStyle(nil)
        check(Fixture.state.withLock{$0.collected}==0 && Fixture.state.withLock{$0.published}==0,
              "existing style and nil optional output cause no collection or publication")
        print("Writing diagnostic isolation: \(checks) checks passed")
    }
}
'''
fixture=fixture.replace('// REAL_DIAGNOSTICS','\n'.join(member(diag,s)for s in('final class Operation:','static func withOperation<T>(')))
fixture=fixture.replace('// REAL_WRAPPERS','\n'.join(member(cycle,s)for s in('static func collectWritingStyle()','@MainActor static func publishWritingStyle(')))
fixture=fixture.replace('// REAL_RESULT',member(run,'struct Result'))
with tempfile.TemporaryDirectory(prefix='sentient-writing-isolation-')as directory:
    path=Path(directory);(path/'main.swift').write_text(fixture)
    subprocess.run(['xcrun','swiftc','-parse-as-library',str(path/'main.swift'),'-o',str(path/'check')],check=True)
    subprocess.run([str(path/'check')],check=True)
