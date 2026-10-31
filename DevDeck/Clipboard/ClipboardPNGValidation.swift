import Foundation
import zlib

/// ImageIO can recover corrupt PNG streams as a placeholder image. Validate the
/// chunk checksums and compressed stream too, without retaining decompressed pixels.
enum ClipboardPNGValidation {
    static func valid(_ data: Data, width: Int, height: Int) -> Bool {
        guard data.count >= 8 else { return false }
        var compressed = Data()
        var offset = 8
        var ended = false
        while offset + 12 <= data.count {
            let length = data[offset..<offset + 4].reduce(0) { ($0 << 8) | Int($1) }
            guard length <= data.count - offset - 12 else { return false }
            let type = String(data: data.subdata(in: offset + 4..<offset + 8), encoding: .ascii)
            let expected = data[offset + 8 + length..<offset + 12 + length].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            let actual = data.withUnsafeBytes { bytes in
                crc32(0, bytes.bindMemory(to: UInt8.self).baseAddress! + offset + 4, uInt(length + 4))
            }
            guard UInt32(actual) == expected else { return false }
            if type == "IDAT" { compressed.append(data.subdata(in: offset + 8..<offset + 8 + length)) }
            offset += length + 12
            if type == "IEND" { ended = true; break }
        }
        guard ended, !compressed.isEmpty else { return false }
        var stream = z_stream()
        guard inflateInit_(&stream, zlibVersion(), Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return false }
        defer { inflateEnd(&stream) }
        let limit = width * height * 8 + height * 7 // maximum 16-bit RGBA + interlace row filters
        var output = [UInt8](repeating: 0, count: 65_536)
        return compressed.withUnsafeBytes { bytes in
            stream.next_in = UnsafeMutablePointer(mutating: bytes.bindMemory(to: UInt8.self).baseAddress!)
            stream.avail_in = uInt(bytes.count)
            var status = Z_OK
            while status == Z_OK {
                status = output.withUnsafeMutableBytes { buffer in
                    stream.next_out = buffer.bindMemory(to: UInt8.self).baseAddress!
                    stream.avail_out = uInt(buffer.count)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                guard stream.total_out <= limit else { return false }
            }
            return status == Z_STREAM_END && stream.avail_in == 0 && stream.total_out > 0
        }
    }
}
