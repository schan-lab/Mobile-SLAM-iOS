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
   Mid-360 に設定してある送信先（ホスト）IP と、Mid-360 と同じサブネットのマスクにします。
   工場出荷時なら IP アドレス `192.168.1.50`、サブネットマスク `255.255.255.0`。
   Mid-360 の IP・送信先を変更している場合は、その値に合わせてください（受信はすべてのインターフェースで行うので、
   アプリ側の受信設定は不要です）。
   Mid-360 の IP や送信先そのものは、アプリの 設定 → Mid-360 → IP アドレスと送信先 で読み出し・変更できます
   （Livox SDK2 の制御プロトコル 0x0101 / 0x0100、IP 変更時は 0x0200 で再起動。変更には、iPhone が Mid-360 の
   現在の IP と同じサブネットにある必要があります）。
2. **アプリを起動して「ローカルネットワーク」へのアクセスを許可**する。拒否すると点群を受信できません
   （あとから 設定 → プライバシーとセキュリティ → ローカルネットワーク で変更できます）。
3. Mid-360 をつないで電源を入れ、画面上部の `Ethernet`、`Mid-360`、`IMU` が緑になれば受信できています。
4. マップ作成 → 停止 → PCD 保存で地図ができます。保存した地図を読み込めば自己位置推定もできます。

保存した PCD と記録は、ファイル App の「このiPhone内 › Mobile SLAM」から取り出せます
（記録は `raw/` に保存され、iCloud バックアップの対象外です）。

## rosbag（ROS 2 / MCAP）

- **記録**: 「● 記録」で ROS 2 bag（MCAP、無圧縮）を保存します。待機中（ライブ表示だけ）・マップ作成中・自己位置推定中の
  どの状態でも記録でき、記録の開始・停止は SLAM に影響しません。トピックは livox_ros_driver2 と同じです。
  - `/livox/imu` `sensor_msgs/msg/Imu`（角速度 rad/s、加速度 m/s²、`orientation_covariance[0] = -1`）
  - `/livox/lidar` `sensor_msgs/msg/PointCloud2`（10 Hz、フィールド `x y z intensity`(f32) `tag line`(u8)
    `timestamp`(f64, 点ごとの絶対時刻 ns)、point_step 26）
  - frame_id は `livox_frame`。Mid-360 の時計が未同期（起動からの時間）のときは、記録開始時に iPhone の時計へ合わせます。
  - `ros2 bag play` / `ros2 bag info` / Foxglove でそのまま開けます。設定 → rosbag で生パケット形式にも戻せます。
- **rosbag から SLAM**: 「rosbag」ボタンで bag を選んで開始すると、bag を実時間（0.5 / 1 / 2 倍速）で再生しながら
  マップ作成・自己位置推定をします。読める形式は MCAP（無圧縮・zstd・lz4）で、LiDAR は `PointCloud2`
  （点ごとの時刻フィールド `timestamp` / `time` / `t` などに対応）か Livox `CustomMsg`、IMU は `sensor_msgs/Imu`
  （m/s² と g を自動判別）です。トピックは型と名前から自動で選びます。sqlite3（.db3）の bag は未対応です。
- 再生した点群は Mid-360 のパケット形式に変換して実機と同じ経路に流すため、LiDAR→IMU の外部パラメータは
  設定 → SLAM → 詳細パラメータ で合わせてください（規定値は Mid-360 内蔵 IMU）。

## SFTP 送信

PCD ビューア・rosbag の一覧で左スワイプか長押し → 「SFTP で送信」。送信先（ホスト・ポート・ユーザー・転送先パス）は
設定 → SFTP で複数登録できます。認証はアプリ内で作る Ed25519 キーペア（秘密鍵はキーチェーンのみ、公開鍵はコピーして
`~/.ssh/authorized_keys` に追加）かパスワードです。ホスト鍵は最初の接続時に記憶し、変わったら送信しません。
SSH/SFTP には [Citadel](https://github.com/orlandos-nl/Citadel)（SwiftPM、0.12.0 固定）を使っています。

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
clang++ -std=c++17 -O2 -IMobileSLAM/Bridge tools/mid360_sim.cpp -o /tmp/mid360_sim
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
tools/                    疑似 Mid-360、UI テスト用のサーバー
core/                     SLAM 本体（LIO・NDT）
third_party/eigen/        Eigen 3.4.0（ヘッダのみ）
third_party/zstd/, lz4/   MCAP チャンクの展開用
```

## デモモード

設定 → 「実機なしで試す」をオンにすると、アプリ内で疑似 Mid-360（`MobileSLAM/Bridge/Mid360Synth.hpp`）の点群が流れ、
実機なしでマップ作成・保存・自己位置推定を一通り試せます（App Review 向けでもあります）。

## ローカライズ

日本語（開発言語）と英語に対応しています。UI 文字列は `MobileSLAM/Localizable.xcstrings`、
Info.plist の文言は `MobileSLAM/InfoPlist.xcstrings` にあります。コードでは `Text("日本語")` か `L("日本語")` を使い、
数値は `String(format: L("… %@ …"), …)` で埋め込みます。

## App Store 公開について

掲載情報・審査メモの原稿は `AppStore/metadata.md`、スクリーンショットは `AppStore/screenshots/`、
サポート・プライバシーポリシーのページは `AppStore/pages/` にあります。


- データの収集・送信・トラッキングは一切なし（プライバシーマニフェストで申告済み。App Store Connect の
  「App のプライバシー」は「データの収集なし」を選択）。
- 標準の暗号化以外は使っていないため `ITSAppUsesNonExemptEncryption = NO`。
- 第三者ライセンス（Eigen / MPL 2.0）は アプリ内の 設定 → このアプリについて・ライセンス に表示。
- Mid-360 がないと主要機能を試せないため、審査提出時は App Review の「メモ」に**実機での動作動画の URL** を添えてください
  （App Review Guidelines 2.1：特別なハードウェアが必要なアプリ）。
- App Store Connect ではプライバシーポリシーの URL が必須です。内容は「個人情報を収集しない」旨で足ります。

## ライセンス

[MIT License](LICENSE)。第三者ソフトウェアは [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) を参照。
