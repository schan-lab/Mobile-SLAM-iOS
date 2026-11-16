import Foundation

/// User settings, stored in UserDefaults.
enum AppSettings {
    /// Values match the colour modes of the point shader.
    static let colorHeight: Int32 = 0
    static let colorIntensity: Int32 = 2

    static let defaultBlind: Float = 1.5
    static let maxBlind: Float = 5.0

    private static let keyBlind = "blind_m"
    private static let keyColor = "color_mode"

    /// Points closer than this (m) are ignored by SLAM / localisation.
    static var blind: Float {
        get {
            let d = UserDefaults.standard
            guard d.object(forKey: keyBlind) != nil else { return defaultBlind }
            return min(max(d.float(forKey: keyBlind), 0), maxBlind)
        }
        set { UserDefaults.standard.set(min(max(newValue, 0), maxBlind), forKey: keyBlind) }
    }

    static var colorMode: Int32 {
        get {
            let d = UserDefaults.standard
            guard d.object(forKey: keyColor) != nil else { return colorIntensity }
            return Int32(d.integer(forKey: keyColor)) == colorHeight ? colorHeight : colorIntensity
        }
        set { UserDefaults.standard.set(Int(newValue), forKey: keyColor) }
    }
}

// ------------------------------------------------------------------ recording / playback

extension AppSettings {
    enum RecordFormat: String {
        case rosbag
        case raw
    }

    private static let keyRecordFormat = "record_format"
    private static let keyPlaySpeed = "bag_play_speed"
    static let playSpeeds: [Double] = [0.5, 1, 2]

    /// Format of the "記録" button (default: ROS 2 bag).
    static var recordFormat: RecordFormat {
        get { RecordFormat(rawValue: UserDefaults.standard.string(forKey: keyRecordFormat) ?? "") ?? .rosbag }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: keyRecordFormat) }
    }

    static var playSpeed: Double {
        get {
            let v = UserDefaults.standard.double(forKey: keyPlaySpeed)
            return playSpeeds.contains(v) ? v : 1
        }
        set { UserDefaults.standard.set(newValue, forKey: keyPlaySpeed) }
    }
}

// ------------------------------------------------------------------ SLAM parameters

/// One tunable SLAM parameter (stored in UserDefaults as "slam.<key>", blind keeps its old key).
struct SlamParam: Identifiable {
    enum Group: CaseIterable {
        case scan, optimizer, noise, extrinsic, localization
    }

    let key: String
    let group: Group
    let title: String
    let note: String
    let range: ClosedRange<Double>
    let step: Double
    let unit: String
    let digits: Int
    /// Slider moves in log10 space (noise parameters spanning decades).
    var log = false
    let read: (SlamParams) -> Double
    let write: (inout SlamParams, Double) -> Void

    var id: String { key }

    func format(_ v: Double) -> String {
        let s = log ? String(format: "%.0e", v) : String(format: "%.\(digits)f", v)
        return unit.isEmpty ? s : "\(s) \(unit)"
    }
}

extension AppSettings {
    static let defaultParams: SlamParams = {
        var p = SlamParams()
        slam_default_params(&p)
        p.blind = defaultBlind
        return p
    }()

