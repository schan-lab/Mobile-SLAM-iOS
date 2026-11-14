import SwiftUI

/// Full-screen 3D viewer for one PCD.
struct PcdViewerView: View {
    let item: MapStore.Item

    @State private var view = PcdMTKView()
    @State private var info = L("読み込み中…")
    @State private var failed = false
    @State private var sizeIdx = 1
    private let sizes: [Float] = [1.5, 2.5, 4, 6]

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            MetalViewHost(view: view).ignoresSafeArea()
            VStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.text).lineLimit(1)
                    Text(info).font(.system(size: 12)).foregroundStyle(failed ? Theme.red : Theme.textDim)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()
                Spacer()
                Text("1本指: 回転   2本指: 移動   ピンチ: ズーム   ダブルタップ: 全体表示")
                    .font(.system(size: 11)).foregroundStyle(Theme.textDim)
                HStack(spacing: 8) {
                    PillButton(label: L("全体表示"), height: 50, fontSize: 14) { view.fit() }
                    PillButton(label: L("点サイズ") + " " + String(repeating: "●", count: sizeIdx + 1), height: 50, fontSize: 14) {
                        sizeIdx = (sizeIdx + 1) % sizes.count
                        view.pointSize = sizes[sizeIdx]
                    }
                    ShareLink(item: item.url) {
                        Text("共有").font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: 50)
                            .background(Capsule().fill(Theme.accent))
                    }
                }
                .card(padding: 8)
            }
            .frame(maxWidth: 600)
            .padding(12)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .onAppear {
            view.colorMode = AppSettings.colorMode
            load()
        }
    }

    private func load() {
        let url = item.url
        Task.detached(priority: .userInitiated) {
            let t0 = Date()
            let r = Result { try PcdCloudRef(url: url) }
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            await MainActor.run {
                switch r {
                case .success(let c):
                    view.setCloud(c)
                    let s = c.maxP - c.minP
                    let sub = c.count < c.total ? String(format: L("（%@点を表示）"), c.count.formatted()) : ""
                    info = String(format: L("%@点%@   %.1f × %.1f × %.1f m   %@   %dms"),
                                  c.total.formatted(), sub, s.x, s.y, s.z, c.format, ms)
                case .failure(let e):
                    info = String(format: L("読み込み失敗: %@"), e.localizedDescription)
                    failed = true
                }
            }
        }
    }
}
