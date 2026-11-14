import Foundation
import Network
import os

private let log = Logger(subsystem: "MobileSLAM", category: "Mid360")

/// Receives Livox Mid-360 point cloud / IMU over UDP (BSD sockets, one thread per port).
/// The iPhone's wired Ethernet (USB-C / Lightning adapter) must have the host IP configured in the Mid-360
/// (factory default 192.168.1.50). Sockets bind to INADDR_ANY, so any address / subnet works.
final class LidarReceiver: @unchecked Sendable {

    struct Counters {
        var pointPackets: Int64 = 0
        var pointCount: Int64 = 0
        var imuPackets: Int64 = 0
        var lostPackets: Int64 = 0
        var pushPackets: Int64 = 0
        var lastUdpCnt: Int = -1
        var dataType: Int = -1
        var lidarSrc: String = "-"
        var lidarInfo: String = L("未検出")
        /// LiDAR IP from the discovery ACK (empty until one arrives).
        var detectedIP: String = ""
        var lastImu: [Float]? = nil
    }

    let live: LiveHandle
    private let state = OSAllocatedUnfairLock(initialState: Counters())
    var counters: Counters { state.withLock { $0 } }

    /// Optional consumer of raw packets (e.g. the SLAM core). type: 1 = point, 2 = IMU. Called on receive threads.
    var packetSink: ((Int32, UnsafePointer<UInt8>, Int32) -> Void)? {
        get { sinkLock.withLock { sink } }
        set { sinkLock.withLock { sink = newValue } }
    }
    private var sink: ((Int32, UnsafePointer<UInt8>, Int32) -> Void)?
    private let sinkLock = NSLock()

    /// Optional raw packet recorder (format: [type u8][len u16 LE][bytes]).
    var recorder: PacketRecorder? {
        get { sinkLock.withLock { rec } }
        set { sinkLock.withLock { rec = newValue } }
    }
    private var rec: PacketRecorder?

    // ---- Ethernet status ----
    private(set) var ethAddrs: String = "-"
    private(set) var ethUp = false
    /// IPv4 address / netmask of each wired interface.
    private(set) var ethIPv4: [(ip: String, mask: String)] = []
    /// Directed broadcast addresses of the wired interfaces (for LiDAR discovery). Read by the detect thread.
    private let ethBroadcasts = OSAllocatedUnfairLock<[String]>(initialState: [])
    private(set) var socketError: String? = nil
    private let monitor = NWPathMonitor()
    private var wiredNames: Set<String> = []
    private let monitorQueue = DispatchQueue(label: "mid360.path")

    private var fds: [Int32] = []
    private var threads: [Thread] = []
    private let runLock = NSLock()
    private var running = false
    private var generation = 0
    /// True while the sockets of start() call `gen` are live (old threads exit after stop / restart).
    private func alive(_ gen: Int) -> Bool { runLock.withLock { running && generation == gen } }

    init(liveCapacity: Int32) {
        live = live_create(liveCapacity)
        monitor.pathUpdateHandler = { [weak self] path in
            let names = Set(path.availableInterfaces.filter { $0.type == .wiredEthernet }.map(\.name))
            self?.monitorQueue.async { self?.wiredNames = names }
        }
        monitor.start(queue: monitorQueue)
    }

    deinit {
        monitor.cancel()
        stopDemo()
        stop()
        live_destroy(live)
    }

    // ------------------------------------------------------------------ lifecycle

    func start() {
        runLock.lock()
        defer { runLock.unlock() }
        guard !running else { return }
        running = true
        generation += 1
        let gen = generation
        socketError = nil
        do {
            let point = try openSocket(port: Livox.hostPointPort)
            let imu = try openSocket(port: Livox.hostImuPort)
            let push = try openSocket(port: Livox.hostPushPort)
            let detect = try openSocket(port: Livox.hostDetectPort, broadcast: true)
            threads.append(loop("point", point, gen) { [weak self] p, from in self?.onPoint(p, from: from) })
            threads.append(loop("imu", imu, gen) { [weak self] p, _ in self?.onImu(p) })
            threads.append(loop("push", push, gen) { [weak self] _, _ in self?.state.withLock { $0.pushPackets += 1 } })
            threads.append(loop("detect", detect, gen) { [weak self] p, _ in self?.onDetect(p) })
            let tx = Thread { [weak self] in self?.detectLoop(detect, gen) }
            tx.name = "mid360-detect-tx"
            tx.start()
            threads.append(tx)
            log.info("sockets open")
        } catch {
            socketError = "\(error)"
            log.error("socket open failed: \(error)")
        }
    }

