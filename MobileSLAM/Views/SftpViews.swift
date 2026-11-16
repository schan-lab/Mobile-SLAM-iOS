import SwiftUI
import UIKit

// ------------------------------------------------------------------ settings: key pair + destinations

/// SFTP settings: the app's key pair and the saved destinations.
struct SftpSettingsView: View {
    @State private var hosts = SftpHostStore.load()
    @State private var fingerprint = SshKey.fingerprint
    @State private var confirmRegen = false
    @State private var copied = false
    @State private var editing: SftpHost?

    var body: some View {
        List {
            Section {
                if let fp = fingerprint {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Ed25519").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.text)
                        Text(fp).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.textDim)
                            .textSelection(.enabled)
                    }
                    Button {
                        if let line = SshKey.publicKeyLine {
                            UIPasteboard.general.string = line
                            copied = true
                        }
                    } label: {
                        Label(copied ? L("コピーしました") : L("公開鍵をコピー"), systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    Button(role: .destructive) { confirmRegen = true } label: {
                        Label("キーペアを作り直す", systemImage: "arrow.triangle.2.circlepath")
                    }
                } else {
                    Button {
                        SshKey.generate()
                        fingerprint = SshKey.fingerprint
                    } label: {
                        Label("キーペアを作成", systemImage: "key")
                    }
                }
            } header: {
                Text("キーペア")
            } footer: {
                Text("秘密鍵はこの端末のキーチェーンにだけ保存され、外に出ません。公開鍵をコピーして、送信先サーバーの ~/.ssh/authorized_keys に1行で追加してください。")
            }
            .listRowBackground(Theme.card)

            Section {
                ForEach(hosts) { h in
                    Button { editing = h } label: { SftpHostRow(host: h) }
                        .swipeActions {
                            Button("削除", role: .destructive) {
                                SftpHostStore.delete(h)
                                hosts = SftpHostStore.load()
                            }
                        }
                }
                Button {
                    editing = SftpHost()
                } label: {
                    Label("送信先を追加", systemImage: "plus")
                }
            } header: {
                Text("送信先")
            }
            .listRowBackground(Theme.card)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .navigationTitle("SFTP")
        .sheet(item: $editing, onDismiss: { hosts = SftpHostStore.load() }) { h in
            NavigationStack { SftpHostEditView(host: h) }
                .preferredColorScheme(.dark)
        }
        .alert("キーペアを作り直しますか？", isPresented: $confirmRegen) {
            Button("キャンセル", role: .cancel) {}
            Button("作り直す", role: .destructive) {
                SshKey.generate()
                fingerprint = SshKey.fingerprint
                copied = false
            }
        } message: {
            Text("今の鍵は使えなくなります。新しい公開鍵を各サーバーに登録し直してください。")
        }
    }
}

struct SftpHostRow: View {
    let host: SftpHost

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(host.title).font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.text).lineLimit(1)
            Text(host.summary).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.textDim).lineLimit(1)
        }
        .padding(.vertical, 2)
    }
}

/// Adds or edits one destination.
struct SftpHostEditView: View {
    @Environment(\.dismiss) private var dismiss
    @State var host: SftpHost
    @State private var port = ""
    @State private var password = ""

    init(host: SftpHost) {
        _host = State(initialValue: host)
        _port = State(initialValue: String(host.port))
        _password = State(initialValue: SftpHostStore.password(host) ?? "")
    }

    private var valid: Bool {
        !host.host.trimmingCharacters(in: .whitespaces).isEmpty && !host.user.trimmingCharacters(in: .whitespaces).isEmpty
            && (Int(port).map { (1...65535).contains($0) } ?? false)
    }

    var body: some View {
        Form {
            Section {
                field(L("名前（任意）"), $host.name, placeholder: L("研究室の PC"), id: "sftp.name")
                field(L("ホスト"), $host.host, placeholder: "192.168.1.10", id: "sftp.host")
                field(L("ポート"), $port, placeholder: "22", keyboard: .numberPad, id: "sftp.port")
                field(L("ユーザー名"), $host.user, placeholder: "ubuntu", id: "sftp.user")
                field(L("転送先パス"), $host.remoteDir, placeholder: "data/mobile_slam", id: "sftp.path")
            } footer: {
                Text("転送先パスは / で始めると絶対パス、それ以外はログインしたディレクトリからの相対パスです。ないフォルダは作ります。空欄ならログインしたディレクトリに送ります。")
            }
            Section {
                Picker("認証", selection: $host.auth) {
                    Text("キーペア").tag(SftpHost.Auth.key)
                    Text("パスワード").tag(SftpHost.Auth.password)
                }
                if host.auth == .password {
                    SecureField("パスワード", text: $password)
                        .textContentType(.password)
                }
            } footer: {
                if host.auth == .key {
                    Text(SshKey.fingerprint == nil ? L("SFTP 設定でキーペアを作成し、公開鍵をサーバーに登録してください。")
                                                   : L("SFTP 設定でコピーした公開鍵をサーバーに登録してください。"))
                } else {
                    Text("パスワードはこの端末のキーチェーンに保存します。")
                }
            }
            if let k = host.hostKey {
                Section {
                    Text(k).font(.system(size: 11, design: .monospaced)).lineLimit(3).textSelection(.enabled)
                    Button("ホスト鍵をリセット", role: .destructive) { host.hostKey = nil }
                } header: {
                    Text("ホスト鍵")
                } footer: {
                    Text("最初に接続したときのサーバーの鍵です。違う鍵のサーバーには送信しません。サーバーを入れ替えたときはリセットしてください。")
                }
            }
        }
        .navigationTitle(host.host.isEmpty ? L("送信先を追加") : host.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") {
                    host.host = host.host.trimmingCharacters(in: .whitespaces)
                    host.user = host.user.trimmingCharacters(in: .whitespaces)
                    host.remoteDir = host.remoteDir.trimmingCharacters(in: .whitespaces)
                    host.port = Int(port) ?? 22
                    SftpHostStore.upsert(host)
                    SftpHostStore.setPassword(host, host.auth == .password ? password : "")
                    dismiss()
                }
                .disabled(!valid)
            }
        }
    }

    private func field(_ label: String, _ text: Binding<String>, placeholder: String,
                       keyboard: UIKeyboardType = .asciiCapable, id: String) -> some View {
        HStack {
            Text(label).frame(width: 110, alignment: .leading)
            TextField(placeholder, text: text)
                .keyboardType(keyboard)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier(id)
        }
    }
}

