#!/usr/bin/env python3
"""Exercise production speed selection, executor routing and labels with synthetic plans.

Compiles the real Swift resolver and executor's selection block. Account reads are inert;
preferences use a process-local volatile domain. No provider calls or app launch occur.
"""
from pathlib import Path
import re
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


def invocation_field(prefix):
    start = codex.index(prefix)
    return codex[start:codex.index('\n', start)]


def proactive_selection(filename, name):
    source = (APP / 'Proactive' / filename).read_text()
    # Execute the callers' actual model/effort assignments without their prompts or tools.
    assignments = re.findall(r'^\s*inv\.(?:model|effort|claudeModel)\s*=.*$', source, re.MULTILINE)
    return '\n'.join((f'static func {name}() -> Invocation {{',
                      'var inv = Invocation()', *assignments, 'return inv', '}'))


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
    'enum ClaudeAuth { static var cachedPlan: String?; static var isPro: Bool { cachedPlan == "pro" } }',
    'enum CodexCLI {',
    member(codex, 'enum Model:'),
    member(codex, 'enum Effort:'),
    'struct Invocation {',
    invocation_field('var model: Model ='),
    invocation_field('var effort: Effort ='),
    invocation_field('var claudeModel:'),
    '}',
    proactive_selection('Proactive.swift', 'planningSelection'),
    proactive_selection('ProactiveResearch.swift', 'researchSelection'),
    member(codex, 'private static func backendTuned('),
    member(codex, 'private static func execArguments('),
    member(codex, 'private static func agentExecArguments('),
    'static func agentPrefix() -> [String] { agentExecArguments() }',
    'static func backgroundPrefix() -> [String] { execArguments(resumeSessionID: "fixture-resume") }',
    'static func backgroundSelection(_ model: Model, _ effort: Effort) -> (modelID: String, effortArg: String) {',
    'backendTuned(model: model, effort: effort)',
    '}',
    'static func agentSelection() throws -> (modelID: String, effortArg: String) {',
    'let backend = ModelBackend.current',
    selection,
    'return (modelID, effortArg)',
    '}',
    '}',
    'enum ClaudeCLI {',
    member(claude, 'enum Model:'),
    member(claude, 'static func tuned(for'),
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
                select("faster")
                let backgroundModels: [CodexCLI.Model] = [.gpt61terra, .gpt61sol, .gpt6astra, .gpt6sol, .gpt56terra, .gpt6luna]
                let backgroundEfforts: [CodexCLI.Effort] = [.low, .medium, .high, .xhigh]
                for model in backgroundModels {
                    for effort in backgroundEfforts {
                        let pair = CodexCLI.backgroundSelection(model, effort)
                        check(pair.modelID == (limited ? "gpt-6-luna" : model.rawValue)
                                && pair.effortArg == effort.rawValue,
                              "\(raw ?? "unknown")/assertedPlus=\(assertedPlus): every background tier uses a supported model and preserves effort")
                        ModelBackend.$runOverride.withValue(.custom) {
                            let pair = CodexCLI.backgroundSelection(model, effort)
                            check(pair.modelID == "fixture-model" && pair.effortArg == "xhigh",
                                  "Custom background model and effort are independent of ChatGPT plan")
                        }
                    }
                }
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
                    check(CodexCLI.agentPrefix().contains(#"service_tier="fast""#) == !limited,
                          "\(context): fast service is requested only for paid ChatGPT Sidekick")
                    check(CodexCLI.backgroundPrefix() == ["exec", "resume", "fixture-resume"],
                          "\(context): background/resume does not request fast service")
                    check(execution.modelID == expectedModel && execution.effortArg == expectedEffort,
                          "\(context): executor uses the resolved pair")
                    let expectedLabel = limited ? "GPT-6 Luna · \(lunaThinking[index]) thinking"
                                                : "\(fullLabels[index]) · low thinking"
                    check(speed.modelLine == expectedLabel, "\(context): Settings matches execution")

                    ModelBackend.$runOverride.withValue(.claude) {
                        check(CodexCLI.agentPrefix() == ["exec"], "Claude never inherits Codex fast service")
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
                        check(CodexCLI.agentPrefix() == ["exec"], "Custom provider never inherits Codex fast service")
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

        // Both proactive stages use the same production selections on every account tier.
        check(ClaudeCLI.Model.haiku.rawValue == "claude-haiku-5-5", "Haiku ingestion is version pinned")
        let planning = CodexCLI.planningSelection(), research = CodexCLI.researchSelection()
        for plan in ["free", "go", "plus", "pro", "team"] {
            CodexAuth.plan = CodexAuth.Plan(raw: plan)
            for inv in [planning, research] {
                let pair = CodexCLI.backgroundSelection(inv.model, inv.effort)
                check(pair.modelID == (["free", "go"].contains(plan) ? "gpt-6-luna" : "gpt-6-sol")
                        && pair.effortArg == "high", "Proactive planning/research match on ChatGPT \(plan)")
            }
        }
        for plan in ["pro", "max", "team", "enterprise", "unknown"] {
            ClaudeAuth.cachedPlan = plan
            for inv in [planning, research] {
                let pair = ClaudeCLI.tuned(for: inv)
                check(pair.modelID == "claude-opus-5-5" && pair.effortArg == "high",
                      "Proactive planning/research use Opus high on Claude \(plan)")
            }
            for model in [ClaudeCLI.Model.opus, .sonnet, .haiku] {
                for effort in [CodexCLI.Effort.low, .medium, .high] {
                    var inv = CodexCLI.Invocation(); inv.claudeModel = model; inv.effort = effort
                    let pair = ClaudeCLI.tuned(for: inv)
                    check(pair.modelID == model.rawValue && pair.effortArg == effort.rawValue,
                          "Claude \(plan) preserves the requested background model and effort")
                }
            }
        }
        print("Computer-use speed and background routing: \(checks) checks passed")
    }
}
'''

with tempfile.TemporaryDirectory(prefix='sentient-computer-use-speed-') as directory:
    path = Path(directory)
    (path / 'main.swift').write_text('\n'.join((fixture, speed, checks)))
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-default-isolation', 'MainActor', '-warnings-as-errors',
                    str(path / 'main.swift'), '-o', str(path / 'check')], check=True)
    subprocess.run([str(path / 'check')], check=True)
