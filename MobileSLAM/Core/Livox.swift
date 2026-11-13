import Foundation

/// Livox SDK2 (Mid-360) wire protocol, minimal subset.
///
/// Control frame header (24 bytes):
///   0 sof(0xAA) 1 version 2 length(u16) 4 seq(u32) 8 cmd_id(u16)
///  10 cmd_type 11 sender_type 12 resv[6] 18 crc16(header[0..18)) 20 crc32(data)
enum Livox {
    static let lidarDetectPort: UInt16 = 56000
    static let hostDetectPort: UInt16 = 56001
    static let hostPushPort: UInt16 = 56201
    static let hostPointPort: UInt16 = 56301
    static let hostImuPort: UInt16 = 56401

    /// Factory default destination IP of Mid-360.
    static let defaultHostIP = "192.168.1.50"

    static let headerSize = 36
    private static let ctrlHeader = 24

    static func crc16Ccitt(_ buf: [UInt8], _ off: Int, _ len: Int) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for i in off..<(off + len) {
            crc ^= UInt16(buf[i]) << 8
            for _ in 0..<8 { crc = (crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : crc << 1 }
        }
        return crc
    }

    /// Discovery request (cmd_id 0x0000).
    static func buildDetectRequest(seq: UInt32) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: ctrlHeader)
        b[0] = 0xAA
        b[2] = UInt8(ctrlHeader & 0xFF)
        b[3] = UInt8(ctrlHeader >> 8)
        for i in 0..<4 { b[4 + i] = UInt8((seq >> (8 * UInt32(i))) & 0xFF) }
        // cmd_id 0, cmd_type 0 (REQ), sender_type 0 (host), reserved 0
        let crc = crc16Ccitt(b, 0, 18)
        b[18] = UInt8(crc & 0xFF)
        b[19] = UInt8(crc >> 8)
        return b   // crc32 of empty data = 0
    }

    struct DetectAck {
        let devType: Int
        let sn: String
        let ip: String
        let cmdPort: Int
    }

    static func parseDetectAck(_ p: UnsafeRawBufferPointer) -> DetectAck? {
        guard p.count >= ctrlHeader + 24, p[0] == 0xAA else { return nil }
        let cmdId = Int(p[8]) | Int(p[9]) << 8
        guard cmdId == 0, p[10] == 1 else { return nil }
        let d = ctrlHeader
        let devType = Int(p[d + 1])
        let snBytes = Array(p[(d + 2)..<(d + 18)]).prefix { $0 != 0 }
        let sn = String(decoding: snBytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        let ip = (0..<4).map { String(p[d + 18 + $0]) }.joined(separator: ".")
        let port = Int(p[d + 22]) | Int(p[d + 23]) << 8
        return DetectAck(devType: devType, sn: sn, ip: ip, cmdPort: port)
    }

    static func devTypeName(_ t: Int) -> String {
        switch t {
        case 9, 35: return "Mid-360"
        case 10: return "HAP"
        default: return "type=\(t)"
        }
    }
}
