import SwiftUI

/// Advanced SLAM parameters. Values are saved immediately; the main screen applies them when it comes back.
struct SlamParamsView: View {
    @State private var values: [String: Double] = Self.load()
    @State private var confirmReset = false

    private static func load() -> [String: Double] {
        Dictionary(uniqueKeysWithValues: AppSettings.params.map { ($0.key, AppSettings.value($0)) })
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Text("変更はメイン画面に戻ると反映されます（解像度は次に開始したときから）。分からないときは規定値のまま使ってください。")
                    .font(.system(size: 12)).foregroundStyle(Theme.textDim)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ForEach(SlamParam.Group.allCases, id: \.self) { g in
                    section(title(g), note: note(g)) {
                        ForEach(AppSettings.params.filter { $0.group == g }) { p in row(p) }
                    }
                }
                Button("すべて規定値に戻す") { confirmReset = true }
                    .font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                    .padding(.horizontal, 18).frame(height: 40)
                    .background(Capsule().fill(Theme.red))
                    .buttonStyle(.plain)
            }
            .padding(12)
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.bg)
        .navigationTitle("詳細パラメータ")
        .alert("すべて規定値に戻しますか？", isPresented: $confirmReset) {
            Button("キャンセル", role: .cancel) {}
            Button("戻す", role: .destructive) {
                AppSettings.resetParams()
                values = Self.load()
            }
        }
    }

    private func title(_ g: SlamParam.Group) -> String {
        switch g {
        case .scan: return L("スキャンとマップ")
        case .optimizer: return L("位置合わせ")
        case .noise: return L("ノイズ")
        case .extrinsic: return L("LiDAR の取り付け位置（IMU 座標系）")
        case .localization: return L("自己位置推定")
        }
    }

    private func note(_ g: SlamParam.Group) -> String? {
        switch g {
        case .extrinsic: return L("IMU から見た LiDAR 原点の位置です。Mid-360 の内蔵 IMU なら規定値のままで構いません。")
        default: return nil
        }
    }

    private func binding(_ p: SlamParam) -> Binding<Double> {
        Binding(
            get: {
                let v = values[p.key] ?? p.read(AppSettings.defaultParams)
                return p.log ? log10(v) : v
            },
            set: { raw in
                var v = p.log ? pow(10, raw) : raw
                if p.log {
                    // one significant digit, so the label and the stored value agree
                    let e = floor(log10(v))
                    v = (v / pow(10, e)).rounded() * pow(10, e)
                }
                values[p.key] = v
                AppSettings.setValue(p, v)
            })
    }

    @ViewBuilder
    private func row(_ p: SlamParam) -> some View {
        let v = values[p.key] ?? p.read(AppSettings.defaultParams)
        let isDefault = abs(v - p.read(AppSettings.defaultParams)) < max(p.step, abs(v) * 1e-3) / 2
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(p.title).font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.text)
                Spacer()
                Text(p.format(v)).font(.system(size: 16, weight: .bold, design: .monospaced))
                    .foregroundStyle(isDefault ? Theme.textDim : Theme.accent)
            }
            if p.log {
                Slider(value: binding(p), in: log10(p.range.lowerBound)...log10(p.range.upperBound))
            } else {
                Slider(value: binding(p), in: p.range, step: p.step)
            }
            HStack {
                if !p.note.isEmpty {
                    Text(p.note).font(.system(size: 12)).foregroundStyle(Theme.textDim)
                }
                Spacer()
                if !isDefault {
                    Button(String(format: L("規定 %@"), p.format(p.read(AppSettings.defaultParams)))) {
                        values[p.key] = p.read(AppSettings.defaultParams)
                        AppSettings.setValue(p, p.read(AppSettings.defaultParams))
                    }
                    .font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.accent)
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func section<C: View>(_ title: String, note: String?, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.textDim)
            if let note { Text(note).font(.system(size: 12)).foregroundStyle(Theme.textDim) }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 14)
    }
}
