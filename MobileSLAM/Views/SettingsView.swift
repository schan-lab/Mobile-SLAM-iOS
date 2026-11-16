import SwiftUI

/// Settings screen. Values are saved immediately; the main screen applies them when it comes back.
struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var blind = AppSettings.blind
    @State private var colorMode = AppSettings.colorMode
    @State private var recordFormat = AppSettings.recordFormat
    @State private var playSpeed = AppSettings.playSpeed

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                section("SLAM") {
                    HStack {
                        Text("近くの点を無視する距離").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.text)
                        Spacer()
                        Text(blind <= 0 ? L("無効") : String(format: "%.1f m", blind))
                            .font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.accent)
                    }
                    Slider(value: $blind, in: 0...AppSettings.maxBlind, step: 0.1)
                        .onChange(of: blind) { _, v in AppSettings.blind = v }
                    Text(String(format: L("マップ作成・自己位置推定で、LiDAR からこの距離より近い点を使いません。持っている人の体や手が地図に写り込むのを防ぎます。狭い場所では小さくしてください。（規定 %.1f m、ライブ表示には影響しません）"), AppSettings.defaultBlind))
                        .font(.system(size: 12)).foregroundStyle(Theme.textDim)
                    Button("規定値に戻す") { blind = AppSettings.defaultBlind }
                        .font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 14).frame(height: 34)
                        .background(Capsule().fill(Theme.grey))
                        .buttonStyle(.plain)
                    NavigationLink {
                        SlamParamsView()
                    } label: {
                        HStack {
                            Text("詳細パラメータ").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.text)
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(Theme.textDim)
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                }
                section("rosbag") {
                    Text("記録の形式").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.text)
                    HStack(spacing: 8) {
                        PillButton(label: "ROS 2 (MCAP)", color: recordFormat == .rosbag ? Theme.accent : Theme.grey,
                                   fontSize: 14) { setFormat(.rosbag) }
                        PillButton(label: L("生パケット"), color: recordFormat == .raw ? Theme.accent : Theme.grey,
                                   fontSize: 14) { setFormat(.raw) }
                    }
                    Text("ROS 2 (MCAP)：/livox/imu（sensor_msgs/Imu）と /livox/lidar（sensor_msgs/PointCloud2、点ごとのタイムスタンプ付き）を記録します。ros2 bag play や Foxglove でそのまま開けます。\n生パケット：Mid-360 の UDP パケットをそのまま保存します。")
                        .font(.system(size: 12)).foregroundStyle(Theme.textDim)
                    Text("再生速度").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.text).padding(.top, 4)
                    HStack(spacing: 8) {
                        ForEach(AppSettings.playSpeeds, id: \.self) { v in
                            PillButton(label: String(format: "%gx", v), color: playSpeed == v ? Theme.accent : Theme.grey,
                                       fontSize: 14) {
                                playSpeed = v
                                AppSettings.playSpeed = v
                            }
                        }
                    }
                    Text("rosbag から SLAM するときの再生速度です。速くすると処理が追いつかずスキャンを捨てることがあります。")
                        .font(.system(size: 12)).foregroundStyle(Theme.textDim)
                }
                section(L("表示")) {
                    Text("点群の色").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.text)
                    HStack(spacing: 8) {
                        PillButton(label: L("反射強度"), color: colorMode == AppSettings.colorIntensity ? Theme.accent : Theme.grey,
                                   fontSize: 14) { setColor(AppSettings.colorIntensity) }
                        PillButton(label: L("高さ"), color: colorMode == AppSettings.colorHeight ? Theme.accent : Theme.grey,
                                   fontSize: 14) { setColor(AppSettings.colorHeight) }
                    }
                    Text("反射強度：反射の弱い面は青、強い面は赤。\n高さ：点の高さで色を分けます。\n反射強度の入っていない PCD は高さで色を付けます。")
                        .font(.system(size: 12)).foregroundStyle(Theme.textDim)
                }
                section("Mid-360") {
                    NavigationLink {
                        Mid360NetworkView()
                    } label: {
                        HStack {
                            Text("IP アドレスと送信先").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.text)
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(Theme.textDim)
                        }
                    }
                    .buttonStyle(.plain)
                    Text(String(format: L("Mid-360 の IP アドレスや、点群の送り先（この %@ の IP）を確認・変更します。"), Device.name))
                        .font(.system(size: 12)).foregroundStyle(Theme.textDim)
                }
                section("SFTP") {
                    NavigationLink {
                        SftpSettingsView()
                    } label: {
                        HStack {
                            Text("キーペアと送信先").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.text)
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(Theme.textDim)
                        }
                    }
                    .buttonStyle(.plain)
                    Text("PCD や rosbag を PC やサーバーに SFTP で送ります。送信は PCD ビューア・rosbag の一覧から行います。")
                        .font(.system(size: 12)).foregroundStyle(Theme.textDim)
                }
                section(L("デモ")) {
                    Toggle(isOn: Binding(get: { model.demoMode }, set: { model.setDemoMode($0) })) {
                        Text("実機なしで試す").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.text)
                    }
                    .tint(Theme.accent)
                    Text("Mid-360 がなくても、部屋をスキャンしながら歩く様子を再現した疑似データで、ライブ表示・マップ作成・PCD保存・自己位置推定を試せます。オンの間は実機からのデータと混ざるので、実機を使うときはオフにしてください。")
                        .font(.system(size: 12)).foregroundStyle(Theme.textDim)
                }
                NavigationLink {
                    AboutView()
                } label: {
                    HStack {
                        Text("このアプリについて・ライセンス").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.text)
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(Theme.textDim)
                    }
                    .card(padding: 14)
                }
                .buttonStyle(.plain)
            }
            .padding(12)
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.bg)
        .navigationTitle("設定")
    }

    private func setFormat(_ f: AppSettings.RecordFormat) {
        recordFormat = f
        AppSettings.recordFormat = f
    }

    private func setColor(_ m: Int32) {
        colorMode = m
        AppSettings.colorMode = m
    }

    private func section<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.textDim)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 14)
    }
}
