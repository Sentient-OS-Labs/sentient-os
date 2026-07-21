//
//  ComputerUseBackend.swift
//  Sentient OS macOS
//
//  Compile-time routing for the Computer Use implementation. Intel builds use Sentient's
//  bundled native service; Apple Silicon builds keep OpenAI's Sky bootstrap unchanged.
//

enum ComputerUseBackend: Sendable, Equatable {
    case sky
    case sentientIntel

    static var current: Self {
        #if arch(x86_64)
        .sentientIntel
        #else
        .sky
        #endif
    }
}
