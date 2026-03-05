Open Wallpaper Engine（パッチ版）
=========

[English](README.md) | [繁體中文](README.zh-TW.md) | **日本語**

[![GitHub license](https://img.shields.io/badge/license-GPL--3.0-blue.svg)](LICENSE)

[Open Wallpaper Engine](https://github.com/MrWindDog/wallpaper-engine-mac) のパッチフォークです。macOS 向けにシーン壁紙のレンダリングと Web 壁紙の修正を追加しています。

> **注意：** 本プロジェクトは Steam の商用版 Wallpaper Engine とは無関係です。Steam Workshop の壁紙アセットを表示できるオープンソースの macOS アプリケーションです。

## クレジット

本プロジェクトは以下の貢献者の成果に基づいています：

- **[MrWindDog](https://github.com/MrWindDog)** — 上流 [wallpaper-engine-mac](https://github.com/MrWindDog/wallpaper-engine-mac) フォークのメンテナー、新機能と UI 改善を追加
- **[Haren Chen](https://github.com/haren724)** — [open-wallpaper-engine-mac](https://github.com/haren724/open-wallpaper-engine-mac) のオリジナル作者、コアアーキテクチャを構築（SwiftUI、動画壁紙再生、インポートシステム、プレイリスト UI）
- **[1ris_W](https://github.com/Erica-Iris)** — 中国語 i18n 翻訳
- **[Klaus Zhu](https://github.com/klauszhu1105)** — アプリロゴアイコン
- **[Chen Chia Yang](https://github.com/Unayung)** — シーン壁紙レンダリング、Web 壁紙修正、Steam Workshop 統合、マルチディスプレイ対応、Zip インポート

[GPL-3.0](LICENSE) ライセンス（オリジナルプロジェクトと同一）。

## 0.8.0 の新機能

### マルチディスプレイ対応
接続された各モニターに異なる壁紙を割り当て、画面ごとに有効/無効を制御できます。
- **ディスプレイ設定パネル** — 接続されたすべての画面をビジュアルレイアウトで表示、クリックで選択
- **画面ごとの壁紙** — 各ディスプレイで異なる壁紙を独立して表示
- **有効/無効トグル** — モニターごとに壁紙のオン/オフを切り替え
- **自動検出** — 新しいモニターは接続時に自動的に検出・有効化

### 再生設定 — 修正済み
パフォーマンス再生設定（他のアプリがフォーカスされた時の一時停止/ミュート/停止）がすべての壁紙タイプで正しく動作するようになりました。

### Steam Workshop ブラウザ
アプリ内から直接 Steam Workshop の壁紙を閲覧、検索、ダウンロードできます。
- **検索とフィルター** — 名前で検索、コンテンツレーティング（Everyone/Questionable/Mature）、タイプ（Scene/Video/Web）、ジャンルタグでフィルター
- **ソートオプション** — トレンド、最新、人気順、サブスクライブ数順
- **steamcmd 統合** — steamcmd を自動検出（Homebrew またはカスタムパス）、未インストール時はインストール手順を表示
- **Steam ログイン** — パスワード、Steam Guard、キャッシュセッション認証に対応
- **ダウンロード進捗表示** — リアルタイムステータス更新（認証中、ダウンロード %、検証、コピー中）
- **安全なデフォルト** — コンテンツレーティングを「Everyone」に設定し、成人向けコンテンツをフィルタリング

### Zip インポート
`.zip` ファイルから壁紙パッケージを直接インポート。手動解凍は不要です。ファイル > インポートおよびドラッグ＆ドロップに対応。

### 複数選択と一括解除
Cmd+クリックで複数の壁紙を選択し、右クリックで一括サブスクライブ解除。

### 壁紙ストレージの分離
壁紙は `~/Documents/Open Wallpaper Engine/` に保存されるようになり、Documents ディレクトリを直接使用しなくなりました。リポジトリをクローンした際の「error」壁紙を防止します。

## パッチ内容

### Web 壁紙 — グレー/空白レンダリングの修正
WebGL ベースの壁紙は `WKWebView` がローカルファイルアクセスをブロックしていたため、グレーの矩形として表示されていました。

**修正：** WKWebView 設定で `allowFileAccessFromFileURLs` と `allowUniversalAccessFromFileURLs` を有効にし、WebGL シェーダーがローカルテクスチャファイルを読み込めるようにしました。

### シーン壁紙 — ゼロから実装
シーン壁紙（Steam Workshop で最も一般的なタイプ）は完全に未実装で、「Hello, World!」のみ表示されていました。

**新しい実装：**
- **PKG パーサー** — Wallpaper Engine の PKGV アーカイブ形式を読み取り、scene.json、モデル、マテリアル、テクスチャを抽出
- **TEX パーサー** — TEXV0005 テクスチャコンテナを読み取り、TEXI/TEXB セクションから埋め込み JPEG/PNG 画像を抽出
- **Scene JSON デコーダー** — scene.json を解析、ポリモーフィックフィールド（値がプレーンタイプまたは `{"script":..,"value":..}` オブジェクト）を柔軟に処理
- **SpriteKit レンダラー** — シーン画像レイヤーを SKSpriteNode としてレンダリング、位置、サイズ、アルファ、カラーティント、ブレンドモードを正確に処理
- **プレビューフォールバック** — テクスチャを抽出できない場合は preview.jpg/png/gif にフォールバック
- **TEXI 形式検出** — デコードできない DXT 圧縮テクスチャを迅速に識別してスキップ

### インポート — フォルダインポートの修正
インポートパネルが個別の壁紙フォルダと複数の壁紙を含む親ディレクトリの両方を正しく処理するようになりました。

## 現在の制限事項

- **DXT テクスチャ** — DXT1/DXT5 圧縮テクスチャ（TEXI 形式 4/7/8）を使用する壁紙はレンダリングできません。ソフトウェアデコンプレッサーまたは Metal ベースのレンダリングが必要な GPU ネイティブ圧縮形式です。プレビュー画像にフォールバックします。
- **パーティクルエフェクト** — シーンパーティクルシステム（雨、雪、スパークル）は解析されますが、視覚的な問題を避けるためレンダリングで無効化されています。
- **オーディオリアクティブスクリプト** — Wallpaper Engine の JavaScript ベースのオーディオ視覚化スクリプトは実行されません。スクリプト付きプロパティは静的な `value` にフォールバックします。
- **シェーダーエフェクト** — カスタム GLSL シェーダー（ブルーム、ブラー、カラー補正）は適用されません。
- **カメラパララックス** — マウス追従カメラ移動は未実装です。
- **アニメーションシーン** — スプライトアニメーションとタイムラインベースのオブジェクトアニメーションはサポートされていません。
- **一部の JPEG サムネイル** — 少数の TEXB 形式 1 ファイルに macOS がデコードできない非標準 JPEG データが含まれています。

## サポートされている壁紙タイプ

| タイプ | ステータス |
|--------|------------|
| 動画 (.mp4, .webm) | 動作中（オリジナル） |
| Web (HTML/WebGL) | 動作中（パッチ済み） |
| シーン（静的画像） | 動作中（新機能） |
| シーン（パーティクル） | 部分対応（無効化） |
| シーン（DXT テクスチャ） | プレビューフォールバック |
| アプリケーション | 未サポート |

## ソースからビルド

### 前提条件
- macOS >= 13.0
- Xcode >= 14.4
- Xcode Command Line Tools

### 手順
```sh
git clone https://github.com/unayung/wallpaper-engine-mac
cd wallpaper-engine-mac
open "Open Wallpaper Engine.xcodeproj"
```

Xcode で署名証明書を自分のものに変更するか「Sign to Run Locally」を選択し、`Cmd + R` でビルド・実行します。

## 使い方

### Steam Workshop から閲覧・ダウンロード

1. steamcmd をインストール（`brew install steamcmd`）するか、既存のバイナリを指定
2. **Workshop** タブに切り替え、Steam アカウントでログイン（Wallpaper Engine の所有が必要）
3. プロンプトが表示されたら [Steam Web API キー](https://steamcommunity.com/dev/apikey) を入力
4. 検索、フィルターし、**Download** をクリックして壁紙をダウンロード

### ローカルファイルからインポート

- **フォルダ：** ファイル > フォルダからインポート — `project.json` を含む壁紙フォルダを選択
- **Zip：** ファイル > インポート またはドラッグ＆ドロップで `.zip` ファイルを読み込み
- **手動：** 壁紙フォルダを `~/Documents/Open Wallpaper Engine/` に直接コピー

## 変更ファイル（上流との差分）

**変更：**
- `WebWallpaperView.swift` — WKWebView ファイルアクセス設定
- `WallpaperView.swift` — シーン壁紙ディスパッチ
- `SceneWallpaperView.swift` — SpriteKit NSViewRepresentable に書き換え
- `ImportPanels.swift` — フォルダインポートロジック修正

**追加：**
- `Services/SceneParsers/PKGParser.swift` — PKGV アーカイブパーサー
- `Services/SceneParsers/TEXParser.swift` — TEXV テクスチャパーサー
- `Services/SceneParsers/SceneModels.swift` — Scene JSON データモデル
- `Services/SceneWallpaperViewModel.swift` — シーン読み込みと SpriteKit レンダリング
- `Services/SteamCmdService.swift` — steamcmd 検出、ログイン、Workshop ダウンロード
- `Services/WorkshopAPIService.swift` — Steam Web API クライアント
- `Services/WorkshopViewModel.swift` — Workshop ブラウザ状態管理
- `Services/WallpaperDirectory.swift` — 集中壁紙ストレージパス
- `Services/ZipImporter.swift` — Zip ファイル解凍とインポート
- `ContentView/Components/WorkshopView.swift` — Workshop ブラウザ UI
