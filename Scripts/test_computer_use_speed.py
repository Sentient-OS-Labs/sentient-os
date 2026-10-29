#!/usr/bin/env python3
"""Exercise production speed selection, executor routing and labels with synthetic plans.

Compiles the real Swift resolver and executor's selection block. Account reads are inert;
preferences use a process-local volatile domain. No provider calls or app launch occur.
"""
from pathlib import Path
import subprocess
import tempfile

APP = Path(__file__).resolve().parents[1] / 'Sentient OS macOS'


def member(source, signature):
    start = source.index(signature)
    end = source.index('{', start) + 1
    depth = 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]


codex = (APP / 'Cloud/CodexCLI.swift').read_text()
claude = (APP / 'Cloud/ClaudeCLI.swift').read_text()
auth = (APP / 'Cloud/CodexAuth.swift').read_text()
backend = (APP / 'Cloud/ModelBackend.swift').read_text()
speed = (APP / 'Cloud/ComputerUseSpeed.swift').read_text()
agent = member(codex, 'func runAgentCommand(')
selection = agent[agent.index('let (model, effort) ='):agent.index('var bridge:')]

fixture = '\n'.join((
    'import Foundation',
    member(backend, 'nonisolated enum ModelBackend:'),
    'enum CodexAuth {',
    member(auth, 'enum Tier:'),
    member(auth, 'struct Plan:'),
    'static var plan: Plan?',
    'static var assertedPlus = false',
    'static func currentPlan() -> Plan? { plan }',
    member(auth, 'static func isLimited()'),
    '}',
    'struct CustomProvider {',
    'var modelName: String',
    'static var current = CustomProvider(modelName: "fixture-model")',
    'static var reasoning = "xhigh"',
    '}',
    'enum HostedClaudeRuntime { static func model() throws -> String { \"hosted-server-model\" } }',
    'enum CodexCLI {',
    member(codex, 'enum Model:'),
    member(codex, 'enum Effort:'),
    member(codex, 'private static func backendTuned('),
    'static func agentSelection() throws -> (modelID: String, effortArg: String) {',
    'let backend = ModelBackend.current',
    selection,
    'return (modelID, effortArg)',
    '}',
    '}',
    'enum ClaudeCLI {',
    member(claude, 'enum Model:'),
    member(claude, 'static func agentTuned()'),
    '}',
))

checks = r'''
@main struct Checks {
    @MainActor static func main() {
        var checks = 0
        func check(_ value: Bool, _ message: String) {
            precondition(value, message)
            checks += 1
        }
        func select(_ speed: String) {
            UserDefaults.standard.setVolatileDomain([
                ComputerUseSpeed.key: speed,
                ModelBackend.key: "chatgpt"
            ], forName: UserDefaults.argumentDomain)
        }
        defer { UserDefaults.standard.removeVolatileDomain(forName: UserDefaults.argumentDomain) }

        let fullModels = ["gpt-6.1-terra", "gpt-6.1-sol", "gpt-6-astra"]
        let fullLabels = ["GPT-6.1 Terra", "GPT-6.1 Sol", "GPT-6 Astra"]
        let lunaEfforts = ["low", "medium", "high"]
        let lunaThinking = ["low", "med", "high"]
        let claudeModels = ["claude-sonnet-5-5", "claude-opus-5-5", "claude-opus-5-5"]
        let claudeLabels = ["Claude Sonnet 5.5 · low thinking", "Claude Opus 5.5 · low thinking",
                            "Claude Opus 5.5 · med thinking"]
        let claudeEfforts = ["low", "low", "medium"]
        let plans: [String?] = ["free", "go", "Free", "Go", "FREE", "GO", "plus", "pro",
                                "prolite", "team", "business", "edu", "enterprise", "future", nil]

        for raw in plans {
            CodexAuth.plan = raw.map { CodexAuth.Plan(raw: $0) }
            for assertedPlus in [false, true] {
                CodexAuth.assertedPlus = assertedPlus
                let limited = !assertedPlus && ["free", "go"].contains(raw?.lowercased() ?? "")
                for (index, speed) in ComputerUseSpeed.allCases.enumerated() {
                    select(speed.rawValue)
                    let context = "\(raw ?? "unknown")/assertedPlus=\(assertedPlus)/\(speed)"
                    check(ComputerUseSpeed.current == speed, "\(context): saved speed is read live")
                    let expectedModel = limited ? "gpt-6-luna" : fullModels[index]
                    let expectedEffort = limited ? lunaEfforts[index] : "low"
                    let pair = speed.codexModelAndEffort
                    check(pair.model.rawValue == expectedModel && pair.effort.rawValue == expectedEffort,
                          "\(context): plan selects supported model and effort")
                    let execution = try! CodexCLI.agentSelection()
                    check(execution.modelID == expectedModel && execution.effortArg == expectedEffort,
                          "\(context): executor uses the resolved pair")
                    let expectedLabel = limited ? "GPT-6 Luna · \(lunaThinking[index]) thinking"
                                                : "\(fullLabels[index]) · low thinking"
                    check(speed.modelLine == expectedLabel, "\(context): Settings matches execution")

                    ModelBackend.$runOverride.withValue(.claude) {
                        let execution = try! CodexCLI.agentSelection()
                        check(execution.modelID == claudeModels[index] && execution.effortArg == claudeEfforts[index],
                              "\(context): Claude routing is independent of the ChatGPT plan")
                        check(speed.modelLine == claudeLabels[index], "\(context): Claude readout is unchanged")
                    }
                    ModelBackend.$runOverride.withValue(.sentient) {
                        let execution = try! CodexCLI.agentSelection()
                        check(execution.modelID == "hosted-server-model" && execution.effortArg == "low",
                              "\(context): hosted execution uses the server model independently of subscriptions and speed")
                        check(speed.modelLine == "Sentient managed model", "\(context): hosted readout makes no unsupported model promise")
                    }
                    ModelBackend.$runOverride.withValue(.custom) {
                        let execution = try! CodexCLI.agentSelection()
                        check(execution.modelID == "fixture-model" && execution.effortArg == "xhigh",
                              "\(context): custom model and effort win")
                        check(speed.modelLine == "fixture-model · xhigh thinking",
                              "\(context): custom readout is unchanged")
                    }
                }
            }
        }

        CodexAuth.assertedPlus = false
        CodexAuth.plan = CodexAuth.Plan(raw: "free")
        for rawSpeed in ["", "unknown-speed"] {
            select(rawSpeed)
            let execution = try! CodexCLI.agentSelection()
            check(ComputerUseSpeed.current == .faster && execution.modelID == "gpt-6-luna"
                    && execution.effortArg == "low", "missing/invalid speed defaults to Free's Luna low")
        }
        // Exercise an upgrade and downgrade without recreating the speed value or restarting.
        select("smarter")
        for plan in ["free", "plus", "go"] {
            CodexAuth.plan = CodexAuth.Plan(raw: plan)
            let execution = try! CodexCLI.agentSelection()
            check(execution.modelID == (plan == "plus" ? "gpt-6-astra" : "gpt-6-luna"),
                  "plan changes take effect on the next run")
        }
        print("Computer-use speed: \(checks) checks passed")
    }
}
'''

with tempfile.TemporaryDirectory(prefix='sentient-computer-use-speed-') as directory:
    path = Path(directory)
    (path / 'main.swift').write_text('\n'.join((fixture, speed, checks)))
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-default-isolation', 'MainActor', '-warnings-as-errors',
                    str(path / 'main.swift'), '-o', str(path / 'check')], check=True)
    subprocess.run([str(path / 'check')], check=True)
