#!/usr/bin/env python3
"""Serve the production scoped vault MCP on loopback for an explicit synthetic live test.
The caller owns --root and --connection-file, retains stdin open, and configures its own CLI.
No provider key or account is read. SIGTERM stops the child; EOF closes its server normally.
"""
import argparse
from pathlib import Path
import signal
import subprocess
import tempfile
from test_hosted_vault_tools import APP, SUPPORT

MAIN = r'''
import Foundation
import Darwin
nonisolated enum DirectMCPRuntime {
    static func quoted(_ text: String) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed]), as: UTF8.self)
    }
}
@main struct Fixture {
    static func main() async throws {
        let server = try HostedVaultToolServer(root: URL(fileURLWithPath: CommandLine.arguments[1]))
        let connection = try await server.start()
        let config = try JSONSerialization.data(withJSONObject: ["mcpServers":[connection.name:connection.claudeServer]], options: [.sortedKeys])
        let path = CommandLine.arguments[2]
        try config.write(to: URL(fileURLWithPath: path), options: [.atomic])
        chmod(path, 0o600)
        // Keep main's executor available to the real Network/MCP actors until stdin closes.
        await Task.detached { _ = FileHandle.standardInput.readDataToEndOfFile() }.value
        await server.stop()
    }
}
'''

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--connection-file', type=Path, required=True)
    args = parser.parse_args()
    if not args.root.is_dir() or args.root.is_symlink():
        parser.error('--root must be an existing synthetic directory, not a symlink')
    with tempfile.TemporaryDirectory(prefix='sentient-vault-mcp-fixture-') as temporary:
        root = Path(temporary)
        (root/'Support.swift').write_text(SUPPORT[:SUPPORT.index('actor LocalMCPServer')])
        (root/'Main.swift').write_text(MAIN)
        binary = root/'fixture'
        subprocess.run(['swiftc','-swift-version','6','-parse-as-library','-default-isolation','MainActor','-warnings-as-errors',
                        *[str(APP/'Cloud'/name) for name in ['HostedVaultFiles.swift','HostedVaultToolServer.swift','LocalMCPServer.swift','LoopbackHTTP.swift']],
                        str(root/'Support.swift'),str(root/'Main.swift'),'-o',str(binary)],check=True)
        child = subprocess.Popen([str(binary),str(args.root.resolve()),str(args.connection_file.resolve())])
        def stop(signum, frame):
            child.terminate()
        previous = signal.signal(signal.SIGTERM, stop)
        try:
            code = child.wait()
        finally:
            signal.signal(signal.SIGTERM, previous)
            if child.poll() is None:
                child.terminate()
                child.wait(timeout=5)
        raise SystemExit(code)

if __name__ == '__main__':
    main()
