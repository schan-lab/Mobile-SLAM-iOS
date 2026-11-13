import SwiftUI

/// Settings screen. Values are saved immediately; the main screen applies them when it comes back.
struct SettingsView: View {
    @State private var blind = AppSettings.blind
    @State private var colorMode = AppSettings.colorMode

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                section("SLAM") {
                    HStack {
                        Text("近くの点を無視する距離").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.text)
                        Spacer()
                        Text(blind <= 0 ? "無効" : String(format: "%.1f m", blind))
                            .font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.accent)
                    }
                    Slider(value: $blind, in: 0...AppSettings.maxBlind, step: 0.1)
                        .onChange(of: blind) { _, v in AppSettings.blind = v }
                    Text("マップ作成・自己位置推定で、LiDAR からこの距離より近い点を使いません。" +
                         "持っている人の体や手が地図に写り込むのを防ぎます。狭い場所では小さくしてください。" +
                         String(format: "（規定 %.1f m、ライブ表示には影響しません）", AppSettings.defaultBlind))
                        .font(.system(size: 12)).foregroundStyle(Theme.textDim)
                    Button("規定値に戻す") { blind = AppSettings.defaultBlind }
                        .font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 14).frame(height: 34)
                        .background(Capsule().fill(Theme.grey))
                        .buttonStyle(.plain)
                }
                section("表示") {
                    Text("点群の色").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.text)
                    HStack(spacing: 8) {
                        PillButton(label: "反射強度", color: colorMode == AppSettings.colorIntensity ? Theme.accent : Theme.grey,
                                   fontSize: 14) { setColor(AppSettings.colorIntensity) }
                        PillButton(label: "高さ", color: colorMode == AppSettings.colorHeight ? Theme.accent : Theme.grey,
                                   fontSize: 14) { setColor(AppSettings.colorHeight) }
                    }
                    Text("反射強度：反射の弱い面は青、強い面は赤。\n高さ：点の高さで色を分けます。\n反射強度の入っていない PCD は高さで色を付けます。")
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
        }
        .background(Theme.bg)
        .navigationTitle("設定")
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
