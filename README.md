# PR Review

PRのURLを貼ってレビュー用のGit worktreeを作り、Xcodeで開くmacOSアプリの試作。
普段の作業中のファイルやブランチを切り替えずにレビューできます。

## 起動

macOS 14以降、Xcode / Command Line Tools、Git、認証済みのGitHub CLIが必要です。

```sh
git clone https://github.com/KantoYamamoto/pr-review.git
cd pr-review
brew install gh
gh auth login
./scripts/bundle.sh
open 'dist/PR Review.app'
```

Xcodeで `PRReview.xcodeproj` を開き、PRReview scheme / My Macを選んで ⌘R でも起動できます。
ローカル用のad-hoc署名です。配布用のDeveloper ID署名・公証は含みません。

## プロジェクト構成

通常のXcode macOS Appプロジェクトとして、アプリとユニットテストの2ターゲットを用意しています。

```text
PRReview/
├── PRReview.xcodeproj/          # Xcodeプロジェクト・共有scheme
├── PRReview/
│   ├── PRReviewApp.swift        # アプリの入口
│   ├── ContentView.swift        # 画面
│   ├── ReviewModel.swift        # 状態・操作
│   ├── Services/
│   │   └── ReviewService.swift  # Git操作・保存
│   └── Assets.xcassets/         # 色・アプリアイコン（画像は未設定）
├── PRReviewTests/
│   └── PRReviewTests.swift
├── scripts/bundle.sh
└── README.md
```

Info.plistはXcodeのビルド設定から自動生成します。
ローカルGitリポジトリとGit/ghを扱うため、App Sandboxは無効です。

## 使い方

1. 「リポジトリ登録」で普段使っているローカルrepoを選ぶ。
2. そのrepo内で開く `.xcworkspace` または `.xcodeproj` を選ぶ。
3. `https://github.com/owner/repo/pull/123` を貼り「レビュー開始」。
4. 専用worktreeが作られ、登録したプロジェクトをXcodeで開く。
5. 左の一覧から再開。GitHubのPRやFinderにも移動できる。
   PRに追加コミットが入ったらXcodeの該当プロジェクトを閉じて「最新コミットを取得」。
   同じworktreeを最新SHAに切り替え、コミット表示と最終更新日時を更新します。
6. レビュー後はXcodeの該当プロジェクトを閉じ、未保存の編集を保存して「レビュー終了…」。

### Firebase設定・ローカル設定をコピーする

登録リポジトリの右にあるコピー設定ボタンから、`GoogleService-Info.plist` や
ローカルの `.xcconfig` などを追加できます。指定はrepoごとに保存され、次に作るレビュー環境へ
同じ相対パスでコピーします。設定変更は既存のレビュー環境には適用しません。

- リポジトリ内にある、Gitでignoreされた通常のファイルだけを指定できます。
  フォルダ、シンボリックリンク、Git管理済みファイル、`.git` 内のファイルは対象外です。
- コピー先もPRのignore設定に含まれ、まだ存在しないことを確認してからコピーします。
  コピーには所有者のみ読み書きできる権限を設定します。
- ファイル内容を更新時にコピーし直すことはありません。コピー時のSHA-256を保存し、
  コピー元が後から変更されても、レビュー環境の内容を維持します。
- コピーしたファイルが未変更なら、レビュー終了時にworktreeと一緒に片付けます。
  編集されていれば更新・終了を止めます。必要な内容を元repo等へ保存したうえで、
  コピーを元の内容へ戻すか、不要になったコピーを削除してください。
- 最新PRがコピー先をGit管理したり、親フォルダをファイル／シンボリックリンクに
  変更した場合は、内容が同じでも更新を止めます。元ファイルを上書きすることはありません。
- 設定・コピー記録はMac内のApplication Supportへ保存し、repoには書き込みません。
  指定したファイルはレビュー環境へローカルコピーするだけで、GitHubへ送信しません。

ターゲットごとにFirebaseのBundle IDが異なる構成では、対応する設定ファイルを指定してください。

GitHub CLIが認証されていてもGitのfetch認証が別途必要な構成があります。
HTTPS remoteで認証が失敗する場合は `gh auth setup-git`、SSHなら通常のSSH認証を設定してください。

## 動作と保護

- GitHub.comのみ対応。`origin`のURLとPRのowner/repoが一致する登録repoを使用。
- PRのhead refを一時的な専用refにfetchし、SHAを確認してdetached HEADのworktreeを作成。
- ローカルrepoの作業ファイルやチェックアウトブランチは切り替えません。
  Gitオブジェクトとworktree管理情報は共有します。
- Git hookはこのアプリからのGit操作では無効化。依存取得・ビルド・setup scriptは自動実行しません。
- 同じPRの「レビュー開始」は作成済み環境を再度開きます。追加pushへの自動追従はせず、
  「最新コミットを取得」で更新します。ブランチは作成せずdetached HEADを維持します。
  force pushで履歴が変わった場合も最新SHAへ切り替えます。マージ・rebaseは行いません。
  取得中にPRが変わった場合は切り替えを中止し、再取得を案内します。
  最新なら「すでに最新のコミットです」と表示します。
- 更新・削除直前にも確認し、未コミット／未追跡の変更、レビュー中のSHA以降のコミット、ignoredファイルが
  あれば削除を拒否します。アプリがコピーして内容が変わっていない設定ファイルは例外です。
  また、`.xcodeproj` / `.xcworkspace` 内の `xcuserdata/<user>.xcuserdatad/`
  にあるignoredの `UserInterfaceState.xcuserstate` と `xcschemes/xcschememanagement.plist` は
  Xcodeが生成する状態としてworktreeと一緒に削除します。共有／個人ブレークポイント、
  カスタムscheme、Git管理されているファイルの変更は保護します。
  強制削除はありません。その他の不要な生成物はFinder等から手動で削除できます。
- アプリが作ったUUIDのパス、repoの一致を確認し、`git worktree remove`で削除します。
- Xcodeの未保存バッファは検出できません。該当プロジェクトを閉じてから終了してください。
- Xcodeの外部DerivedData、SPMキャッシュ、シミュレータは管理・削除しません。
  同じシミュレータ・Bundle IDでRunすると普段の開発アプリを上書きすることがあります。
- ファイル単位のローカル設定コピーに対応しています。PodsやTuist等のフォルダのコピー・
  依存取得・プロジェクト生成のセットアップは手動です。

## 保存先

`~/Library/Application Support/PRReview/state.json` に登録repoとレビュー環境の情報を保存。
`~/Library/Application Support/PRReview/Worktrees/<UUID>/` にレビュー用worktreeを作成。
環境が残っている間は登録元repoを移動・削除しないでください。

アプリを削除してもworktreeは自動削除されません。先にアプリから各レビューを終了してください。
保存に失敗して一覧から見えなくなった環境は、登録元repoで `git worktree list` を確認して
必要なファイルを保存した上で `git worktree remove <対象パス>` で片付けられます。

## 開発・確認

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
