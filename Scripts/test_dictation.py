#!/usr/bin/env python3
"""Actual Swift Scribe transport and PCM converter against a loopback WebSocket.
Uses synthetic audio/text, no mic permission, provider credentials or app/user data.
"""
from pathlib import Path
import base64
import hashlib
import http.server
import json
import os
import struct
import subprocess
import tempfile
import threading
from urllib.parse import urlparse, parse_qs

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / 'Sentient OS macOS/Notch Magic'
FAILURES = []

class SocketFixture(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *_): pass
    def do_GET(self):
        try:
            path = urlparse(self.path)
            query = parse_qs(path.query)
            assert query['model_id'] == ['scribe_v2_realtime']
            assert query['commit_strategy'] == ['manual']
            assert query['audio_format'] == ['pcm_16000']
            assert query['keyterms'] == ['summarise','summarize','proofread','sentient os','sentient','jesai']
            assert len(query['language_code'][0]) in (2,3)
            assert query['token'] == ['synthetic-token+with/slash=']
            key = self.headers['Sec-WebSocket-Key']
            accept = base64.b64encode(hashlib.sha1((key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
            self.send_response(101)
            self.send_header('Upgrade', 'websocket')
            self.send_header('Connection', 'Upgrade')
            self.send_header('Sec-WebSocket-Accept', accept)
            self.end_headers()
            if path.path != '/never-ready': self.send({'message_type':'session_started'})
            count = 0
            while True:
                header = self.rfile.read(2)
                if len(header) != 2: return
                opcode, length = header[0] & 15, header[1] & 127
                if length == 126: length = struct.unpack('!H', self.rfile.read(2))[0]
                elif length == 127: length = struct.unpack('!Q', self.rfile.read(8))[0]
                assert length < 1_000_000
                mask = self.rfile.read(4) if header[1] & 128 else None
                payload = self.rfile.read(length)
                if mask: payload = bytes(v ^ mask[i % 4] for i, v in enumerate(payload))
                if opcode == 8: return
                if opcode == 9:
                    self.wfile.write(bytes([0x8a, len(payload)]) + payload); self.wfile.flush(); continue
                assert opcode == 1, 'API JSON must be a text WebSocket frame'
                value = json.loads(payload)
                assert value['message_type'] == 'input_audio_chunk'
                assert value['sample_rate'] == 16000
                base64.b64decode(value['audio_base_64'], validate=True)
                if path.path == '/disconnect':
                    self.send({'message_type':'partial_transcript','text':'Keep these words'})
                    self.close_connection = True; return
                if path.path == '/warning':
                    self.send({'message_type':'warning','warning':'private provider text'}); continue
                if value['commit']:
                    if path.path == '/never-commit': continue
                    count += 1
                    self.send({'message_type':'committed_transcript', 'text': 'hello world' if count == 1 else 'hello world again'})
                else:
                    self.send({'message_type':'partial_transcript','text':'hello wor'})
                    self.send({'message_type':'partial_transcript','text':'hello world'})
        except (BrokenPipeError, ConnectionResetError): pass
        except Exception as exc: FAILURES.append(str(exc))
    def send(self, value):
        payload = json.dumps(value).encode()
        header = bytes([0x81, len(payload)]) if len(payload) < 126 else bytes([0x81,126]) + struct.pack('!H',len(payload))
        self.wfile.write(header + payload); self.wfile.flush()

SWIFT = r'''
import Foundation
import AVFAudio
nonisolated enum VoiceError: Error { case deviceChanged }
@main struct Tests {
    @MainActor static func main() async throws {
        let base = CommandLine.arguments[1]
        var checks = 0
        func check(_ value: Bool, _ label: String) { precondition(value, label); checks += 1 }
        var transcript = ScribeTranscript()
        try transcript.update("hello", committed: false)
        try transcript.update("hello world", committed: false)
        check(transcript.text == "hello world", "partials replace, never append")
        try transcript.update("hello world", committed: true)
        try transcript.update("hello world", committed: true)
        check(transcript.text == "hello world hello world", "intentional repeated speech is preserved")
        do { try transcript.update(String(repeating:"x", count: 131073), committed: false); fatalError("unbounded text") }
        catch { checks += 1 }
        let connection = ScribeRealtimeConnection(testEndpoint: URL(string:base + "/success")!)
        var changes: [String] = []
        connection.onTranscript = { changes.append($0) }
        try await connection.connect(token:"synthetic-token+with/slash=", zeroRetention:false)
        try await connection.send(Data(repeating:0,count:3200))
        try await connection.commit()
        check(connection.transcript.text == "hello world", "first committed segment")
        try await connection.send(Data(repeating:0,count:6400))
        try await connection.commit()
        check(connection.transcript.committed == "hello world hello world again", "serial commits preserve segments exactly once")
        check(changes.contains("hello world hello wor"), "live text retains earlier committed segment")
        connection.close()
        for route in ["never-ready", "never-commit"] {
            let socket = ScribeRealtimeConnection(testEndpoint: URL(string:base + "/" + route)!)
            let task = Task {
                try await socket.connect(token:"synthetic-token+with/slash=", zeroRetention:false)
                try await socket.send(Data(repeating:0,count:3200))
                try await socket.commit()
            }
            try await Task.sleep(for:.milliseconds(100))
            task.cancel()
            do { try await task.value; fatalError("cancel should throw") } catch { checks += 1 }
            socket.close()
        }
        let broken = ScribeRealtimeConnection(testEndpoint: URL(string:base + "/disconnect")!)
        try await broken.connect(token:"synthetic-token+with/slash=", zeroRetention:false)
        try await broken.send(Data(repeating:0,count:3200))
        try await Task.sleep(for:.milliseconds(100))
        check(broken.transcript.text == "Keep these words", "disconnect preserves recoverable partial text")
        do { try await broken.commit(); fatalError("disconnect must fail") } catch { checks += 1 }
        let privacy = ScribeRealtimeConnection(testEndpoint: URL(string:base + "/warning")!)
        try await privacy.connect(token:"synthetic-token+with/slash=", zeroRetention:true)
        try await privacy.send(Data(repeating:0,count:3200))
        try await Task.sleep(for:.milliseconds(100))
        do { try await privacy.commit(); fatalError("retention warning must fail") }
        catch DictationFailure.retentionUnavailable { checks += 1 }

        // Actual 48kHz stereo -> 16kHz mono, including resampler tail and a partial final packet.
        let input = DictationAudio()
        let output = AsyncThrowingStream<Data,Error>.makeStream(bufferingPolicy:.bufferingOldest(80))
        let conversion = Task.detached { await DictationAudio.convert(input.buffers, into:output.continuation, meter:{ _ in }) }
        let format = AVAudioFormat(commonFormat:.pcmFormatFloat32, sampleRate:48000, channels:2, interleaved:false)!
        for _ in 0..<3 {
            let buffer = AVAudioPCMBuffer(pcmFormat:format, frameCapacity:4096)!
            buffer.frameLength = 4096
            for channel in 0..<2 { for i in 0..<4096 { buffer.floatChannelData![channel][i] = 0.1 * sin(Float(i)*0.04) } }
            input.append(buffer)
        }
        input.finish()
        var bytes = Data(), packets = 0
        for try await packet in output.stream { bytes.append(packet); packets += 1 }
        await conversion.value
        check(abs(bytes.count / 2 - 4096) < 64, "converter preserves resampler tail and duration")
        check(packets == 3, "100ms packets plus nonempty final tail")
        check(DictationAudio.level(bytes) > 0.2, "meter uses real signal")
        check(DictationAudio.level(Data(repeating:0,count:3200)) == 0, "silence is flat")
        let overloaded = DictationAudio()
        for _ in 0..<70 {
            let buffer = AVAudioPCMBuffer(pcmFormat:format, frameCapacity:4096)!; buffer.frameLength = 4096
            overloaded.append(buffer)
        }
        do { for try await _ in overloaded.buffers {}; fatalError("overflow must not truncate silently") }
        catch DictationFailure.overloaded { checks += 1 }
        print("PASS: \(checks) real dictation transport/audio checks")
    }
}
'''

def main():
    server = http.server.ThreadingHTTPServer(('127.0.0.1',0),SocketFixture)
    threading.Thread(target=server.serve_forever,daemon=True).start()
    try:
        with tempfile.TemporaryDirectory(prefix='sentient-dictation-test-') as temporary:
            folder = Path(temporary); fixture = folder/'test.swift'; fixture.write_text(SWIFT)
            binary = folder/'test'
            subprocess.run(['xcrun','swiftc','-D','DEBUG','-swift-version','5','-default-isolation','MainActor',
                '-enable-upcoming-feature','NonisolatedNonsendingByDefault','-warnings-as-errors','-parse-as-library',
                str(APP/'ScribeRealtimeConnection.swift'),str(APP/'DictationAudio.swift'),str(fixture),'-o',str(binary)],check=True,timeout=90)
            subprocess.run([str(binary),'ws://127.0.0.1:'+str(server.server_address[1])],check=True,timeout=25)
            assert not FAILURES, FAILURES
    finally: server.shutdown(); server.server_close()

if __name__ == '__main__': main()
