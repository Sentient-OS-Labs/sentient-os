import Foundation

/// One genuine device callback. Not a poll of the last cached lux value.
struct ALSFrame: Sendable {
    let sequence: UInt64
    let time: Double
    let arrivalTime: Double
    let deviceTicks: UInt64
    let timestampSource: String
    let lux: Double?
    let channels: [UInt32]
    let rawHex: String

    static func decode(_ packet: [UInt8], sequence: UInt64, time: Double,
                       arrival: Double, ticks: UInt64, timestampSource: String) -> Self? {
        guard packet.count == 122 else { return nil }
        func word(_ i: Int) -> UInt32 {
            UInt32(packet[i]) | UInt32(packet[i+1]) << 8 | UInt32(packet[i+2]) << 16 | UInt32(packet[i+3]) << 24
        }
        let light = Double(Float(bitPattern: word(40)))
        return Self(sequence: sequence, time: time, arrivalTime: arrival, deviceTicks: ticks,
            timestampSource: timestampSource, lux: light.isFinite && light >= 0 ? light : nil,
            channels: [20,24,28,32].map(word),
            rawHex: packet.map { String(format: "%02X", $0) }.joined(separator: " "))
    }
}
