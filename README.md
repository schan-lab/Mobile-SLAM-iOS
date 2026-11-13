# Mobile SLAM for iPhone

Livox Mid-360 を iPhone に有線 LAN で直結し、
その場で 3D マップの作成（LIO）と、保存したマップに対する自己位置推定（NDT）を行います。

SLAM 本体（`core/`）は C++17 + Eigen で書いています。

## 必要なもの

| | |
|---|---|
| iPhone | iOS 17 以上。USB-C の iPhone（15 以降）か、Lightning の場合は「Lightning - USB 3 カメラアダプタ」 |
| LiDAR | Livox Mid-360 |
| 接続 | USB-C（または USB-A）の有線 LAN アダプター、Mid-360 の電源（9–27 V） |
| 開発 | Mac + Xcode 16 以上（プロジェクトは Xcode 16 の同期フォルダ形式） |

## 使い方

1. **iPhone の有線 LAN を固定 IP にする**
   LAN アダプターを挿すと「設定」に「Ethernet」が出ます。設定 → Ethernet → (アダプター名) → IP を構成 → 手動 で、
   IP アドレス `192.168.1.50`、サブネットマスク `255.255.255.0` にします（Mid-360 の工場出荷時の送信先）。
2. **アプリを起動して「ローカルネットワーク」へのアクセスを許可**する。拒否すると点群を受信できません
   （あとから 設定 → プライバシーとセキュリティ → ローカルネットワーク で変更できます）。
3. Mid-360 をつないで電源を入れ、画面上部の `Ethernet`、`Mid-360`、`IMU` が緑になれば受信できています。
4. マップ作成 → 停止 → PCD 保存で地図ができます。保存した地図を読み込めば自己位置推定もできます。

保存した PCD と生データは、ファイル App の「このiPhone内 › Mobile SLAM」から取り出せます
（生データは `raw/` に保存され、iCloud バックアップの対象外です）。

## ビルド

```sh
git clone https://github.com/schan-lab/Mobile-SLAM-iOS.git
cd Mobile-SLAM-iOS
open MobileSLAM.xcodeproj
```

Xcode でターゲット MobileSLAM の Signing & Capabilities で自分の Team を選び、iPhone を選んで ▶ で実行します。

## 実機なしでの動作確認

`tools/mid360_sim.cpp` は、部屋をスキャンしながら動く Mid-360 を模した UDP パケット（点群 + IMU）を送ります。
iOS シミュレータは Mac のネットワークを使うので、これで受信から SLAM・描画まで一通り確認できます。

```sh
clang++ -std=c++17 -O2 tools/mid360_sim.cpp -o /tmp/mid360_sim
xcrun simctl launch booted io.github.schan-lab.MobileSLAM -autoStartMapping   # Debug ビルドのみ有効
/tmp/mid360_sim 127.0.0.1 40
```

## 中身

```
MobileSLAM/
  Bridge/        C API（SlamBridge.h）：SLAM エンジンのスレッド、PCD 読み込み、パケット解析
  Core/          受信（BSD ソケット）、アプリ状態、設定、ファイル管理
  Rendering/     Metal による点群描画とカメラ操作
  Views/         SwiftUI の画面
  PrivacyInfo.xcprivacy   プライバシーマニフェスト
Config/Info.plist         ローカルネットワークの利用目的など
tools/                    疑似 Mid-360
core/                     SLAM 本体（LIO・NDT）
third_party/eigen/        Eigen 3.4.0（ヘッダのみ）
```

## App Store 公開について

- データの収集・送信・トラッキングは一切なし（プライバシーマニフェストで申告済み。App Store Connect の
  「App のプライバシー」は「データの収集なし」を選択）。
- 標準の暗号化以外は使っていないため `ITSAppUsesNonExemptEncryption = NO`。
- 第三者ライセンス（Eigen / MPL 2.0）は アプリ内の 設定 → このアプリについて・ライセンス に表示。
- Mid-360 がないと主要機能を試せないため、審査提出時は App Review の「メモ」に**実機での動作動画の URL** を添えてください
  （App Review Guidelines 2.1：特別なハードウェアが必要なアプリ）。
- App Store Connect ではプライバシーポリシーの URL が必須です。内容は「個人情報を収集しない」旨で足ります。

## ライセンス

[MIT License](LICENSE)。第三者ソフトウェアは [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) を参照。
