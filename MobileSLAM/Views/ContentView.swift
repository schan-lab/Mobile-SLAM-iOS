import SwiftUI

/// Main screen: live 3D view, status card and controls.
struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var path = NavigationPath()

    enum Route: Hashable { case maps, settings, viewer(MapStore.Item) }

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                Theme.bg.ignoresSafeArea()
                MetalViewHost(view: model.mapView).ignoresSafeArea()
                VStack(spacing: 0) {
                    statusCard
                    Spacer()
                    if let t = model.toast { ToastView(text: t).padding(.bottom, 10) }
                    bottomControls
                }
                .padding(12)
                .animation(.easeInOut(duration: 0.2), value: model.toast)
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Route.self) { r in
                switch r {
                case .maps: MapListView(pick: false) { item in path.append(Route.viewer(item)) }
                case .settings: SettingsView()
                case .viewer(let item): PcdViewerView(item: item)
                }
            }
        }
        .sheet(isPresented: $model.showMapPicker) {
            NavigationStack {
                MapListView(pick: true) { item in
                    model.showMapPicker = false
                    model.loadPriorMap(item)
                }
            }
            .preferredColorScheme(.dark)
        }
        .alert("自己位置推定に切り替え", isPresented: $model.confirmSwitchToLoc) {
            Button("キャンセル", role: .cancel) {}
            Button("切り替える") { model.applyMode(.localization) }
        } message: {
            Text("作成中のマップは表示から消えます。必要なら先に「PCD保存」してください。")
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active { model.activate() } else if phase == .background { model.deactivate() }
        }
        .onChange(of: path.count) { _, n in
            // back on the main screen: settings may have changed
            model.mapView.isPaused = n > 0
            if n == 0 { model.applySettings() }
        }
    }

    // ------------------------------------------------------------------ top card

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    StatusChip(ok: model.chipEth.ok, label: model.chipEth.label)
                    StatusChip(ok: model.chipLidar.ok, label: model.chipLidar.label)
                    StatusChip(ok: model.chipImu.ok, label: model.chipImu.label)
                }
            }
            HStack(spacing: 8) {
                let (label, color) = model.phase
                Text(label)
                    .font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 10).fill(color))
                Text(model.headline)
                    .font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.text)
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                smallButton("保存済みマップ") { path.append(Route.maps) }
                smallButton("設定") { path.append(Route.settings) }
            }
            if model.showDetails {
                Text(model.details)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textDim)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .card()
        .contentShape(Rectangle())
        .onTapGesture { model.showDetails.toggle() }
    }

    private func smallButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                .lineLimit(1).fixedSize()
                .padding(.horizontal, 12).frame(height: 32)
                .background(Capsule().fill(Theme.grey))
        }
        .buttonStyle(.plain)
    }

    // ------------------------------------------------------------------ bottom controls

    private var bottomControls: some View {
        VStack(spacing: 8) {
            Text(model.hint)
                .font(.system(size: 11))
                .foregroundStyle(model.pickMode ? Theme.orange : Theme.textDim)
                .multilineTextAlignment(.center)
            if model.mode == .localization {
                HStack(spacing: 8) {
                    PillButton(label: model.loadingMap ? "読み込み中…" : (model.mapName.map { "🗺 \($0)" } ?? "マップを選択"),
                               height: 40, fontSize: 13) { model.pickMap() }
                        .layoutPriority(1)
                    PillButton(label: model.pickMode ? "指定をやめる" : "初期位置を指定",
                               color: model.pickMode ? Theme.orange : Theme.grey, height: 40, fontSize: 13) {
                        model.togglePickPose()
                    }
                }
            }
            HStack(spacing: 6) {
                PillButton(label: "マップ作成", color: model.mode == .mapping ? Theme.accent : Theme.grey,
                           height: 38, fontSize: 13) { model.switchMode(.mapping) }
                PillButton(label: "自己位置推定", color: model.mode == .localization ? Theme.accent : Theme.grey,
                           height: 38, fontSize: 13) { model.switchMode(.localization) }
            }
            .card(padding: 6)
            HStack(spacing: 8) {
                PillButton(label: model.recordLabel ?? "● 記録", color: model.recordLabel != nil ? Theme.red : Theme.grey,
                           height: 56, fontSize: 14) { model.toggleRecord() }
                    .frame(width: 96)
                PillButton(label: model.running ? "■  停止"
                                : (model.mode == .localization ? "▶  自己位置推定 開始" : "▶  マップ作成 開始"),
                           color: model.running ? Theme.red : Theme.accent, height: 56, fontSize: 16) {
                    model.toggleMapping()
                }
                PillButton(label: "PCD保存", color: model.canSave ? Theme.green : Theme.grey, height: 56, fontSize: 14,
                           enabled: model.canSave) { model.savePcd() }
                    .frame(width: 96)
            }
            .card(padding: 8)
        }
    }
}

/// Hosts an existing UIView (the Metal views are owned by the model so they survive SwiftUI updates).
struct MetalViewHost: UIViewRepresentable {
    let view: UIView
    func makeUIView(context: Context) -> UIView { view }
    func updateUIView(_ uiView: UIView, context: Context) {}
}
