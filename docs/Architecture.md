# Architecture

最低対応はmacOS 26、Swift 6言語モード。AppKitの操作と画面状態はMainActor、
Git・ハッシュ計算・コピー・ビルドは非同期サービスで扱います。macOS 27専用APIには依存しません。

## 責任の分担

- **ReviewModel**: 入力・選択・シート・表示ログ・実行Taskの寿命。保存データは直接変更しません。
- **ReviewCoordinator**: 登録、作成、更新、終了、ビルド結果の保存。状態変更・保存・復旧の順序と排他を管理します。
- **ReviewService**: Git worktreeの操作と保護検証。検出・コピー・worktreeは関連するextensionへ分割しています。
- **StateStore**: Codable JSONの読み込みとatomicな保存。破損済みファイルは上書きしません。
- **GitClient / GitHubClient**: Gitのliteral引数・hook無効化、GitHubメタデータの取得。
- **RepositoryFileSafety**: 相対パス、Git内部、シンボリックリンクの検証を共有します。
- **CommandRunner**: Swift Subprocessによる非同期実行、stdout/stderrの分離、ログ配信、プロセスグループの終了。
- **XcodeBuildService**: Scheme・実行先、xcodebuild、専用成果物の保存・削除。
- **MacIntegration**: 非同期のNSOpenPanelとXcode起動。ドメインやサービスから画面を開きません。

## 操作と保存

Coordinatorの明示的なgateをawaitの前後で保持します。MainActorやactorだけでは、
await中の別操作の割り込みを防げないためです。現在はアプリ全体で1操作です。
別レビューの並列ビルドが必要になった段階で、この境界をセッション単位へ拡張できます。

- 作成: ファイルの事前検証 → fetch → worktree → コピー → 状態保存。
  保存失敗時は環境を一覧に残し、再保存を案内します。
- 更新: 状態・変更確認 → fetch → 再確認 → 安全なcheckout → 状態保存。
  保存失敗時は編集の有無を再確認して元SHAへ復帰します。復帰失敗も環境を保持して表示します。
- 終了: 保護検証 → 非強制のworktree削除 → 一覧から除去 → 状態保存・専用成果物の削除。
  worktree削除失敗時はコピーと成果物を残します。削除成功後の保存失敗は再保存できます。
- ビルド: HEAD・保護検証 → 明示実行 → ログを閉じる → 再検証 → 結果保存。
  更新で過去の結果は消さず、SHAの違いを画面で示します。

Git変更操作は途中のキャンセルで未整合状態を残さないよう、保持・awaitしたTaskで
保存・復旧まで完了させます。ビルドは中断可能で、子プロセス終了後に中断結果を保存します。
アプリ終了時もTaskの完了を待ちます。突然の強制終了やOSクラッシュの完全復旧は保証しません。

## 依存と検証

外部依存はSwift Subprocessの固定バージョンとそのSwift System依存。
パッケージ更新は既存のNUL区切り出力・stderr分離・子プロセス終了のテストを通してから行います。

既存のXCTestは実Gitの保護動作を維持し、新しい非同期操作にはSwift Testingを使います。
コマンドと保存の境界だけ注入可能にして、保存失敗・ロールバック・実行中断を再現します。
実Xcodeテストは独立した一時プロジェクトを使い、ユーザーのリポジトリやSimulatorには触れません。
