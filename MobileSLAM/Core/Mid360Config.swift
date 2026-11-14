import Foundation

/// Network settings of a Mid-360 (IP of the LiDAR and the destination of its data), read and written over the
/// Livox SDK2 control protocol ("Livox LiDAR Communication Protocol -- Mid360"):
///
/// - 0x0101 parameter inquire / 0x0100 parameter configuration, keys
///   0x0004 lidar_ipcfg (ip[4] mask[4] gateway[4]),
///   0x0005 / 0x0006 / 0x0007 state info / point cloud / IMU destination (ip[4] dst_port u16 src_port u16)
/// - 0x0200 reboot (needed for a new LiDAR IP; the destination settings apply immediately)
///
/// Control commands are unicast UDP to <lidar ip>:56100, so the iPhone must be on the LiDAR's current subnet.
enum Mid360Config {
    struct Network: Equatable {
        var lidarIP: String
        var mask: String
        var gateway: String
        var hostIP: String      // destination of point cloud / IMU / state info
    }

    enum Failure: Error, LocalizedError {
        case badAddress(String)
        case socket(String)
        case noResponse
        case rejected(UInt8, UInt16)
        case malformed

        var errorDescription: String? {
            switch self {
            case .badAddress(let s): return String(format: L("IP アドレスの形式が正しくありません: %@"), s)
            case .socket(let s): return String(format: L("通信エラー: %@"), s)
            case .noResponse:
                return String(format: L("Mid-360 から応答がありません。Mid-360 の IP が正しいか、%@ の IP が Mid-360 と同じサブネットにあるかを確認してください。"), Device.name)
            case .rejected(let code, let key):
                return String(format: L("Mid-360 が設定を受け付けませんでした（ret_code 0x%02X, key 0x%04X）"), code, key)
            case .malformed: return L("Mid-360 からの応答を解釈できませんでした。")
            }
        }
    }

    static let lidarCmdPort: UInt16 = 56100
    static let hostCmdPort: UInt16 = 56101
    // LiDAR-side source ports (spec defaults), sent together with the destination ports
    static let lidarPushPort: UInt16 = 56200
    static let lidarPointPort: UInt16 = 56300
    static let lidarImuPort: UInt16 = 56400

    static let cmdSetParams: UInt16 = 0x0100
    static let cmdGetParams: UInt16 = 0x0101
    static let cmdReboot: UInt16 = 0x0200

    static let keyLidarIP: UInt16 = 0x0004
    static let keyStateHost: UInt16 = 0x0005
    static let keyPointHost: UInt16 = 0x0006
    static let keyImuHost: UInt16 = 0x0007

    // ------------------------------------------------------------------ operations (blocking; call off the main thread)

    /// Reads the current network settings (0x0101).
    static func read(lidarIP: String) throws -> Network {
        var d = Data()
        let keys = [keyLidarIP, keyPointHost]
        d.appendLE(UInt16(keys.count))
        d.appendLE(UInt16(0))
        for k in keys { d.appendLE(k) }
        let ack = try request(lidarIP: lidarIP, cmd: cmdGetParams, data: d)
        guard ack.count >= 3 else { throw Failure.malformed }
        if ack[0] != 0 { throw Failure.rejected(ack[0], 0) }
        let n = Int(ack.u16(1))
        var off = 3
        var net = Network(lidarIP: lidarIP, mask: "", gateway: "", hostIP: "")
        for _ in 0..<n {
            guard off + 4 <= ack.count else { throw Failure.malformed }
            let key = ack.u16(off), len = Int(ack.u16(off + 2))
            off += 4
            guard off + len <= ack.count else { throw Failure.malformed }
            let v = ack.subdata(in: off..<(off + len))
            off += len
            if key == keyLidarIP, len >= 12 {
                net.lidarIP = ipString(v, 0)
                net.mask = ipString(v, 4)
                net.gateway = ipString(v, 8)
            } else if key == keyPointHost, len >= 4 {
                net.hostIP = ipString(v, 0)
            }
        }
        guard !net.mask.isEmpty else { throw Failure.malformed }
        return net
    }

