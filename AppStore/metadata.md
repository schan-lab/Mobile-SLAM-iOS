# App Store Connect 入力内容（Mobile SLAM 1.2）

## アプリ情報

| 項目 | 内容 |
|---|---|
| 名前 | Mobile SLAM |
| サブタイトル（30字以内） | LiDARで歩きながら3Dマップ作成 |
| バンドル ID | io.github.schan-lab.MobileSLAM |
| SKU | mobileslam-ios-1 |
| 主言語 | 日本語 |
| カテゴリ | ユーティリティ（サブ：仕事効率化） |
| 価格 | 無料 |
| 年齢制限 | 4+（質問はすべて「なし」） |
| リリース方法 | 手動（承認後に自分でリリース） |
| 配信地域 | フランスを除くすべての国または地域（1.2 から。暗号の申告書類が必要なため） |
| 著作権 | 2026 schan-lab |
| プライバシーポリシー URL | https://schan-lab.github.io/mobile-slam-support/privacy.html |
| サポート URL | https://schan-lab.github.io/mobile-slam-support/ |
| App のプライバシー | 「データの収集なし」 |
| 輸出コンプライアンス | 1.2 から暗号化あり（SFTP 送信の SSH、標準的な暗号化アルゴリズムのみ）。Info.plist にはキーを置かず、ビルドごとに ASC で回答（標準暗号を使用・フランスでは配信しない）。フランス配信には ANSSI への申告書類が必要 |
| 対応機種 | iPhone のみ（iOS 17 以上） |

## プロモーションテキスト（170字以内）

LiDAR を iPhone に有線でつなぐだけで、その場で 3D マップ作成と自己位置推定。PC も ROS も不要です。実機がなくても、デモモードで操作を試せます。

## 説明

Livox Mid-360 LiDAR を有線 LAN で iPhone に直結し、歩きながらその場で 3D マップを作るアプリです。PC も ROS も必要ありません。

■ できること
・ライブ表示：LiDAR の点群と IMU を受信して 3D で表示
・マップ作成（SLAM）：LiDAR と IMU を組み合わせたオドメトリで、歩きながら 3D マップを作成
・PCD 保存・閲覧：作ったマップを PCD ファイルで保存し、アプリ内で 3D 表示。ファイル App や共有シートから取り出せます
・自己位置推定：保存したマップに対して現在位置を推定。初期位置は地図をタッチして指定でき、省略すると自動で探索
・rosbag 記録：ROS 2 の bag（MCAP）で IMU と点群（点ごとのタイムスタンプ付き）を記録。ros2 bag play や Foxglove でそのまま開けます
・rosbag から SLAM：記録した bag や PC で記録した bag を再生しながらマップ作成・自己位置推定
・SFTP 送信：マップや bag を PC やサーバーへ送信。送信先は複数登録でき、鍵ペアはアプリ内で作成
・SLAM パラメータ：解像度やノイズなどを設定画面で調整
・Mid-360 のネットワーク設定：IP アドレスと送信先をアプリから確認・変更
・デモモード：実機がなくても、疑似データで一連の操作を試せます

■ 必要なもの
・Livox Mid-360 と電源（9〜27 V）
・iPhone / iPad 用の有線 LAN アダプター（USB-C、または Lightning - USB 3 カメラアダプタ経由）
・iPhone の Ethernet 設定で、Mid-360 に設定した送信先 IP アドレスを手動設定（工場出荷時は 192.168.1.50）

■ プライバシー
データの収集は一切行いません。マップや記録は iPhone 内に保存され、SFTP 送信を操作したときだけ、指定したサーバーへ送られます。

※ Livox および Mid-360 は各社の商標です。本アプリは Livox とは関係のない独立したアプリです。

## このバージョンの新機能（1.2）

・rosbag 記録：「● 記録」で ROS 2 の bag（MCAP）を保存できるようになりました。IMU と、点ごとのタイムスタンプ付き点群を記録します。待機中・マップ作成中・自己位置推定中のどの状態でも記録できます
・rosbag から SLAM：bag を再生しながらマップ作成・自己位置推定ができます（MCAP の無圧縮・zstd・lz4、PointCloud2 / Livox CustomMsg に対応）
・SFTP 送信：PCD や bag を PC・サーバーへ送れます。送信先は複数登録でき、アプリ内で作った鍵ペアの公開鍵をコピーして使えます
・SLAM の詳細パラメータを設定画面で変更できるようになりました

## キーワード（100字以内、カンマ区切り）

LiDAR,SLAM,3D,点群,マップ,地図,スキャン,PCD,自己位置推定,ロボット,測量,NDT,IMU,点群表示,ROS,rosbag,SFTP

## 審査メモ（App Review Information → Notes、英語）

This app connects to a Livox Mid-360 LiDAR sensor over a wired Ethernet adapter and builds a 3D map on the device (LiDAR-inertial SLAM). Because the sensor is special hardware, we provide two ways to review the app:

