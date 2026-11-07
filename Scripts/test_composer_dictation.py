#!/usr/bin/env python3
"""Exercise production composer dictation without audio, accounts, or global input."""
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[1]
fixture = r'''
import Foundation
@MainActor final class VoiceCapture {
 var onLevel: ((Float)->Void)?
 var onTranscript: ((String)->Void)?, onFailure: ((Error)->Void)?
 var stops=0, cancels=0, delayed=false
 var startWait: CheckedContinuation<Void,Never>?
 var finishWait: CheckedContinuation<String,Error>?
 func start() async throws { if delayed { await withCheckedContinuation {startWait=$0} }; try Task.checkCancellation() }
 func stopCapturing(){stops+=1}
 func stopAndTranscribe() async throws -> String {try await withCheckedThrowingContinuation {finishWait=$0}}
 func cancel(){cancels+=1;finishWait?.resume(throwing:CancellationError());finishWait=nil}
 func finish(_ text:String){finishWait?.resume(returning:text);finishWait=nil}
}
@main struct Test {
 @MainActor static func main() async {
  var checks=0, text="", sends=0
  func check(_ v:Bool,_ name:String){precondition(v,name);checks+=1}
  func settle() async {try? await Task.sleep(for:.milliseconds(25))}
  let mic=VoiceCapture(), voice=ComposerDictation(capture:nil)
  voice.cancel()
  let c=ComposerDictation(capture:mic)
  c.start(draft:"Please") {text=$0};await settle()
  check(c.stage == .recording && !c.hasTranscript,"capture starts with waveform before words")
  mic.onLevel?(0.6);check(c.levels.last == 0.6,"meter feeds the waiting waveform")
  mic.onTranscript?("draft this");check(text == "Please draft this" && c.hasTranscript,"first words replace waveform and append to draft")
  mic.onTranscript?("draft this email");check(text == "Please draft this email","revised transcript replaces previous interim text")
  c.stop();check(mic.stops==1 && c.stage == .finalizing,"stop closes microphone synchronously")
  await settle();mic.finish("draft this email.");await settle()
  check(text == "Please draft this email." && !c.isActive && sends==0,"stop finalizes into draft without sending")
  c.start(draft:"") {text=$0};await settle();mic.onTranscript?("Send this")
  c.stop(sendWhenReady:{sends+=1});await settle()
  c.stop(sendWhenReady:{sends+=1});mic.finish("Send this now.");await settle()
  check(sends==1 && text == "Send this now.","send during dictation includes final words and submits once")
  c.start(draft:"") {text=$0};await settle();let late=mic.onTranscript
  mic.onTranscript?("Keep these words");c.stop(sendWhenReady:{sends+=1});await settle();c.cancel();late?("wrong");await settle()
  check(text == "Keep these words" && sends==1,"cancel rejects late text and pending sends")
  let slow=VoiceCapture();slow.delayed=true;let s=ComposerDictation(capture:slow)
  s.start(draft:"") {_ in};await settle();s.stop();slow.startWait?.resume();slow.startWait=nil;await settle()
  check(!s.isActive,"stop during permission/start cannot reopen microphone")
  c.start(draft:"") {text=$0};await settle();mic.onTranscript?("Recover me")
  mic.onFailure?(CancellationError());await settle()
  check(!c.isActive && c.error != nil && text == "Recover me","failure preserves draft and surfaces error")
  print("PASS: \(checks) composer dictation lifecycle checks")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='sentient-composer-voice-') as d:
 p=Path(d);(p/'test.swift').write_text(fixture)
 subprocess.run(['xcrun','swiftc','-swift-version','5','-default-isolation','MainActor','-parse-as-library',str(root/'Sentient OS macOS/Notch Magic/ComposerDictation.swift'),str(p/'test.swift'),'-o',str(p/'test')],check=True,timeout=60)
 subprocess.run([str(p/'test')],check=True,timeout=15)
