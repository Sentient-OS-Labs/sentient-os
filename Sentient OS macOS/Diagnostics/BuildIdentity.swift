// The linker UUID identifies the exact executable without adding user/device identifiers.
// Unlike marketing version/build numbers, this changes when the compiled code changes.
import Foundation
import MachO

nonisolated enum BuildIdentity {
    static let identifier: String = {
        var index: UInt32 = 0
        #if DEBUG
        if let path = Bundle.main.executableURL?.resolvingSymlinksInPath().path {
            for candidate in 0..<_dyld_image_count() {
                if let name = _dyld_get_image_name(candidate),
                   URL(fileURLWithPath: String(cString: name)).resolvingSymlinksInPath().path == path + ".debug.dylib" {
                    index = candidate; break
                }
            }
        }
        #endif
        guard let header = _dyld_get_image_header(index), header.pointee.magic == MH_MAGIC_64,
              header.pointee.ncmds < 4096, header.pointee.sizeofcmds < 16_777_216 else { return "unknown" }
        var remaining = Int(header.pointee.sizeofcmds)
        var cursor = UnsafeRawPointer(header).advanced(by: MemoryLayout<mach_header_64>.size)
        for _ in 0..<header.pointee.ncmds {
            guard remaining >= MemoryLayout<load_command>.size else { break }
            let command = cursor.load(as: load_command.self)
            let length = Int(command.cmdsize)
            guard length >= MemoryLayout<load_command>.size, length <= remaining, length % 4 == 0 else { break }
            if command.cmd == LC_UUID, length >= MemoryLayout<uuid_command>.size {
                return UUID(uuid: cursor.load(as: uuid_command.self).uuid).uuidString.lowercased()
            }
            cursor = cursor.advanced(by: length); remaining -= length
        }
        return "unknown"
    }()
}