// ------------------------------------------------------------------ send sheet

/// Picks a destination and uploads one file.
struct SftpSendView: View {
    let item: MapStore.Item

    @Environment(\.dismiss) private var dismiss
    @State private var hosts = SftpHostStore.load()
    @State private var state = SendState.idle
    @State private var task: Task<Void, Never>?
    @State private var editing: SftpHost?

    enum SendState: Equatable {
        case idle
        case sending(host: String, done: Int64, total: Int64)
        case done(String)
        case failed(String)
    }

    private var busy: Bool {
        if case .sending = state { return true }
        return false
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.text).lineLimit(1)
                    Text(String(format: "%.1f MB", Double(item.size) / 1e6)).font(.system(size: 12)).foregroundStyle(Theme.textDim)
                }
            }
            .listRowBackground(Theme.card)
            statusSection
            Section {
                ForEach(hosts) { h in
                    Button { send(to: h) } label: {
                        HStack {
                            SftpHostRow(host: h)
                            Spacer()
                            Image(systemName: "arrow.up.circle.fill").font(.system(size: 22)).foregroundStyle(Theme.accent)
                        }
                    }
                    .disabled(busy)
                }
                Button { editing = SftpHost() } label: { Label("送信先を追加", systemImage: "plus") }
                    .disabled(busy)
            } header: {
                Text("送信先")
            } footer: {
                if hosts.isEmpty {
                    Text("送信先がありません。追加してください。キーペアの作成と公開鍵のコピーは 設定 › SFTP でできます。")
                }
            }
            .listRowBackground(Theme.card)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .navigationTitle("SFTP で送信")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(busy ? L("中止") : L("閉じる")) {
                    if busy {
                        task?.cancel()
                    } else {
                        dismiss()
                    }
                }
            }
        }
        .interactiveDismissDisabled(busy)
        .sheet(item: $editing, onDismiss: { hosts = SftpHostStore.load() }) { h in
            NavigationStack { SftpHostEditView(host: h) }
                .preferredColorScheme(.dark)
        }
        .onDisappear { task?.cancel() }
    }

    @ViewBuilder
    private var statusSection: some View {
        switch state {
        case .idle:
            EmptyView()
        case .sending(let host, let done, let total):
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(String(format: L("%@ に送信中…"), host)).font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.text)
                    ProgressView(value: total > 0 ? Double(done) / Double(total) : 0)
                    Text(String(format: "%.1f / %.1f MB", Double(done) / 1e6, Double(total) / 1e6))
                        .font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.textDim)
                }
            }
            .listRowBackground(Theme.card)
        case .done(let path):
            Section {
                Label(String(format: L("送信しました: %@"), path), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Theme.green)
            }
            .listRowBackground(Theme.card)
        case .failed(let msg):
            Section {
                Label(msg, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.red)
            }
            .listRowBackground(Theme.card)
        }
    }

    private func send(to host: SftpHost) {
        state = .sending(host: host.title, done: 0, total: item.size)
        let url = item.url
        task = Task {
            do {
                let r = try await SftpUploader.upload(url, to: host) { done, total in
                    Task { @MainActor in
                        if case .sending = state { state = .sending(host: host.title, done: done, total: total) }
                    }
                }
                if let k = r.newHostKey {
                    var h = host
                    h.hostKey = k
                    SftpHostStore.upsert(h)
                    hosts = SftpHostStore.load()
                }
                state = .done(r.remotePath)
            } catch is CancellationError {
                state = .failed(L("中止しました"))
            } catch {
                state = .failed(String(format: L("送信できませんでした: %@"), Self.describe(error)))
            }
        }
    }

    private static func describe(_ e: Error) -> String {
        if let s = e as? SftpError { return s.localizedDescription }
        let text = String(describing: e)
        if text.contains("allAuthenticationOptionsFailed") || text.contains("authentication") {
            return L("認証に失敗しました（公開鍵の登録・ユーザー名・パスワードを確認してください）")
        }
        if text.contains("hostKeyChanged") { return SftpError.hostKeyChanged("").localizedDescription }
        return (e as? LocalizedError)?.errorDescription ?? text
    }
}