    /// Writes the destination IP (applied immediately) and, if it differs, the LiDAR IP followed by a reboot.
    /// Returns true when the LiDAR was rebooted.
    @discardableResult
    static func write(currentLidarIP: String, to net: Network, changeLidarIP: Bool) throws -> Bool {
        let host = try ipBytes(net.hostIP)
        var kvs: [(UInt16, Data)] = []
        if changeLidarIP {
            kvs.append((keyLidarIP, try ipBytes(net.lidarIP) + ipBytes(net.mask) + ipBytes(net.gateway)))
        }
        for (key, dst, src) in [(keyStateHost, Livox.hostPushPort, lidarPushPort),
                                (keyPointHost, Livox.hostPointPort, lidarPointPort),
                                (keyImuHost, Livox.hostImuPort, lidarImuPort)] {
            var v = host
            v.appendLE(dst)
            v.appendLE(src)
            kvs.append((key, v))
        }
        var d = Data()
        d.appendLE(UInt16(kvs.count))
        d.appendLE(UInt16(0))
        for (k, v) in kvs {
            d.appendLE(k)
            d.appendLE(UInt16(v.count))
            d.append(v)
        }
        let ack = try request(lidarIP: currentLidarIP, cmd: cmdSetParams, data: d)
        guard ack.count >= 1 else { throw Failure.malformed }
        let code = ack[0]
        let errKey = ack.count >= 3 ? ack.u16(1) : 0
        let needsReboot = code == 0x21   // LVX_RET_PARAM_REBOOT_EFFECT
        guard code == 0 || needsReboot else { throw Failure.rejected(code, errKey) }
        guard changeLidarIP || needsReboot else { return false }
        var r = Data()
        r.appendLE(UInt16(100))   // reboot after 100 ms (same as the SDK)
        let rack = try request(lidarIP: currentLidarIP, cmd: cmdReboot, data: r)
        guard rack.count >= 1 else { throw Failure.malformed }
        if rack[0] != 0 { throw Failure.rejected(rack[0], 0) }
        return true
    }

    // ------------------------------------------------------------------ framing

    /// Builds a control frame: sof, version, length, seq, cmd_id, cmd_type (REQ), sender_type (host), resv[6],
    /// crc16 over the first 18 bytes, crc32 over the data (0 when there is none), data. All fields little endian.
    static func frame(cmd: UInt16, seq: UInt32, data: Data) -> Data {
        var b = Data()
        b.append(0xAA)
        b.append(0)
        b.appendLE(UInt16(24 + data.count))
        b.appendLE(seq)
        b.appendLE(cmd)
        b.append(0)   // REQ
        b.append(0)   // host
        b.append(Data(count: 6))
        b.appendLE(Livox.crc16Ccitt([UInt8](b), 0, 18))
        b.appendLE(data.isEmpty ? 0 : crc32(data))
        b.append(data)
        return b
    }

    /// CRC-32 (poly 0x04C11DB7 reflected, init / xorout 0xFFFFFFFF).
    static func crc32(_ d: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for byte in d {
            c ^= UInt32(byte)
            for _ in 0..<8 { c = (c & 1) != 0 ? (c >> 1) ^ 0xEDB8_8320 : c >> 1 }
        }
        return ~c
    }

    /// Parses an ACK frame for (cmd, seq); returns its data, or nil if it is something else.
    static func parseAck(_ p: Data, cmd: UInt16, seq: UInt32) -> Data? {
        guard p.count >= 24, p[p.startIndex] == 0xAA else { return nil }
        let b = Data(p)
        let len = Int(b.u16(2))
        guard len >= 24, len <= b.count else { return nil }
        guard Livox.crc16Ccitt([UInt8](b), 0, 18) == b.u16(18) else { return nil }
        guard b.u32(4) == seq, b.u16(8) == cmd, b[10] == 1 else { return nil }
        let data = b.subdata(in: 24..<len)
        if !data.isEmpty && crc32(data) != b.u32(20) { return nil }
        return data
    }

