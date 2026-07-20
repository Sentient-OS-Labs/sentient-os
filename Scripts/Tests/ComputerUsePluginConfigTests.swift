import Foundation

@main
struct ComputerUsePluginConfigTests {
    static func main() throws {
        try testIntelDisableThenSkyRepair()
        try testAlternateQuoteTableIsUpdatedWithoutDuplicate()
        try testDottedKeysAreRejectedWithoutChangingInput()
        try testRelativeDottedKeysUnderPluginsAreRejectedAtomically()
        try testPatchIsIdempotent()
        print("ComputerUsePluginConfig fixtures passed")
    }

    private static func testIntelDisableThenSkyRepair() throws {
        let initial = """
        [plugins."computer-use@openai-bundled"]
        enabled = true
        """
        var intel = try ComputerUsePluginConfig.settingEnabled(
            true, for: .sentientIntel, in: initial, createIfMissing: true)
        intel = try ComputerUsePluginConfig.settingEnabled(
            false, for: .sky, in: intel, createIfMissing: false)
        expect(ComputerUsePluginConfig.isEnabled(.sentientIntel, in: intel) == true,
               "Intel plugin must be enabled")
        expect(ComputerUsePluginConfig.isEnabled(.sky, in: intel) == false,
               "Intel setup must disable OpenAI computer use")

        let repaired = try ComputerUsePluginConfig.settingEnabled(
            true, for: .sky, in: intel, createIfMissing: true)
        expect(ComputerUsePluginConfig.isEnabled(.sky, in: repaired) == true,
               "Sky repair must restore enabled=true readiness")
    }

    private static func testAlternateQuoteTableIsUpdatedWithoutDuplicate() throws {
        let initial = """
        [plugins.'computer-use@sentient']
        enabled = false
        """
        let patched = try ComputerUsePluginConfig.settingEnabled(
            true, for: .sentientIntel, in: initial, createIfMissing: true)
        expect(ComputerUsePluginConfig.isEnabled(.sentientIntel, in: patched) == true,
               "single-quoted table must be recognized")
        expect(patched.contains("[plugins.'computer-use@sentient']"),
               "existing quote style must be preserved")
        expect(!patched.contains("[plugins.\"computer-use@sentient\"]"),
               "equivalent double-quoted table must not be appended")
    }

    private static func testDottedKeysAreRejectedWithoutChangingInput() throws {
        for (plugin, initial) in [
            (ComputerUsePluginConfig.Plugin.sentientIntel,
             "plugins.'computer-use@sentient'.enabled = true\n"),
            (.sky, "plugins.\"computer-use@openai-bundled\".enabled = false\n")
        ] {
            let before = initial
            do {
                _ = try ComputerUsePluginConfig.settingEnabled(
                    true, for: plugin, in: initial, createIfMissing: true)
                fail("semantic dotted key must be rejected")
            } catch let error as ComputerUsePluginConfig.PatchError {
                expect(error == .dottedKey(plugin.identifier), "unexpected dotted-key error: \(error)")
            }
            expect(initial == before, "failed patch must leave caller input unchanged")
        }
    }

    private static func testPatchIsIdempotent() throws {
        let once = try ComputerUsePluginConfig.settingEnabled(
            true, for: .sentientIntel, in: "", createIfMissing: true)
        let twice = try ComputerUsePluginConfig.settingEnabled(
            true, for: .sentientIntel, in: once, createIfMissing: true)
        expect(once == twice, "same patch must be byte-idempotent")
    }

    private static func testRelativeDottedKeysUnderPluginsAreRejectedAtomically() throws {
        let fixtures: [(ComputerUsePluginConfig.Plugin, String)] = [
            (.sky, """
            [plugins]
            "computer-use@openai-bundled".enabled = true
            """),
            (.sentientIntel, """
            [plugins]
            'computer-use@sentient'.enabled = true
            """)
        ]

        for (plugin, original) in fixtures {
            let before = Data(original.utf8)
            expect(ComputerUsePluginConfig.hasUnsupportedDottedEnabledKey(plugin, in: original),
                   "relative dotted alias must be visible to readiness for \(plugin.identifier)")
            do {
                _ = try ComputerUsePluginConfig.settingEnabled(
                    true, for: plugin, in: original, createIfMissing: true)
                fail("relative dotted key under [plugins] must be rejected")
            } catch let error as ComputerUsePluginConfig.PatchError {
                expect(error == .dottedKey(plugin.identifier),
                       "unexpected relative dotted-key error: \(error)")
            }
            expect(Data(original.utf8) == before,
                   "rejected relative dotted fixture must remain byte-for-byte unchanged")
        }

        let ambiguousIntelReadiness = """
        [plugins."computer-use@sentient"]
        enabled = true

        [plugins]
        "computer-use@openai-bundled".enabled = true
        """
        expect(ComputerUsePluginConfig.hasUnsupportedDottedEnabledKey(.sky, in: ambiguousIntelReadiness),
               "active relative Sky alias must block Intel readiness")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fail(message) }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}
