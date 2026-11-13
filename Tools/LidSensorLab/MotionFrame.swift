import Foundation

struct MotionFrame: Sendable {
    enum Kind: String, Sendable { case accel, gyro }
    let kind: Kind
    let sequence: UInt64
    let time: Double
    let arrivalTime: Double
    let deviceTicks: UInt64
    let timestampSource: String
    let vector: SIMD3<Double>
    let rawHex: String
    static func decode(_ packet: [UInt8], kind: Kind, sequence: UInt64, time: Double,
                       arrival: Double, ticks: UInt64, timestampSource: String) -> Self? {
        guard packet.count == 22 else { return nil }
        func q16(_ i: Int) -> Double {
            let bits = UInt32(packet[i]) | UInt32(packet[i+1]) << 8 | UInt32(packet[i+2]) << 16 | UInt32(packet[i+3]) << 24
            return Double(Int32(bitPattern: bits)) / 65_536
        }
        return Self(kind: kind, sequence: sequence, time: time, arrivalTime: arrival,
            deviceTicks: ticks, timestampSource: timestampSource, vector: SIMD3(q16(6),q16(10),q16(14)),
            rawHex: packet.map { hexTable[Int($0)] }.joined(separator: " "))
    }
    private static let hexTable = (0...255).map { String(format: "%02X", $0) }
}