    static let params: [SlamParam] = [
        SlamParam(key: "max_range", group: .scan, title: L("最大距離"),
                  note: L("これより遠い点を使いません。"),
                  range: 10...200, step: 5, unit: "m", digits: 0,
                  read: { Double($0.max_range) }, write: { $0.max_range = Float($1) }),
        SlamParam(key: "scan_ds", group: .scan, title: L("スキャンの間引き"),
                  note: L("位置合わせに使う点をこの大きさの格子で間引きます。大きいほど速く、小さいほど細かく合わせます。"),
                  range: 0.05...1.0, step: 0.05, unit: "m", digits: 2,
                  read: { Double($0.scan_ds) }, write: { $0.scan_ds = Float($1) }),
        SlamParam(key: "map_res", group: .scan, title: L("位置合わせ用マップの解像度"),
                  note: L("次に開始したときから反映されます。"),
                  range: 0.05...1.0, step: 0.05, unit: "m", digits: 2,
                  read: { Double($0.map_res) }, write: { $0.map_res = Float($1) }),
        SlamParam(key: "vis_res", group: .scan, title: L("表示・PCD の解像度"),
                  note: L("保存する PCD の点の間隔です。小さいほど細かく、ファイルが大きくなります。次に開始したときから反映されます。"),
                  range: 0.01...0.5, step: 0.01, unit: "m", digits: 2,
                  read: { Double($0.vis_res) }, write: { $0.vis_res = Float($1) }),
        SlamParam(key: "max_iter", group: .optimizer, title: L("反復回数"),
                  note: L("1スキャンあたりのカルマンフィルタ更新の最大反復回数です。"),
                  range: 1...10, step: 1, unit: "", digits: 0,
                  read: { Double($0.max_iter) }, write: { $0.max_iter = Int32($1.rounded()) }),
        SlamParam(key: "plane_thresh", group: .optimizer, title: L("平面とみなす誤差"),
                  note: L("近くの点を平面に当てはめるときの許容誤差です。"),
                  range: 0.02...0.5, step: 0.01, unit: "m", digits: 2,
                  read: { Double($0.plane_thresh) }, write: { $0.plane_thresh = Float($1) }),
        SlamParam(key: "knn_max_d2", group: .optimizer, title: L("近傍探索の範囲"),
                  note: L("平面を作る5点目までの距離の2乗の上限です。"),
                  range: 0.5...20, step: 0.5, unit: "m²", digits: 1,
                  read: { Double($0.knn_max_d2) }, write: { $0.knn_max_d2 = Float($1) }),
        SlamParam(key: "gyr_cov", group: .noise, title: L("ジャイロのノイズ"),
                  note: "", range: 1e-4...10, step: 0, unit: "", digits: 0, log: true,
                  read: { Double($0.gyr_cov) }, write: { $0.gyr_cov = Float($1) }),
        SlamParam(key: "acc_cov", group: .noise, title: L("加速度のノイズ"),
                  note: "", range: 1e-4...10, step: 0, unit: "", digits: 0, log: true,
                  read: { Double($0.acc_cov) }, write: { $0.acc_cov = Float($1) }),
        SlamParam(key: "laser_cov", group: .noise, title: L("LiDAR のノイズ"),
                  note: L("小さいほど LiDAR を信頼し、大きいほど IMU を信頼します。"),
                  range: 1e-5...1e-1, step: 0, unit: "", digits: 0, log: true,
                  read: { Double($0.laser_cov) }, write: { $0.laser_cov = Float($1) }),
        SlamParam(key: "ext_x", group: .extrinsic, title: "x",
                  note: "", range: -0.3...0.3, step: 0.001, unit: "m", digits: 3,
                  read: { Double($0.ext_t.0) }, write: { $0.ext_t.0 = Float($1) }),
        SlamParam(key: "ext_y", group: .extrinsic, title: "y",
                  note: "", range: -0.3...0.3, step: 0.001, unit: "m", digits: 3,
                  read: { Double($0.ext_t.1) }, write: { $0.ext_t.1 = Float($1) }),
        SlamParam(key: "ext_z", group: .extrinsic, title: "z",
                  note: "", range: -0.3...0.3, step: 0.001, unit: "m", digits: 3,
                  read: { Double($0.ext_t.2) }, write: { $0.ext_t.2 = Float($1) }),
        SlamParam(key: "ndt_res", group: .localization, title: L("NDT の格子サイズ"),
                  note: L("自己位置推定でマップを表す格子の大きさです。"),
                  range: 0.5...3, step: 0.1, unit: "m", digits: 1,
                  read: { Double($0.ndt_res) }, write: { $0.ndt_res = Float($1) }),
        SlamParam(key: "loc_match_ok", group: .localization, title: L("一致率のしきい値"),
                  note: L("追跡中、これより一致率が低い結果は使いません。"),
                  range: 0.1...0.9, step: 0.05, unit: "", digits: 2,
                  read: { Double($0.loc_match_ok) }, write: { $0.loc_match_ok = Float($1) }),
        SlamParam(key: "loc_init_radius", group: .localization, title: L("初期位置の探索半径"),
                  note: L("指定した初期位置のまわりを探す範囲です。"),
                  range: 0...5, step: 0.5, unit: "m", digits: 1,
                  read: { Double($0.loc_init_radius) }, write: { $0.loc_init_radius = Float($1) }),
    ]

    private static func paramKey(_ key: String) -> String { "slam.\(key)" }

    static func value(_ p: SlamParam) -> Double {
        let d = UserDefaults.standard
        guard d.object(forKey: paramKey(p.key)) != nil else { return p.read(defaultParams) }
        return min(max(d.double(forKey: paramKey(p.key)), p.range.lowerBound), p.range.upperBound)
    }

    static func setValue(_ p: SlamParam, _ v: Double) {
        UserDefaults.standard.set(min(max(v, p.range.lowerBound), p.range.upperBound), forKey: paramKey(p.key))
    }

    /// Forgets all tuned values (blind included).
    static func resetParams() {
        for p in params { UserDefaults.standard.removeObject(forKey: paramKey(p.key)) }
        blind = defaultBlind
    }

    /// Current parameters for the SLAM core.
    static var slamParams: SlamParams {
        var s = defaultParams
        for p in params { p.write(&s, value(p)) }
        s.blind = blind
        return s
    }
}
