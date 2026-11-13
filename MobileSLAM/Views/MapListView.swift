import SwiftUI
import UniformTypeIdentifiers

/// Lists PCD maps saved in Documents. pick = true returns the chosen map instead of opening the viewer.
struct MapListView: View {
    let pick: Bool
    let onSelect: (MapStore.Item) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var items: [MapStore.Item] = []
    @State private var importing = false
    @State private var deleting: MapStore.Item?
    @State private var error: String?

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
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
                            if !pick {
                                Button("削除", role: .destructive) { deleting = item }
                            }
                        }
                }
            } footer: {
                if items.isEmpty {
                    Text("まだ保存されたマップがありません。\nマップ作成後に「PCD保存」を押してください。\n" +
                         "PC などから受け取った PCD は「ファイルを開く」で取り込めます。")
                        .font(.system(size: 14)).foregroundStyle(Theme.textDim)
                        .frame(maxWidth: .infinity).multilineTextAlignment(.center).padding(.top, 40)
                } else {
                    Text(pick ? "タップで選択" : "タップで表示・左にスワイプで削除\nファイル App の「このiPhone内 › Mobile SLAM」からも取り出せます")
                        .font(.system(size: 12)).foregroundStyle(Theme.textDim)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .navigationTitle(pick ? "使うマップを選択" : "保存済みマップ")
        .toolbar {
            if pick {
                ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } }
            }
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
        .onAppear(perform: refresh)
    }

    private func refresh() { items = MapStore.list() }

    private func row(_ item: MapStore.Item) -> some View {
        HStack(spacing: 12) {
            Text("◉").font(.system(size: 20, weight: .bold)).foregroundStyle(Theme.accent)
                .frame(width: 44, height: 44)
                .background(RoundedRectangle(cornerRadius: 12).fill(Theme.accent.opacity(0.13)))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.text).lineLimit(1)
                Text(String(format: "%@   %.1f MB   約", Self.dateFmt.string(from: item.modified), Double(item.size) / 1e6)
                     + "\((item.size / 16).formatted())点")
                    .font(.system(size: 12)).foregroundStyle(Theme.textDim)
            }
        }
        .padding(.vertical, 4)
    }
}
