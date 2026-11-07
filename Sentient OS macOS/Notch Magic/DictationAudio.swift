// Bounded microphone-buffer handoff and PCM conversion for Scribe. The audio callback only
// copies buffers; conversion, metering and chunking run on one background task.
// Doc: Documentation - Sidekick - General.md
import Foundation
@preconcurrency import AVFAudio

nonisolated final class DictationAudio: @unchecked Sendable {
    // Every yielded buffer is an owned copy, consumed once by the converter task.
    struct Buffer: @unchecked Sendable { let pcm: AVAudioPCMBuffer }
    let buffers: AsyncThrowingStream<Buffer, Error>
    private let continuation: AsyncThrowingStream<Buffer, Error>.Continuation

    init() {
        let pair = AsyncThrowingStream<Buffer, Error>.makeStream(bufferingPolicy: .bufferingOldest(64))
        buffers = pair.stream; continuation = pair.continuation
    }
    func append(_ input: AVAudioPCMBuffer) {
        guard let copy = AVAudioPCMBuffer(pcmFormat: input.format, frameCapacity: input.frameLength) else {
            finish(DictationFailure.overloaded); return
        }
        copy.frameLength = input.frameLength
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input.audioBufferList))
        let target = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for index in source.indices {
            guard let from = source[index].mData, let to = target[index].mData else {
                finish(DictationFailure.invalidResponse); return
            }
            memcpy(to, from, Int(source[index].mDataByteSize))
        }
        if case .dropped = continuation.yield(Buffer(pcm: copy)) { finish(DictationFailure.overloaded) }
    }
    func finish(_ error: Error? = nil) { continuation.finish(throwing: error) }

    /// One converter per session preserves sample-rate conversion state between hardware buffers.
    static func convert(_ buffers: AsyncThrowingStream<Buffer, Error>,
                        into output: AsyncThrowingStream<Data, Error>.Continuation,
                        failure: @escaping @Sendable (Error) async -> Void = { _ in },
                        meter: @escaping @Sendable (Float) async -> Void) async {
        do {
            let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000,
                                       channels: 1, interleaved: true)!
            var converter: AVAudioConverter?
            var inputFormat: AVAudioFormat?
            var pending = Data()
            for try await item in buffers {
                try Task.checkCancellation()
                if converter == nil {
                    converter = AVAudioConverter(from: item.pcm.format, to: format)
                    inputFormat = item.pcm.format
                }
                guard let converter, item.pcm.format == inputFormat else { throw VoiceError.deviceChanged }
                let capacity = AVAudioFrameCount(ceil(Double(item.pcm.frameLength) * 16000 / item.pcm.format.sampleRate)) + 64
                guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
                    throw DictationFailure.overloaded
                }
                var supplied = false
                var error: NSError?
                let status = converter.convert(to: converted, error: &error) { _, state in
                    if supplied { state.pointee = .noDataNow; return nil }
                    supplied = true; state.pointee = .haveData; return item.pcm
                }
                guard status != .error, error == nil else { throw DictationFailure.invalidResponse }
                if let samples = converted.int16ChannelData?[0], converted.frameLength > 0 {
                    pending.append(Data(bytes: samples, count: Int(converted.frameLength) * 2))
                }
                while pending.count >= 3200 { // 100 ms of signed little-endian mono PCM
                    let packet = Data(pending.prefix(3200)); pending.removeFirst(3200)
                    await meter(level(packet))
                    if case .dropped = output.yield(packet) { throw DictationFailure.overloaded }
                }
            }
            // Drain resampler latency as well as our partial packet, preserving the last syllable.
            if let converter, let tail = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) {
                var error: NSError?
                let result = converter.convert(to: tail, error: &error) { _, state in
                    state.pointee = .endOfStream; return nil
                }
                guard result != .error, error == nil else { throw DictationFailure.invalidResponse }
                if let samples = tail.int16ChannelData?[0], tail.frameLength > 0 {
                    pending.append(Data(bytes: samples, count: Int(tail.frameLength) * 2))
                }
            }
            if !pending.isEmpty {
                await meter(level(pending))
                if case .dropped = output.yield(pending) { throw DictationFailure.overloaded }
            }
            output.finish()
        } catch {
            output.finish(throwing: error)
            if !(error is CancellationError) { await failure(error) }
        }
    }

    static func level(_ pcm: Data) -> Float {
        guard pcm.count >= 2 else { return 0 }
        let energy: Double = pcm.withUnsafeBytes { bytes in
            var sum = 0.0
            for offset in stride(from: 0, to: bytes.count - 1, by: 2) {
                let sample = Double(Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: Int16.self))) / 32768
                sum += sample * sample
            }
            return sum / Double(bytes.count / 2)
        }
        let db = 20 * log10(max(sqrt(energy), 0.00001))
        return Float(min(1, max(0, (db + 55) / 45)))
    }
}