1. Demo mode (no hardware needed)
   - Open 設定 (Settings, top right) → turn on "実機なしで試す" (Try without hardware).
   - Go back. Synthetic sensor data of a room starts streaming; the status chips turn green.
   - Tap "▶ マップ作成 開始" (Start mapping). Keep the phone still for 3 seconds while it initializes; the map then builds automatically.
   - Tap "■ 停止" (Stop) → "PCD保存" (Save PCD). The map appears under "PCD ビューア" (PCD Viewer) and can be viewed in 3D.
   - Localization: switch to "自己位置推定", choose the saved map, then tap "▶ 自己位置推定 開始".

2. Video on real hardware
   - The attached video shows mapping, saving and localization with a real Mid-360 on an iPhone.

3. New in 1.2 (all work in demo mode)
   - rosbag recording: tap "● 記録" (Record) at any time, then tap it again ("■ … MB") to stop. A ROS 2 bag (.mcap) is saved.
   - Mapping from a rosbag: tap "rosbag" (top card), choose the recorded bag, then tap "▶ マップ作成 開始". The bag is replayed and mapped; it stops by itself at the end.
   - SFTP upload: Settings → SFTP → "キーペアを作成" (Create key pair) / "公開鍵をコピー" (Copy public key) and add a destination. Uploading needs an SSH server reachable from the device (any standard OpenSSH server with the copied public key in ~/.ssh/authorized_keys, or password login). Files are sent only to servers the user registers.
   - Advanced SLAM parameters: Settings → SLAM → "詳細パラメータ".

Local network permission is requested to receive UDP packets from the sensor and for SFTP uploads the user starts. The app collects no data and has no account or login. Encryption is used only for SSH/SFTP (standard algorithms).

## 添付・素材

- 審査用動画：`AppStore/review-video-small.mp4`（720p・音声なし・9MB。App Review Information → 添付ファイル。元の動画は `review-video.mov`。どちらも git には含めない）
- スクリーンショット（App Store Connect の必須サイズ：6.1／6.3インチ、1206×2622。6.9インチ版は `screenshots/6.9/`）
  - 日本語：`AppStore/screenshots/ja/`（01 実機でのマップ作成、02 実機での自己位置推定（一致 99%）、03 保存したマップの 3D 表示（デモ））
  - 英語：`AppStore/screenshots/en/`（01 デモでのマップ作成、02 保存したマップの 3D 表示（デモ））

---

# English (U.S.) localization

| Field | Value |
|---|---|
| Name | Mobile SLAM |
| Subtitle | 3D maps with a LiDAR, on foot |
| Privacy Policy URL | https://schan-lab.github.io/mobile-slam-support/privacy.html |
| Support URL | https://schan-lab.github.io/mobile-slam-support/ |

## Promotional Text

Plug a LiDAR into your iPhone over wired Ethernet and build 3D maps and localize on the spot — no PC or ROS required. No hardware? Try everything in demo mode.

## Description

Connect a Livox Mid-360 LiDAR to your iPhone with a wired Ethernet adapter and build 3D maps on the spot while you walk. No PC or ROS needed.

FEATURES
• Live view: receive the LiDAR point cloud and IMU data and view them in 3D
• Mapping (SLAM): build a 3D map as you walk, using LiDAR-inertial odometry
• Save and view PCD: save maps as PCD files and view them in 3D in the app; export them from the Files app or the share sheet
• Localization: estimate your position against a saved map. Tap the map to give a starting pose, or let the app search for it
• rosbag recording: record the IMU and point cloud (with per-point timestamps) as a ROS 2 bag (MCAP), ready for ros2 bag play and Foxglove
• SLAM from a rosbag: replay a recorded bag, or one made on a PC, to build maps and localize
• SFTP upload: send maps and bags to a PC or server; save several destinations and create the key pair in the app
• SLAM parameters: tune resolutions, noise and more in Settings
• Mid-360 network settings: view and change the sensor's IP address and data destination from the app
• Demo mode: try every step with simulated data, no hardware needed

REQUIREMENTS
• Livox Mid-360 and a 9–27 V power supply
• A wired Ethernet adapter for iPhone / iPad (USB-C, or via the Lightning to USB 3 Camera Adapter)
• In the iPhone's Ethernet settings, set the IP address manually to the Mid-360's destination (host) IP (192.168.1.50 by default)

PRIVACY
The app collects no data. Maps and recordings stay on your iPhone and are sent only to a server you choose when you use SFTP upload.

Livox and Mid-360 are trademarks of their respective owners. This app is independent and not affiliated with Livox.

## What's New in This Version (1.2)

• rosbag recording: "● Record" now saves a ROS 2 bag (MCAP) with the IMU and the point cloud with per-point timestamps — while idle, mapping or localizing
• SLAM from a rosbag: build maps and localize while replaying a bag (MCAP uncompressed / zstd / lz4, PointCloud2 or Livox CustomMsg)
• SFTP upload: send PCDs and bags to a PC or server; save several destinations and copy the public key of a key pair made in the app
• Advanced SLAM parameters in Settings

## Keywords

LiDAR,SLAM,3D,point cloud,mapping,scan,PCD,localization,robotics,survey,NDT,IMU,viewer,ROS,rosbag
