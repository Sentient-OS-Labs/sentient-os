#!/usr/bin/env python3
"""Compile the real analysis owner, idle observer, plan and power policies with inert I/O.

Provider work and XPC replies are controllable continuations. Preferences and vaults are isolated;
no model, connector, daemon, power setting or production application is invoked.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / 'Sentient OS macOS'


def member(source, signature):
    start = source.index(signature)
    end = source.index('{', start) + 1
    depth = 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]


with tempfile.TemporaryDirectory(prefix='sentient-idle-analysis-') as directory:
    target = Path(directory)
    power = (APP / 'Scheduling/PowerState.swift').read_text()
    power = power.replace(member(power, 'static func snapshot()'), '''static var fixtureSnapshot = Snapshot(onAC: true, percent: 100, critical: false)
    static func snapshot() -> Snapshot { fixtureSnapshot }''')
    (target / 'PowerState.swift').write_text(power)
    coordinator = (APP / 'Ingestion/ProcessingCoordinator.swift').read_text()
    coordinator = coordinator.replace('ProcessInfo.processInfo.beginActivity', 'TestActivity.beginActivity')
    coordinator = coordinator.replace('ProcessInfo.processInfo.endActivity', 'TestActivity.endActivity')
    coordinator += '''
extension ProcessingCoordinator {
    var fixtureRunID: UUID { runID }
    func fixtureRequireAwake() { record.trigger = .overnight }
    func fixtureMaintain(for id: UUID? = nil) async -> Bool { await maintainAwake(for: id ?? runID) }
    func fixtureRelease(for id: UUID) async { await releaseAwake(for: id) }
    func fixtureMonitor() async { await checkRunningWork() }
    func fixtureHeartbeatDue() { lastHeartbeatAt = .distantPast }
    func fixtureBudget(_ seconds: Double) { record.activeSeconds = seconds }
    func fixtureStalled() { lastProgressAt = SuspendingClock.now.advanced(by: .seconds(-4300)) }
}
'''
    (target / 'ProcessingCoordinator.swift').write_text(coordinator)
    history = (APP / 'Diagnostics/DiagnosticHistory.swift').read_text()
    history = history.replace('UserDefaults = .standard', 'UserDefaults = FixtureDefaults.history')
    (target / 'DiagnosticHistory.swift').write_text(history)
    binary = target / 'tests'
    sources = [
        ROOT / 'Scripts/Fixtures/PluggedInAnalysisTests.swift',
        target / 'ProcessingCoordinator.swift', target / 'PowerState.swift',
        APP / 'Ingestion/ProcessingPlan.swift', APP / 'Ingestion/InitialAnalysisRecovery.swift',
        APP / 'Scheduling/PluggedInAnalysisScheduler.swift', target / 'DiagnosticHistory.swift',
    ]
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-default-isolation', 'MainActor',
                    '-parse-as-library', *map(str, sources), '-o', str(binary)], check=True, timeout=90)
    subprocess.run([str(binary), str(target)], check=True, timeout=40)
