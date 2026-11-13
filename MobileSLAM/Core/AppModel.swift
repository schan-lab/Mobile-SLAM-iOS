import Foundation
import Network
import SwiftUI
import UIKit
import os

private let log = Logger(subsystem: "MobileSLAM", category: "App")

/// App state and actions of the main screen.
@MainActor
final class AppModel: ObservableObject {

    let engine = SlamEngine()
    let receiver = LidarReceiver(liveCapacity: 40_000)   // ~0.2 s of Mid-360 output
    lazy var mapView: LiveMapView = {
        let v = LiveMapView(engine: engine, live: receiver.live)
        v.onPosePicked = { [weak self] x, y, yaw in self?.onPosePicked(x: x, y: y, yaw: yaw) }
        return v
    }()

    struct Chip {
        var ok: Bool
        var label: String
    }

    @Published var mode: SlamEngine.Mode = .mapping
    @Published var mapName: String?
    @Published var loadingMap = false
    @Published var pickMode = false
    @Published var showDetails = false
    @Published var showMapPicker = false
    @Published var confirmSwitchToLoc = false
    @Published var toast: String?

    @Published private(set) var st = SlamStatus()
    @Published private(set) var chipEth = Chip(ok: false, label: "Ethernet 未接続")
    @Published private(set) var chipLidar = Chip(ok: false, label: "LiDAR 受信なし")
    @Published private(set) var chipImu = Chip(ok: false, label: "IMU 0Hz")
    @Published private(set) var headline = "待機中"
    @Published private(set) var details = ""
    @Published private(set) var recordLabel: String?

    private var timer: Timer?
    private var prevT = CACurrentMediaTime()
    private var prev = LidarReceiver.Counters()
    private var mapStart = Date()
    private var toastTask: Task<Void, Never>?
    private let localNetwork = LocalNetworkPermission()

    init() {
        let engine = self.engine
        receiver.packetSink = { type, buf, len in engine.push(type, buf, len) }
        engine.setBlind(AppSettings.blind)
    }

    var running: Bool { st.isRunning }

    // ------------------------------------------------------------------ lifecycle

    /// Pushes the saved settings to the SLAM core and the view (called whenever we come to the front).
    func applySettings() {
        engine.setBlind(AppSettings.blind)
        mapView.colorMode = AppSettings.colorMode
    }

