import SwiftUI

/// App information, privacy statement and third-party licenses.
struct AboutView: View {
    private var version: String {
        let i = Bundle.main.infoDictionary
        return "\(i?["CFBundleShortVersionString"] as? String ?? "-") (\(i?["CFBundleVersion"] as? String ?? "-"))"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                block("Mobile SLAM", String(format: L("バージョン %@"), version) + "\n" +
                      L("Livox Mid-360 を有線 LAN でつなぎ、その場で 3D マップの作成と自己位置推定を行います。"))
                block(L("プライバシー"),
                      String(format: L("このアプリは個人情報や利用状況を一切収集しません。ネットワークは、有線 LAN でつないだ LiDAR からデータを受信するためと、あなたが指定したサーバーへ SFTP でファイルを送るためだけに使います。作成したマップや記録はこの %1$@ 内（ファイル App の「この%1$@内 › Mobile SLAM」）に保存され、あなたが SFTP 送信や共有をしたときだけ、その送信先に送られます。"), Device.name))
                block(L("実装について"),
                      L("LiDAR-IMU オドメトリは FAST-LIO（W. Xu, F. Zhang, RA-L 2021）の定式化に沿った独自実装です。Mid-360 との通信は公開されているプロトコルを独自に実装しており、Livox SDK は使っていません。"))
                block(L("ライセンス: Mobile SLAM (MIT License)"), Self.mit, mono: true)
                block(L("ライセンス: Eigen 3.4.0 (Mozilla Public License 2.0)"),
                      "Eigen is licensed under the MPL 2.0. A copy of the license is available at " +
                      "https://mozilla.org/MPL/2.0/ and the unmodified source code at https://gitlab.com/libeigen/eigen " +
                      "(tag 3.4.0). Built with EIGEN_MPL2_ONLY.", mono: true)
                block(L("ライセンス: その他のオープンソース"), Self.thirdParty, mono: true)
            }
            .padding(12)
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.bg)
        .navigationTitle("このアプリについて")
    }

    private func block(_ title: String, _ text: String, mono: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.text)
            Text(text)
                .font(mono ? .system(size: 11, design: .monospaced) : .system(size: 13))
                .foregroundStyle(Theme.textDim)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 14)
    }

    /// zstd, lz4, Citadel (SSH / SFTP) and its dependencies (bundled ThirdPartyLicenses.txt).
    static let thirdParty: String = {
        guard let url = Bundle.main.url(forResource: "ThirdPartyLicenses", withExtension: "txt"),
              let s = try? String(contentsOf: url, encoding: .utf8) else { return "-" }
        return s
    }()

    static let mit = """
    MIT License

    Copyright (c) 2026 schan-lab

    Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated \
    documentation files (the "Software"), to deal in the Software without restriction, including without limitation \
    the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and \
    to permit persons to whom the Software is furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all copies or substantial portions \
    of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO \
    THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE \
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF \
    CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER \
    DEALINGS IN THE SOFTWARE.
    """
}