    /// Typed address in ASCII: full-width digits / dots from a Japanese keyboard (iPad has no decimal pad) are converted.
    static func normalize(_ s: String) -> String {
        let half = s.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? s
        return half.replacingOccurrences(of: "。", with: ".").replacingOccurrences(of: "｡", with: ".")
            .trimmingCharacters(in: .whitespaces)
    }

    static func ipBytes(_ s: String) throws -> Data {
        var a = in_addr()
        guard inet_pton(AF_INET, normalize(s), &a) == 1 else { throw Failure.badAddress(s) }
        return withUnsafeBytes(of: a.s_addr) { Data($0) }   // network order = a.b.c.d
    }

    static func ipString(_ d: Data, _ off: Int) -> String {
        let s = d.startIndex + off
        return (0..<4).map { String(d[s + $0]) }.joined(separator: ".")
    }

    /// True when both addresses are valid and in the same subnet under mask.
    static func sameSubnet(_ a: String, _ b: String, mask: String) -> Bool {
        guard let x = try? ipBytes(a), let y = try? ipBytes(b), let m = try? ipBytes(mask) else { return false }
        return (0..<4).allSatisfy { x[$0] & m[$0] == y[$0] & m[$0] }
    }

    // ------------------------------------------------------------------ transport

    private static var seqCounter: UInt32 = UInt32.random(in: 1...0xFFFF)
    private static let seqLock = NSLock()

    /// Sends a command and waits for its ACK (3 tries, 1 s each).
    private static func request(lidarIP: String, cmd: UInt16, data: Data) throws -> Data {
        var dst = sockaddr_in()
        dst.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        dst.sin_family = sa_family_t(AF_INET)
        dst.sin_port = lidarCmdPort.bigEndian
        guard inet_pton(AF_INET, normalize(lidarIP), &dst.sin_addr) == 1 else {
            throw Failure.badAddress(lidarIP)
        }
        let seq = seqLock.withLock {
            seqCounter &+= 1
            return seqCounter
        }
        let pkt = frame(cmd: cmd, seq: seq, data: data)

        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw Failure.socket(String(cString: strerror(errno))) }
        defer { close(fd) }
        var tv = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        // recommended host command port; any port works (the LiDAR replies to the sender)
        var me = sockaddr_in()
        me.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        me.sin_family = sa_family_t(AF_INET)
        me.sin_port = hostCmdPort.bigEndian
        me.sin_addr.s_addr = INADDR_ANY
        let bound = withUnsafePointer(to: &me) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if bound != 0 {
            me.sin_port = 0
            _ = withUnsafePointer(to: &me) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
        }

        var buf = [UInt8](repeating: 0, count: 1500)
        for _ in 0..<3 {
            let sent = pkt.withUnsafeBytes { b in
                withUnsafePointer(to: &dst) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, b.baseAddress, b.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            if sent < 0 {
                let e = errno
                if e == EHOSTUNREACH || e == ENETUNREACH { throw Failure.noResponse }
                throw Failure.socket(String(cString: strerror(e)))
            }
            let deadline = Date().addingTimeInterval(1)
            while Date() < deadline {
                let n = recv(fd, &buf, buf.count, 0)
                if n <= 0 { break }
                if let ack = parseAck(Data(buf[0..<n]), cmd: cmd, seq: seq) { return ack }
            }
        }
        throw Failure.noResponse
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ v: T) {
        Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) }
    }
    func u16(_ i: Int) -> UInt16 {
        let s = startIndex + i
        return UInt16(self[s]) | UInt16(self[s + 1]) << 8
    }
    func u32(_ i: Int) -> UInt32 {
        let s = startIndex + i
        return (0..<4).reduce(UInt32(0)) { $0 | UInt32(self[s + $1]) << (8 * UInt32($1)) }
    }
}