    func activate() {
        applySettings()
        localNetwork.request()
        receiver.start()
        UIApplication.shared.isIdleTimerDisabled = true
        mapView.isPaused = false
        prevT = CACurrentMediaTime()
        prev = receiver.counters
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateStatus() }
        }
        updateStatus()
        #if DEBUG
        // test hook: `simctl launch ... -autoStartMapping` (used with tools/mid360_sim.cpp)
        if ProcessInfo.processInfo.arguments.contains("-autoStartMapping") && !st.isRunning && st.scans == 0 {
            toggleMapping()
        }
        #endif
    }

    func deactivate() {
        timer?.invalidate()
        timer = nil
        if receiver.recorder != nil { toggleRecord() }
        if engine.status.isRunning { engine.stop() }   // map is kept; only start() resets
        mapView.isPaused = true
        receiver.stop()
        UIApplication.shared.isIdleTimerDisabled = false
        st = engine.status
    }

    // ------------------------------------------------------------------ actions

    func showToast(_ s: String) {
        toast = s
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { self?.toast = nil }
        }
    }

    func toggleMapping() {
        st = engine.status
        if !st.isRunning {
            if mode == .localization && !st.hasPrior {
                pickMap()
                return
            }
            if pickMode { togglePickPose() }
            engine.start(mode)
            mapStart = Date()
        } else {
            engine.stop()
        }
        st = engine.status
        updateStatus()
    }

    func switchMode(_ m: SlamEngine.Mode) {
        guard m != mode else { return }
        st = engine.status
        if st.isRunning {
            showToast("停止してから切り替えてください")
            return
        }
        if mode == .mapping && st.vis_size > 0 {
            confirmSwitchToLoc = true
            return
        }
        applyMode(m)
    }

    func applyMode(_ m: SlamEngine.Mode) {
        mode = m
        engine.prepare(m)
        if pickMode { togglePickPose() }
        mapView.guess = nil
        st = engine.status
        if m == .localization && !st.hasPrior { pickMap() }
        updateStatus()
    }

    func pickMap() {
        guard !loadingMap else { return }
        if engine.status.isRunning {
            showToast("停止してからマップを選んでください")
            return
        }
        showMapPicker = true
    }

    func loadPriorMap(_ item: MapStore.Item) {
        loadingMap = true
        let engine = self.engine
        Task.detached(priority: .userInitiated) {
            let r: Result<Int, Error> = Result {
                let c = try PcdCloudRef(url: item.url)
                guard c.count > 100 else {
                    throw NSError(domain: "PCD", code: 2, userInfo: [NSLocalizedDescriptionKey: "点が少なすぎます (\(c.count)点)"])
                }
                guard engine.setPriorMap(c) else {
                    throw NSError(domain: "PCD", code: 3, userInfo: [NSLocalizedDescriptionKey: "NDTマップを作れませんでした"])
                }
                return c.count
            }
            await MainActor.run {
                self.loadingMap = false
                switch r {
                case .success(let n):
                    self.mapName = item.name
                    self.showToast("マップ読み込み: \(n.formatted())点")
                case .failure(let e):
                    self.showToast("マップ読み込み失敗: \(e.localizedDescription)")
                }
                self.updateStatus()
            }
        }
    }

    func togglePickPose() {
        guard mode == .localization else { return }
        if !engine.status.hasPrior {
            pickMap()
            return
        }
        pickMode.toggle()
        mapView.pickMode = pickMode
        if !pickMode { mapView.pitch = 50 }
    }

    private func onPosePicked(x: Float, y: Float, yaw: Float?) {
        engine.setInitialPose(x: x, y: y, yaw: yaw)
        pickMode = false
        mapView.pickMode = false
        mapView.pitch = 70
        if let yaw {
            showToast(String(format: "初期位置 (%.2f, %.2f)  向き %.0f°", x, y, yaw * 180 / .pi))
        } else {
            showToast(String(format: "初期位置 (%.2f, %.2f)  向きは自動で探索", x, y))
        }
    }

    func savePcd() {
        let url = MapStore.newMapURL()
        if engine.savePcd(to: url) {
            showToast("保存しました: \(url.lastPathComponent)")
            log.info("saved \(url.path)")
        } else {
            showToast("保存失敗: PCD書き出し失敗")
        }
    }

    func toggleRecord() {
        if let cur = receiver.recorder {
            receiver.recorder = nil
            cur.close()
            recordLabel = nil
            showToast("生データ保存: raw/\(cur.url.lastPathComponent)")
        } else {
            let url = MapStore.rawDir.appendingPathComponent("raw_\(MapStore.timestamp()).livox")
            do {
                receiver.recorder = try PacketRecorder(url: url)
                recordLabel = "■ 0MB"
            } catch {
                showToast("記録を開始できません: \(error.localizedDescription)")
            }
        }
    }

    // ------------------------------------------------------------------ status

    var phase: (String, Color) {
        let loc = st.loc_state
        if !running && st.scans > 0 { return ("停止中", Theme.accent) }
        if !running { return (mode == .localization ? "自己位置推定" : "ライブ", Theme.grey) }
        if !st.isTracking { return ("初期化中", Theme.orange) }
        if mode == .mapping { return ("マップ作成中", Theme.green) }
        if loc == 2 { return ("追跡中", Theme.green) }
        if loc == 3 { return ("ロスト", Theme.red) }
        return ("探索中", Theme.orange)
    }

    var canSave: Bool { mode == .mapping && !running && st.vis_size > 0 }

    var hint: String {
        pickMode ? "地図をタッチ: 位置   そのままドラッグ: 向き   (2本指: 移動 / ピンチ: ズーム)"
                 : "1本指: 回転   2本指: 移動   ピンチ: ズーム   ダブルタップ: 追従"
    }

    func updateStatus() {
        let now = CACurrentMediaTime()
        let dt = max(now - prevT, 1e-3)
        let c = receiver.counters
        let pps = Double(c.pointPackets - prev.pointPackets) / dt
        let ptps = Double(c.pointCount - prev.pointCount) / dt
        let ips = Double(c.imuPackets - prev.imuPackets) / dt
        prevT = now
        prev = c
        st = engine.status
        receiver.refreshInterfaces()

        chipEth = Chip(ok: receiver.ethUp, label: receiver.ethUp ? "Ethernet" : "Ethernet 未接続")
        chipLidar = Chip(ok: pps > 100, label: pps > 100 ? String(format: "Mid-360  %.0fk点/s", ptps / 1000) : "LiDAR 受信なし")
        chipImu = Chip(ok: ips > 50, label: String(format: "IMU %.0fHz", ips))

        headline = {
            if running && !st.isTracking { return "静止してください…" }
            if mode == .localization && running {
                switch st.loc_state {
                case 2: return String(format: "一致 %.0f%%  (%.2f, %.2f)  %.0f°", st.match * 100, st.px, st.py, st.yaw * 180 / .pi)
                case 3: return "見失いました。再探索中…"
                default: return "マップと照合中…"
                }
            }
            if mode == .localization { return st.hasPrior ? "開始できます（初期位置の指定は任意）" : "マップを選択してください" }
            if running {
                let sec = Int(Date().timeIntervalSince(mapStart))
                return String(format: "%d:%02d   ", sec / 60, sec % 60) + "\(st.vis_size.formatted())点"
            }
            if st.scans > 0 { return "\(st.vis_size.formatted())点  PCD保存できます" }
            return "待機中"
        }()
        if let r = receiver.recorder { recordLabel = String(format: "■ %.0fMB", Double(r.bytes) / 1e6) }

        var d = ""
        if let e = receiver.socketError { d += "ソケット作成失敗: \(e)\n" }
        d += (receiver.ethUp ? "Ethernet接続" : "Ethernet待機中…") + "\n"
        d += receiver.ethAddrs + "\n"
        d += "LiDAR \(c.lidarInfo)  from \(c.lidarSrc)\n"
        d += String(format: "pkt %.0f/s  pts %.0f/s  lost %lld\n", pps, ptps, c.lostPackets)
        if mode == .localization {
            d += String(format: "NDT %.1f ms  match %.2f  state %d\n", st.ndt_ms, st.match, st.loc_state)
        }
        d += String(format: "SLAM %.1f ms/scan (avg %.1f)  eff %d/%d\n", st.last_ms, st.avg_ms, st.effective, st.ds_points)
        d += String(format: "pos (%.2f, %.2f, %.2f)  yaw %.0f°\n", st.px, st.py, st.pz, st.yaw * 180 / .pi)
        d += String(format: "scans %lld  drop scan %lld pkt %lld  q %d", st.scans, st.dropped_scans, st.dropped_pkts, st.queue)
        details = d
    }
}

/// Triggers the iOS local network permission prompt early (a Bonjour browse is the documented trigger);
/// without the permission, UDP from the Mid-360 is not delivered to the app.
final class LocalNetworkPermission {
    private var browser: NWBrowser?

    func request() {
        guard browser == nil else { return }
        let params = NWParameters()
        params.includePeerToPeer = false
        let b = NWBrowser(for: .bonjour(type: "_mobileslam._udp", domain: nil), using: params)
        b.stateUpdateHandler = { _ in }
        b.browseResultsChangedHandler = { _, _ in }
        b.start(queue: .main)
        browser = b
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.browser?.cancel()
            self?.browser = nil
        }
    }
}
