import Foundation

/// Shared bounded decoder for Apple message attributed bodies.
nonisolated enum MessageBody {
    static func text(_ blob: Data) -> String? {
        let marker = blob.range(of: Data("NSString".utf8))
            ?? blob.range(of: Data("NSMutableString".utf8))
        guard let marker else { return nil }

        var i = marker.upperBound + 5                      // the 5-byte preamble after the class name
        guard i < blob.endIndex else { return nil }
        var length = Int(blob[i])
        if blob[i] == 0x81 {
            guard i + 2 < blob.endIndex else { return nil }
            length = Int(blob[i + 1]) | (Int(blob[i + 2]) << 8)   // 2-byte little-endian
            i += 3
        } else {
            i += 1
        }
        guard length > 0, i + length <= blob.endIndex else { return nil }
        return String(data: blob[i ..< (i + length)], encoding: .utf8)
    }
}
