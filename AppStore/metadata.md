# App Store Connect 入力内容（Mobile SLAM 1.0）

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
| 配信地域 | すべての国または地域（175） |
| 著作権 | 2026 schan-lab |
| プライバシーポリシー URL | https://schan-lab.github.io/mobile-slam-support/privacy.html |
| サポート URL | https://schan-lab.github.io/mobile-slam-support/ |
| App のプライバシー | 「データの収集なし」 |
| 輸出コンプライアンス | Info.plist で申告済み（暗号化なし） |
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
・生データ記録：受信したパケットをそのまま保存
・Mid-360 のネットワーク設定：IP アドレスと送信先をアプリから確認・変更
・デモモード：実機がなくても、疑似データで一連の操作を試せます

■ 必要なもの
・Livox Mid-360 と電源（9〜27 V）
・iPhone / iPad 用の有線 LAN アダプター（USB-C、または Lightning - USB 3 カメラアダプタ経由）
・iPhone の Ethernet 設定で、Mid-360 に設定した送信先 IP アドレスを手動設定（工場出荷時は 192.168.1.50）

■ プライバシー
データの収集は一切行いません。マップや記録は iPhone 内に保存され、SFTP 送信を操作したときだけ、指定したサーバーへ送られます。

※ Livox および Mid-360 は各社の商標です。本アプリは Livox とは関係のない独立したアプリです。

## キーワード（100字以内、カンマ区切り）

LiDAR,SLAM,3D,点群,マップ,地図,スキャン,PCD,自己位置推定,ロボット,測量,NDT,IMU,点群表示

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

Local network permission is requested only to receive UDP packets from the sensor. The app collects no data and has no account or login.

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
• Raw recording: save the received packets as they are
• Mid-360 network settings: view and change the sensor's IP address and data destination from the app
• Demo mode: try every step with simulated data, no hardware needed

REQUIREMENTS
• Livox Mid-360 and a 9–27 V power supply
• A wired Ethernet adapter for iPhone / iPad (USB-C, or via the Lightning to USB 3 Camera Adapter)
• In the iPhone's Ethernet settings, set the IP address manually to the Mid-360's destination (host) IP (192.168.1.50 by default)

PRIVACY
The app collects no data. Maps and recordings stay on your iPhone and are sent only to a server you choose when you use SFTP upload.

Livox and Mid-360 are trademarks of their respective owners. This app is independent and not affiliated with Livox.

## Keywords

LiDAR,SLAM,3D,point cloud,mapping,scan,PCD,localization,robotics,survey,NDT,IMU,viewer
