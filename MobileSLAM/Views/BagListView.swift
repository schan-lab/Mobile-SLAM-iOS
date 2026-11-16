import SwiftUI

/// Lists ROS 2 bags (MCAP) to run SLAM on: recordings of the 記録 button and imported files.
struct BagListView: View {
    let onSelect: (MapStore.Item) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var items: [MapStore.Item] = []
    @State private var importing = false
    @State private var deleting: MapStore.Item?
    @State private var error: String?
    @State private var sending: MapStore.Item?

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy/MM/dd HH:mm"
        return f
    }()

    var body: some View {
        List {
            Section {
                ForEach(items) { item in
                    Button { onSelect(item) } label: { row(item) }
                        .listRowBackground(Theme.card)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button("削除", role: .destructive) { deleting = item }
                            ShareLink(item: item.url) { Label("共有", systemImage: "square.and.arrow.up") }
                                .tint(Theme.accent)
                            Button { sending = item } label: { Label("SFTP", systemImage: "arrow.up.to.line") }
                                .tint(Theme.green)
                        }
                        .contextMenu {
                            ShareLink(item: item.url) { Label("共有", systemImage: "square.and.arrow.up") }
                            Button { sending = item } label: { Label("SFTP で送信", systemImage: "arrow.up.to.line") }
                            Button(role: .destructive) { deleting = item } label: {
                                Label("削除", systemImage: "trash")
                            }
                        }
                }
            } footer: {
                if items.isEmpty {
                    Text("rosbag がありません。\n「● 記録」で保存するか、PC などで ros2 bag record した MCAP ファイルを「ファイルを開く」で取り込んでください。")
                        .font(.system(size: 14)).foregroundStyle(Theme.textDim)
                        .frame(maxWidth: .infinity).multilineTextAlignment(.center).padding(.top, 40)
                } else {
                    Text("タップで選択・左にスワイプか長押しで共有・SFTP 送信・削除\n対応: ROS 2 の MCAP（無圧縮・zstd・lz4）。PointCloud2 または Livox CustomMsg と、Imu のトピックを使います。")
                        .font(.system(size: 12)).foregroundStyle(Theme.textDim)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .navigationTitle("rosbag を選択")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } }
            ToolbarItem(placement: .primaryAction) { Button("ファイルを開く") { importing = true } }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data, .item]) { r in
            switch r {
            case .success(let url):
                do {
                    let dst = try MapStore.importFile(url)
                    refresh()
                    if let it = items.first(where: { $0.url.standardizedFileURL == dst.standardizedFileURL }) { onSelect(it) }
                } catch { self.error = error.localizedDescription }
            case .failure(let e): self.error = e.localizedDescription
            }
        }
        .alert("削除しますか？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("キャンセル", role: .cancel) {}
            Button("削除", role: .destructive) {
                if let d = deleting { try? FileManager.default.removeItem(at: d.url) }
                refresh()
            }
        } message: { Text(deleting?.name ?? "") }
        .alert("エラー", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(error ?? "") }
        .sheet(item: $sending) { item in
            NavigationStack { SftpSendView(item: item) }
                .preferredColorScheme(.dark)
        }
        .onAppear(perform: refresh)
    }

    private func refresh() { items = MapStore.listBags() }

    private func row(_ item: MapStore.Item) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "film.stack").font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.accent)
                .frame(width: 44, height: 44)
                .background(RoundedRectangle(cornerRadius: 12).fill(Theme.accent.opacity(0.13)))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.text).lineLimit(1)
                Text(String(format: L("%@   %.1f MB"), Self.dateFmt.string(from: item.modified), Double(item.size) / 1e6))
                    .font(.system(size: 12)).foregroundStyle(Theme.textDim)
            }
        }
        .padding(.vertical, 4)
    }
}
