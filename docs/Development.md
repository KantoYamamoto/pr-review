# 開発・確認

[READMEに戻る](../README.md)

## プロジェクト構成

通常のXcode macOS Appプロジェクトとして、アプリとユニットテストの2ターゲットを用意しています。
Swift 6言語モードでデータ競合を検査し、Swift Subprocess 1.0.1を固定して利用します。
依存バージョンは `Package.resolved` に記録します。設計の詳細は [Architecture](Architecture.md) を参照してください。

```text
PRReview/
├── PRReview.xcodeproj/          # App・テスト・共有scheme・パッケージ定義
├── PRReview/
│   ├── PRReviewApp.swift        # ウィンドウ・終了時の処理
│   ├── ContentView.swift       # レビュー一覧・詳細
│   ├── SettingsViews.swift     # プロジェクト・コピー・ビルド設定
│   ├── ReviewModel.swift       # Observationによる画面状態
│   ├── MacIntegration.swift    # ファイル選択・Xcode起動
│   ├── Domain/                 # Sendableな保存モデル・保護理由
│   ├── Services/               # レビュー操作・保存・コピー・検出・ビルド
│   ├── Infrastructure/         # Git・GitHub・非同期コマンド・パス検証
│   └── Assets.xcassets/
├── PRReviewTests/               # 実Git・保存失敗・プロセス中断・実Xcode検証
├── docs/Architecture.md
└── scripts/bundle.sh
```

Info.plistはXcodeのビルド設定から自動生成します。
ローカルGitリポジトリとGit/ghを扱うため、App Sandboxは無効です。

`scripts/bundle.sh` はローカル用のad-hoc署名を行います。Developer ID署名・公証は行っていません。

## ビルドとテスト

```sh
xcodebuild -project PRReview.xcodeproj -scheme PRReview -configuration Debug -derivedDataPath .build/xcode build
xcodebuild -project PRReview.xcodeproj -scheme PRReview -destination 'platform=macOS' -derivedDataPath .build/xcode test
./scripts/bundle.sh
```

テストは一時Git repoと実際のworktreeを使用し、元の未コミット作業を保持した削除、
変更・未追跡・ignoredファイル・ローカルコミットがある環境の保護、
偽装した削除パスの拒否、保存状態の読み書きを検証します。
更新テストはローカルのbare repoにPR形式のrefを作り、fetchとcheckoutを実行。
GitHubのメタデータとoriginの識別だけを代替し、実際のGitHub通信は行いません。
Xcodeからは ⌘U で同じテストを実行できます。
Swift Testingでコマンドのstdout/stderr・中断時の子プロセス終了、ビルドの引数・安全な成果物管理も検証します。
実Xcode統合テストは一時的な最小プロジェクトをビルド・テストして削除まで確認します。ネットワークやSimulatorは使用しません。
