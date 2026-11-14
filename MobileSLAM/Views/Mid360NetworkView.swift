import SwiftUI

/// Reads / changes the Mid-360's IP address and the destination (this iPhone) of its data.
struct Mid360NetworkView: View {
    @EnvironmentObject var model: AppModel

    @State private var currentIP = ""
    @State private var lidarIP = ""
    @State private var mask = "255.255.255.0"
    @State private var gateway = ""
    @State private var hostIP = ""
    @State private var busy = false
    @State private var message: (String, Bool)?   // text, isError
    @State private var confirm = false
    @State private var loaded = false

    private var iphone: (ip: String, mask: String)? { model.receiver.ethIPv4.first }
    private var changesLidarIP: Bool { lidarIP.trimmed != currentIP.trimmed }
    private var allValid: Bool {
        [currentIP, lidarIP, mask, gateway, hostIP].allSatisfy { (try? Mid360Config.ipBytes($0)) != nil }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                card(L("接続状況")) {
                    row(String(format: L("%@ の有線 LAN"), Device.name), iphone.map { "\($0.ip) / \($0.mask)" } ?? L("未接続"))
                    row(L("検出した Mid-360"), detectedIP.isEmpty ? L("未検出") : detectedIP)
                    if model.demoMode {
                        note(L("デモモードがオンです。実機の設定を変えるには、設定画面でデモをオフにしてください。"), Theme.orange)
                    }
                }
                card(L("現在の Mid-360")) {
                    field(L("Mid-360 の IP アドレス"), $currentIP)
                    note(String(format: L("いまの Mid-360 の IP です。点群を受信中なら自動で入ります。%@ の IP がこのアドレスと同じサブネットにないと設定できません。"), Device.name))
                    PillButton(label: L("現在の設定を読み込む"), color: Theme.grey, height: 40, fontSize: 14,
                               enabled: !busy && (try? Mid360Config.ipBytes(currentIP)) != nil) { load() }
                }
                card(L("新しい設定")) {
                    field(L("Mid-360 の IP アドレス"), $lidarIP)
                    field(L("サブネットマスク"), $mask)
                    field(L("ゲートウェイ"), $gateway)
                    field(String(format: L("送信先 IP アドレス（この %@）"), Device.name), $hostIP)
                    if allValid && !Mid360Config.sameSubnet(lidarIP, hostIP, mask: mask) {
                        note(L("送信先 IP が Mid-360 の IP と同じサブネットにありません。"), Theme.orange)
                    }
                    if allValid && lidarIP.trimmed == hostIP.trimmed {
                        note(L("Mid-360 と送信先に同じ IP は使えません。"), Theme.red)
                    }
                    note(changesLidarIP
                         ? L("Mid-360 の IP を変えると、書き込み後に Mid-360 が再起動します（十数秒）。")
                         : L("送信先だけを変える場合、再起動なしですぐに反映されます。"))
                    PillButton(label: busy ? L("通信中…") : L("Mid-360 に書き込む"), color: Theme.accent,
                               enabled: !busy && !model.demoMode && allValid && lidarIP.trimmed != hostIP.trimmed) {
                        confirm = true
                    }
                }
                if let (text, isError) = message {
                    Text(text)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(isError ? Theme.red : Theme.green)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .card(padding: 14)
                }
                note(L("設定は Mid-360 本体に保存され、電源を切っても残ります。わからなくなった場合は、Livox Viewer 2 などで工場出荷時の設定（Mid-360: 192.168.1.1XX、送信先: 192.168.1.50）に戻せます。"))
            }
            .padding(12)
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.bg)
        .navigationTitle("Mid-360 のネットワーク")
        .onAppear(perform: prefill)
        .confirmationDialog(L("Mid-360 の設定を変更しますか？"), isPresented: $confirm, titleVisibility: .visible) {
            Button(L("書き込む")) { write() }
            Button(L("キャンセル"), role: .cancel) {}
        } message: {
            Text(String(format: L("Mid-360: %@ → %@\n送信先: %@"), currentIP.trimmed, lidarIP.trimmed, hostIP.trimmed))
        }
    }

    private var detectedIP: String {
        let c = model.receiver.counters
        if c.lidarSrc != "-" && c.lidarSrc != "127.0.0.1" { return c.lidarSrc }
        return c.detectedIP
    }

    private func prefill() {
        guard !loaded else { return }
        loaded = true
        model.receiver.refreshInterfaces()
        currentIP = detectedIP
        lidarIP = detectedIP
        if let i = iphone {
            hostIP = i.ip
            mask = i.mask
        }
        if !currentIP.isEmpty { load() }
    }

    private func load() {
        let ip = currentIP.trimmed
        busy = true
        message = nil
        Task.detached {
            let r = Result { try Mid360Config.read(lidarIP: ip) }
            await MainActor.run {
                busy = false
                switch r {
                case .success(let n):
                    lidarIP = n.lidarIP
                    mask = n.mask
                    gateway = n.gateway
                    if hostIP.isEmpty { hostIP = n.hostIP }
                    message = (String(format: L("読み込みました。現在の送信先は %@ です。"), n.hostIP), false)
                case .failure(let e):
                    message = (e.localizedDescription, true)
                }
            }
        }
    }

    private func write() {
        let cur = currentIP.trimmed
        let net = Mid360Config.Network(lidarIP: lidarIP.trimmed, mask: mask.trimmed, gateway: gateway.trimmed,
                                       hostIP: hostIP.trimmed)
        let change = changesLidarIP
        busy = true
        message = nil
        Task.detached {
            let r = Result { try Mid360Config.write(currentLidarIP: cur, to: net, changeLidarIP: change) }
            await MainActor.run {
                busy = false
                switch r {
                case .success(let rebooted):
                    var s = rebooted ? L("書き込みました。Mid-360 を再起動しています。") : L("書き込みました。")
                    if let i = iphone, i.ip != net.hostIP || !Mid360Config.sameSubnet(i.ip, net.lidarIP, mask: i.mask) {
                        s += "\n" + String(format: L("%1$@ の 設定 → Ethernet → IP を構成 → 手動 で、IP アドレスを %2$@、サブネットマスクを %3$@ にしてください。"), Device.name,
                                          net.hostIP, net.mask)
                    }
                    message = (s, false)
                    currentIP = net.lidarIP
                case .failure(let e):
                    message = (e.localizedDescription, true)
                }
            }
        }
    }

    // ------------------------------------------------------------------ pieces

    private func card<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.textDim)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 14)
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(.system(size: 14)).foregroundStyle(Theme.textDim)
            Spacer()
            Text(v).font(.system(size: 14, weight: .semibold, design: v.first?.isNumber == true ? .monospaced : .default)).foregroundStyle(Theme.text)
        }
    }

    private func field(_ label: String, _ text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.text)
            TextField("0.0.0.0", text: Binding(get: { text.wrappedValue },
                                               set: { text.wrappedValue = Mid360Config.normalize($0) }))
                .keyboardType(.decimalPad)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(size: 16, design: .monospaced))
                .foregroundStyle((try? Mid360Config.ipBytes(text.wrappedValue)) == nil ? Theme.red : Theme.text)
                .padding(.horizontal, 10).frame(height: 40)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))
        }
    }

    private func note(_ s: String, _ color: Color = Theme.textDim) -> some View {
        Text(s).font(.system(size: 12)).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
    }
}

private extension String {
    var trimmed: String { Mid360Config.normalize(self) }
}
