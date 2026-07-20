//
//  ComputerUsePluginConfig.swift
//  Sentient OS macOS
//
//  Pure TOML text transforms for the two mutually-exclusive Computer Use plugins. This is not a
//  general TOML parser; it recognizes every equivalent quoted spelling of the exact plugin keys
//  Sentient owns and refuses dotted-key aliases rather than risking a duplicate semantic key.
//

import Foundation

enum ComputerUsePluginConfig {
    enum Plugin: Sendable {
        case sky
        case sentientIntel

        var identifier: String {
            switch self {
            case .sky: "computer-use@openai-bundled"
            case .sentientIntel: "computer-use@sentient"
            }
        }

        var canonicalTable: String { #"[plugins."\#(identifier)"]"# }
    }

    enum PatchError: LocalizedError, Equatable {
        case dottedKey(String)
        case duplicateTable(String)
        case duplicateEnabledKey(String)

        var errorDescription: String? {
            switch self {
            case .dottedKey(let identifier):
                "Refusing dotted plugin key for \(identifier); use its [plugins.\"…\"] table."
            case .duplicateTable(let identifier):
                "Duplicate plugin tables for \(identifier)."
            case .duplicateEnabledKey(let identifier):
                "Duplicate enabled keys for \(identifier)."
            }
        }
    }

    static func isEnabled(_ plugin: Plugin, in text: String) -> Bool? {
        let lines = text.components(separatedBy: "\n")
        guard !containsDottedEnabledKey(plugin, in: lines) else { return nil }
        let tableIndexes = lines.indices.filter { isTable(lines[$0], for: plugin) }
        guard tableIndexes.count == 1, let tableIndex = tableIndexes.first else { return nil }

        let endIndex = endOfTable(startingAt: tableIndex, in: lines)
        var values: [Bool] = []
        for index in (tableIndex + 1)..<endIndex {
            guard isEnabledAssignment(lines[index]) else { continue }
            guard let value = boolValue(of: lines[index]) else { return nil }
            values.append(value)
        }
        return values.count == 1 ? values[0] : nil
    }

    static func settingEnabled(_ enabled: Bool, for plugin: Plugin, in text: String,
                               createIfMissing: Bool) throws -> String {
        var lines = text.components(separatedBy: "\n")
        guard !containsDottedEnabledKey(plugin, in: lines) else {
            throw PatchError.dottedKey(plugin.identifier)
        }

        let tableIndexes = lines.indices.filter { isTable(lines[$0], for: plugin) }
        guard tableIndexes.count <= 1 else { throw PatchError.duplicateTable(plugin.identifier) }
        guard let tableIndex = tableIndexes.first else {
            guard createIfMissing else { return text }
            if lines.last != "" { lines.append("") }
            lines.append(plugin.canonicalTable)
            lines.append("enabled = \(enabled)")
            lines.append("")
            return lines.joined(separator: "\n")
        }

        let endIndex = endOfTable(startingAt: tableIndex, in: lines)
        let enabledIndexes = (tableIndex + 1..<endIndex).filter { isEnabledAssignment(lines[$0]) }
        guard enabledIndexes.count <= 1 else {
            throw PatchError.duplicateEnabledKey(plugin.identifier)
        }
        if let enabledIndex = enabledIndexes.first {
            lines[enabledIndex] = replacingBoolAssignment(lines[enabledIndex], value: enabled)
        } else {
            lines.insert("enabled = \(enabled)", at: tableIndex + 1)
        }
        return lines.joined(separator: "\n")
    }

    private static func isTable(_ line: String, for plugin: Plugin) -> Bool {
        let value = uncommented(line).trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.hasPrefix("["), value.hasSuffix("]") else { return false }
        let inner = value.dropFirst().dropLast().filter { !$0.isWhitespace }
        for root in ["plugins", #""plugins""#, "'plugins'"] {
            if inner == #"\#(root)."\#(plugin.identifier)""#
                || inner == "\(root).'\(plugin.identifier)'" { return true }
        }
        return false
    }

    private static func containsDottedEnabledKey(_ plugin: Plugin, in lines: [String]) -> Bool {
        let acceptedRoots = ["plugins", #""plugins""#, "'plugins'"]
        let acceptedEnabled = ["enabled", #""enabled""#, "'enabled'"]
        return lines.contains { line in
            let parts = uncommented(line).split(separator: "=", maxSplits: 1,
                                                  omittingEmptySubsequences: false)
            guard parts.count == 2 else { return false }
            let lhs = parts[0].filter { !$0.isWhitespace }
            for root in acceptedRoots {
                for key in acceptedEnabled where
                    lhs == #"\#(root)."\#(plugin.identifier)".\#(key)"#
                        || lhs == "\(root).'\(plugin.identifier)'.\(key)" { return true }
            }
            return false
        }
    }

    private static func endOfTable(startingAt tableIndex: Int, in lines: [String]) -> Int {
        guard tableIndex + 1 < lines.count else { return lines.count }
        return ((tableIndex + 1)..<lines.count).first { isAnyTable(lines[$0]) } ?? lines.count
    }

    private static func isAnyTable(_ line: String) -> Bool {
        let value = uncommented(line).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.hasPrefix("[") && value.hasSuffix("]")
    }

    private static func isEnabledAssignment(_ line: String) -> Bool {
        let parts = uncommented(line).split(separator: "=", maxSplits: 1,
                                               omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        switch parts[0].trimmingCharacters(in: .whitespacesAndNewlines) {
        case "enabled", #""enabled""#, "'enabled'": return true
        default: return false
        }
    }

    private static func boolValue(of line: String) -> Bool? {
        let parts = uncommented(line).split(separator: "=", maxSplits: 1,
                                               omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        switch parts[1].trimmingCharacters(in: .whitespacesAndNewlines) {
        case "true": return true
        case "false": return false
        default: return nil
        }
    }

    private static func replacingBoolAssignment(_ line: String, value: Bool) -> String {
        let indentation = line.prefix { $0 == " " || $0 == "\t" }
        let key = uncommented(line).split(separator: "=", maxSplits: 1,
                                           omittingEmptySubsequences: false)[0]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let comment = line.firstIndex(of: "#").map { " " + String(line[$0...]) } ?? ""
        return "\(indentation)\(key) = \(value)\(comment)"
    }

    private static func uncommented(_ line: String) -> Substring {
        line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
    }
}