    func stop() {
        runLock.lock()
        running = false
        let toClose = fds
        fds.removeAll()
        threads.removeAll()
        runLock.unlock()
        // threads notice `running == false` within the receive timeout; closing afterwards is safe
        // because each thread exits its loop on any error.
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) { toClose.forEach { close($0) } }
    }

    // ------------------------------------------------------------------ demo

    private var demo: DemoHandle?
    /// True while synthetic Mid-360 packets are being fed in (call from the main thread).
    var demoRunning: Bool { demo != nil }

    /// Feeds synthetic packets of a simulated room through the same path as real UDP packets.
    func startDemo() {
        guard demo == nil else { return }
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        demo = demo_start({ ctx, type, buf, len in
            guard let ctx, let buf else { return }
            Unmanaged<LidarReceiver>.fromOpaque(ctx).takeUnretainedValue().inject(type, buf, len)
        }, ctx)
        state.withLock {
            $0.lidarInfo = L("デモ（疑似 Mid-360）")
            $0.lastUdpCnt = -1
        }
    }

    func stopDemo() {
        guard let d = demo else { return }
        demo_stop(d)   // joins the thread: no callbacks after this
        demo = nil
        state.withLock {
            $0.lidarInfo = L("未検出")
            $0.lidarSrc = "-"
            $0.lastUdpCnt = -1
        }
    }

    /// The simulated sensor stands still for 3 s (IMU initialisation), then moves again.
    func restartDemoMotion() {
        if let d = demo { demo_restart_motion(d) }
    }

    private func inject(_ type: Int32, _ buf: UnsafePointer<UInt8>, _ len: Int32) {
        let p = UnsafeRawBufferPointer(start: buf, count: Int(len))
        if type == 1 {
            var from = sockaddr_in()
            from.sin_addr.s_addr = UInt32(0x7F000001).bigEndian
            onPoint(p, from: from)
        } else {
            onImu(p)
        }
    }

    // ------------------------------------------------------------------ Ethernet status

    /// Updates [ethUp] / [ethAddrs] from the current interfaces (call periodically).
    func refreshInterfaces() {
        let wired = monitorQueue.sync { wiredNames }
        var list: [(String, String)] = []
        var bcasts: [String] = []
        var v4: [(ip: String, mask: String)] = []
        var ifap: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifap) == 0, let first = ifap {
            var p: UnsafeMutablePointer<ifaddrs>? = first
            while let ifa = p {
                defer { p = ifa.pointee.ifa_next }
                guard let sa = ifa.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
                let name = String(cString: ifa.pointee.ifa_name)
                let addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                let ip = String(cString: inet_ntoa(addr))
                var mask: in_addr_t = 0
                if let nm = ifa.pointee.ifa_netmask {
                    mask = nm.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
                }
                // wired adapters reported by Network.framework, or any secondary en* (en0 is Wi-Fi)
                if wired.contains(name) || (name.hasPrefix("en") && name != "en0") {
                    list.append((name, "\(ip)/\(mask.nonzeroBitCount)"))
                    v4.append((ip, String(cString: inet_ntoa(in_addr(s_addr: mask)))))
                    if mask != 0 && mask != 0xFFFF_FFFF {
                        let b = in_addr(s_addr: addr.s_addr | ~mask)
                        bcasts.append(String(cString: inet_ntoa(b)))
                    }
                }
            }
            freeifaddrs(first)
        }
        ethUp = !list.isEmpty
        ethIPv4 = v4
        ethBroadcasts.withLock { [bcasts] in $0 = bcasts }
        ethAddrs = list.isEmpty ? "-" : list.map { "\($0.0): \($0.1)" }.joined(separator: ", ")
    }

    // ------------------------------------------------------------------ sockets

    struct SocketError: Error, CustomStringConvertible {
        let description: String
    }

    private func openSocket(port: UInt16, broadcast: Bool = false) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw SocketError(description: "socket(): \(String(cString: strerror(errno)))") }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, socklen_t(MemoryLayout<Int32>.size))
        if broadcast { setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &one, socklen_t(MemoryLayout<Int32>.size)) }
        var rcv: Int32 = 4 * 1024 * 1024
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcv, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 0, tv_usec: 300_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard r == 0 else {
            let msg = String(cString: strerror(errno))
            close(fd)
            throw SocketError(description: "bind(\(port)): \(msg)")
        }
        fds.append(fd)
        return fd
    }

    private func loop(_ name: String, _ fd: Int32, _ gen: Int,
                      handler: @escaping (UnsafeRawBufferPointer, sockaddr_in) -> Void) -> Thread {
        let t = Thread { [weak self] in
            let buf = UnsafeMutableRawPointer.allocate(byteCount: 2048, alignment: 8)
            defer { buf.deallocate() }
            var from = sockaddr_in()
            while self?.alive(gen) == true {
                var flen = socklen_t(MemoryLayout<sockaddr_in>.size)
                let n = withUnsafeMutablePointer(to: &from) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, buf, 2048, 0, $0, &flen) }
                }
                if n > 0 {
                    handler(UnsafeRawBufferPointer(start: buf, count: n), from)
                } else if n < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
                    break   // socket closed
                }
            }
        }
        t.name = "mid360-\(name)"
        t.qualityOfService = .userInteractive
        t.start()
        return t
    }

    private func send(_ fd: Int32, _ bytes: [UInt8], to ip: String, port: UInt16) -> Bool {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, ip, &addr.sin_addr) == 1 else { return false }
        let r = bytes.withUnsafeBytes { b in
            withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, b.baseAddress, b.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        return r >= 0
    }

    /// Periodically sends a discovery request so we can show the LiDAR's SN / IP.
    /// Broadcast needs the multicast entitlement on iOS; once points arrive we also ask the sender directly.
    private func detectLoop(_ fd: Int32, _ gen: Int) {
        var seq: UInt32 = 0
        while alive(gen) {
            let req = Livox.buildDetectRequest(seq: seq)
            seq &+= 1
            var targets = ["255.255.255.255"] + ethBroadcasts.withLock { $0 }
            let src = counters.lidarSrc
            if src != "-" { targets.append(src) }
            for t in targets { _ = send(fd, req, to: t, port: Livox.lidarDetectPort) }
            for _ in 0..<30 where alive(gen) { Thread.sleep(forTimeInterval: 0.1) }
        }
    }

    // ------------------------------------------------------------------ handlers

    private func forward(_ type: Int32, _ p: UnsafeRawBufferPointer) {
        guard let base = p.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
        let (s, r) = sinkLock.withLock { (sink, rec) }
        s?(type, base, Int32(p.count))
        r?.write(type: UInt8(type), p)
    }

    private func onDetect(_ p: UnsafeRawBufferPointer) {
        guard let ack = Livox.parseDetectAck(p) else { return }
        let info = "\(Livox.devTypeName(ack.devType)) SN=\(ack.sn) IP=\(ack.ip)"
        state.withLock {
            $0.lidarInfo = info
            $0.detectedIP = ack.ip
        }
    }

    private func onPoint(_ p: UnsafeRawBufferPointer, from: sockaddr_in) {
        guard p.count >= Livox.headerSize else { return }
        forward(1, p)
        let udpCnt = Int(p[7]) | Int(p[8]) << 8
        let type = Int(p[10])
        let n = live_add_packet(live, p.baseAddress!.assumingMemoryBound(to: UInt8.self), Int32(p.count))
        let needSrc = state.withLock { $0.lidarSrc == "-" }
        let src = needSrc ? String(cString: inet_ntoa(from.sin_addr)) : nil
        state.withLock { c in
            if c.lastUdpCnt >= 0 {
                let gap = (udpCnt - c.lastUdpCnt - 1) & 0xFFFF
                if gap >= 1 && gap <= 1000 { c.lostPackets += Int64(gap) }
            }
            c.lastUdpCnt = udpCnt
            c.pointPackets += 1
            c.pointCount += Int64(n)
            c.dataType = type
            if let src { c.lidarSrc = src }
        }
    }

    private func onImu(_ p: UnsafeRawBufferPointer) {
        guard p.count >= Livox.headerSize + 24 else { return }
        forward(2, p)
        var v = [Float](repeating: 0, count: 6)
        let ok = livox_parse_imu(p.baseAddress!.assumingMemoryBound(to: UInt8.self), Int32(p.count), &v)
        let imu = ok != 0 ? v : nil
        state.withLock { c in
            c.imuPackets += 1
            if let imu { c.lastImu = imu }
        }
    }
}

/// Buffered writer for raw packets. Thread safe.
final class PacketRecorder: @unchecked Sendable {
    let url: URL
    private let handle: FileHandle
    private var buf = Data()
    private let lock = NSLock()
    private(set) var bytes: Int64 = 0

    init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        self.url = url
        buf.reserveCapacity(1 << 20)
    }

    func write(type: UInt8, _ p: UnsafeRawBufferPointer) {
        lock.lock()
        defer { lock.unlock() }
        let len = p.count
        buf.append(contentsOf: [type, UInt8(len & 0xFF), UInt8((len >> 8) & 0xFF)])
        buf.append(contentsOf: p)
        bytes += Int64(len + 3)
        if buf.count >= 1 << 20 { flushLocked() }
    }

    private func flushLocked() {
        try? handle.write(contentsOf: buf)
        buf.removeAll(keepingCapacity: true)
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        flushLocked()
        try? handle.close()
    }
}
