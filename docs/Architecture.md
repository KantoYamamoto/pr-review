# Architecture

macOS 26以降、Swift 6言語モードで動作します。画面状態とAppKitの操作はMainActor、
Git・ハッシュ計算・コピー・ビルドは非同期サービスで扱います。

## 変更箇所の探し方

| 変更したいこと | 主な担当 |
|---|---|
| レビューの開始・更新・終了、保存失敗からの復旧 | `ReviewCoordinator` |
| worktreeのGit操作、変更・ローカルコミットの保護 | `ReviewService` / `ReviewWorktrees` |
| 設定コピーの検証・書き込み・変更検出 | `ConfigurationCopies` |
| Xcodeプロジェクトの候補検出 | `XcodeProjectDiscovery` |
| Xcodeプロジェクトを受け付ける条件 | `XcodeProject` |
| ビルドの実行・中断、実行前後のソース確認 | `XcodeBuildService` |
| Scheme・実行先の出力形式への対応 | `XcodeBuildOutput` |
| ビルド生成物の配置・削除・閲覧パスの検証 | `BuildArtifactStore` |
| ビルド設定画面の選択・検証・エラー表示 | `BuildConfigurationModel` |
| メイン画面の入力・選択・進捗とTaskの寿命 | `ReviewModel` |

## 状態と操作の境界

`ReviewModel` と `BuildConfigurationModel` は、操作を `ReviewCoordinator` に依頼します。
画面からGitやビルドの内部サービスを直接呼びません。
ビルド設定の編集中の値は `BuildConfigurationModel` が保持し、保存に成功したときだけ
レビューとリポジトリの既定値を変更します。Schemeを変更すると、前の実行先候補を無効にします。

Coordinatorは保存状態を所有し、状態変更・保存・復旧の順序を管理します。
レビュー開始時はRepositoryのIDから登録済みの最新設定を取得し、未登録のIDでは作成しません。
呼び出し側のSessionはID・パス・SHAを確認したうえで、保持している最新のSessionに解決します。
画面が古い値を渡しても、更新時に新しいビルド設定を失ったり、コピーの保護判定に古い情報を使ったりしません。

排他制御は、awaitの前後を通じて保持する明示的なgateです。
MainActorやactorだけでは、await中に別の操作が割り込むためです。
現在はアプリ全体で1操作を実行します。プロセス間の排他やGUIとCLIの状態共有は未実装です。

| 操作 | 処理と保存失敗時の扱い |
|---|---|
| 作成 | ファイルの事前検証 → fetch → worktree → コピー → 保存。保存に失敗したら環境を一覧に残し、再保存できるようにする |
| 更新 | 変更確認 → fetch → 再確認 → 非強制checkout → 保存。保存に失敗したら編集を再確認し、元SHAへ戻す。復帰にも失敗したら環境を保持する |
| 終了 | 保護検証 → 非強制のworktree削除 → 一覧から除去 → 保存・生成物削除。worktreeを削除できなければコピーと生成物を保持する。削除後の保存失敗は再保存できる |
| ビルド | HEAD・変更確認 → 明示実行 → ログを閉じる → 再確認 → 結果保存。過去SHAの結果も保持する |

Git変更操作は、途中のキャンセルで不整合な状態を残さないよう、保持・awaitしたTaskで保存・復旧まで進めます。
ビルドは中断可能で、子プロセス終了後に中断結果を保存します。
アプリ終了時もTaskの完了を待ちます。突然の強制終了やOSクラッシュからの完全な復旧は保証しません。

## ファイルと外部コマンド

- `Domain/` はSendableな保存モデルと検査結果。ビルド関連の型もここに置き、Xcodeの実行処理と分けます。保存キー・形式は維持します。
- `StateStore` はCodable JSONの読み込みとatomic保存。破損した保存ファイルを初期値で上書きしません。
- `ReviewPaths` はSessionのUUIDと管理領域からworktreeの場所を検証します。
- `RepositoryFileSafety` は相対パス、Git内部、シンボリックリンクを検証します。
- `XcodeProject` はコンテナと構成ファイルを検証します。登録・候補検出・Xcode起動・ビルドで同じ条件を使います。
- `BuildArtifactStore` はUUIDから生成物の配置を決めます。保存されたログパスを削除先として信用せず、閲覧時も所有領域とシンボリックリンクを確認します。
- `BuildLog` はストリーミングログの書き込みを直列化し、書き込み失敗を終了時に返します。
- `GitClient` はliteral引数とhook無効化、`GitHubClient` はGitHubメタデータの取得を担当します。
- `CommandRunner` はSwift Subprocessで非同期実行し、stdout/stderrを分離、ログを配信し、中断時はプロセスグループを終了します。
- `MacIntegration` はファイル選択・Xcode起動・成果物の表示を担当します。ドメインやサービスから画面を開きません。

## 検証

外部依存は固定バージョンのSwift Subprocessと、そのSwift System依存です。
更新時はNUL区切り出力、stderr分離、子プロセス終了の回帰テストを確認します。

Gitの保護動作は実際の一時リポジトリとworktreeで検証します。
保存失敗・ロールバック・コマンド中断は、コマンドと保存の境界に代替処理を注入して再現します。
Xcodeの実行テストは独立した最小プロジェクトを使い、ビルド・テスト・保存・削除を確認します。
利用者のリポジトリやSimulatorには触れません。

登録・起動・ビルドが同じパスを受け付け、同じ不正パスを拒否することも検証します。
ビルド設定の下書きについては、Scheme変更後の実行先の無効化、取得失敗、保存前後の状態を確認します。
