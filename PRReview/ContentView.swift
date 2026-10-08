import SwiftUI
import AppKit

struct ContentView: View {
    @ObservedObject var model: ReviewModel
    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Image(systemName: "arrow.triangle.pull").foregroundStyle(.indigo)
                    Text("PR Review").font(.title2.bold())
                }.padding(20)
                List(selection: $model.selected) {
                    Section("レビュー中 · \(model.state.sessions.count)") {
                        ForEach(model.state.sessions) { session in
                            VStack(alignment: .leading, spacing: 5) {
                                Text("#\(session.number)  \(session.title)").font(.headline).lineLimit(2)
                                Text(session.repository.slug).font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 5).tag(session.id)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("登録リポジトリ").font(.caption.bold()).foregroundStyle(.secondary)
                    ForEach(model.state.repositories) { repo in
                        HStack {
                            Text(repo.slug).font(.caption).lineLimit(1)
                            Spacer()
                            Button { model.editingRepository = repo } label: { Image(systemName: "doc.on.doc") }
                                .help("コピーするファイルを設定").disabled(model.busy)
                                .accessibilityLabel("\(repo.slug)のコピー設定")
                        }
                    }
                    Button("リポジトリ登録", systemImage: "folder.badge.plus") { model.addRepository() }
                        .padding(.top, 5).disabled(model.busy)
                }.padding(16)
            }.navigationSplitViewColumnWidth(min: 230, ideal: 280)
        } detail: {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("作業を残したまま、PRをレビュー。").font(.title2.bold())
                    Text("別のworktreeを作り、Xcodeで開きます。").foregroundStyle(.secondary)
                    HStack {
                        TextField("https://github.com/owner/repo/pull/123", text: $model.input)
                            .textFieldStyle(.roundedBorder).onSubmit { if !model.busy { model.create() } }
                        Button("レビュー開始") { model.create() }
                            .buttonStyle(.borderedProminent).tint(.indigo)
                            .disabled(model.busy || model.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                Divider()
                if let session = model.session {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(session.repository.slug.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text("#\(session.number)  \(session.title)").font(.title.bold()).textSelection(.enabled)
                        Label("レビュー中のコミット: \(session.sha.prefix(10))", systemImage: "point.3.connected.trianglepath.dotted")
                            .font(.callout).foregroundStyle(.secondary)
                        Text("作成: \(session.createdAt.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                        if !(session.copiedFiles ?? []).isEmpty {
                            Text("コピーした設定: \(session.copiedFiles?.count ?? 0)ファイル（変更があれば保護します）")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let updatedAt = session.updatedAt {
                            Text("最終更新: \(updatedAt.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Button("最新コミットを取得", systemImage: "arrow.clockwise") { model.update(session) }
                                .disabled(model.busy)
                            Text("Xcodeの該当プロジェクトを閉じてから更新してください。手元に変更がある場合は更新を止めます。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        HStack {
                            Button("Xcodeで開く", systemImage: "hammer") { model.open(session) }
                                .buttonStyle(.borderedProminent).tint(.indigo)
                            Link("GitHubのPR", destination: URL(string: session.prURL)!)
                            Button("Finder", systemImage: "folder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: session.path) }
                        }.disabled(model.busy)
                        Text(session.path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        Spacer()
                        VStack(alignment: .leading, spacing: 10) {
                            Text("レビューが終わったら").font(.headline)
                            Text("Xcodeのこのプロジェクトを閉じてから終了してください。未保存の編集は先に保存してください。未変更のコピー設定とXcodeの画面状態は片付けます。編集した設定やその他の変更があれば環境を残します。")
                                .font(.callout).foregroundStyle(.secondary)
                            Button("レビュー終了…", systemImage: "checkmark.circle") { model.checkRemoval(session) }.disabled(model.busy)
                        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
                    }
                } else {
                    ContentUnavailableView("レビュー環境を作成", systemImage: "arrow.triangle.branch", description: Text("初回はローカルリポジトリと、開くXcodeプロジェクトを登録してください。\n既存のブランチや作業ファイルを切り替える必要はありません。"))
                    Spacer()
                }
                HStack(spacing: 10) {
                    if model.busy { ProgressView().controlSize(.small) }
                    Text(model.activity).font(.caption).foregroundStyle(.secondary)
                }
            }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .sheet(item: $model.editingRepository) { repository in
            CopySettingsView(model: model, repository: repository)
        }
        .alert("確認", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("閉じる") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .alert("レビュー環境を削除しますか？", isPresented: Binding(get: { model.removal != nil }, set: { if !$0 { model.removal = nil } })) {
            Button("キャンセル", role: .cancel) { model.removal = nil }
            Button("環境を削除", role: .destructive) {
                if let session = model.removal { model.removal = nil; model.remove(session) }
            }
        } message: {
            Text("このPR用のworktree、コピー時から変わっていない設定ファイル、Xcodeの画面状態を削除します。Xcodeの該当プロジェクトを閉じ、未保存の編集がないことを確認してください。元のファイルは残ります。")
        }
    }
}

struct CopySettingsView: View {
    @ObservedObject var model: ReviewModel
    let repository: Repository
    @State private var paths: [String]
    @State private var error: String?
    init(model: ReviewModel, repository: Repository) {
        self.model = model; self.repository = repository
        _paths = State(initialValue: repository.copyPaths ?? [])
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("レビュー環境にコピーするファイル").font(.title2.bold())
            Text(repository.slug).foregroundStyle(.secondary)
            Text("GitでignoreされているFirebase設定や.xcconfigを選択します。同じ相対パスへコピーし、変更がなければレビュー終了時に片付けます。設定は新しく作るレビュー環境に適用されます。")
                .font(.callout).foregroundStyle(.secondary)
            List {
                ForEach(paths, id: \.self) { path in
                    HStack {
                        Text(path).font(.callout.monospaced())
                        Spacer()
                        Button { paths.removeAll { $0 == path } } label: { Image(systemName: "minus.circle") }
                            .accessibilityLabel("\(path)をコピー対象から外す")
                    }
                }
            }.disabled(model.busy)
                .overlay { if paths.isEmpty { Text("コピー対象は未設定です").foregroundStyle(.secondary) } }
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack {
                Button("ファイルを追加…", systemImage: "plus") { chooseFiles() }
                Spacer()
                Button("キャンセル") { model.editingRepository = nil }
                Button("保存") {
                    error = nil
                    model.saveCopies(repository, paths: paths) { error = $0 }
                }.buttonStyle(.borderedProminent)
            }.disabled(model.busy)
        }.padding(24).frame(width: 580, height: 460)
            .interactiveDismissDisabled(model.busy)
    }
    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.message = "リポジトリ内のignoreされている設定ファイルを選択"
        panel.directoryURL = URL(fileURLWithPath: repository.path)
        panel.canChooseDirectories = false; panel.canChooseFiles = true
        panel.allowsMultipleSelection = true; panel.showsHiddenFiles = true
        panel.treatsFilePackagesAsDirectories = true
        guard panel.runModal() == .OK else { return }
        do {
            let added = try panel.urls.map { try model.service.relativeCopyPath($0, repository: repository) }
            paths = Array(Set(paths + added)).sorted(); error = nil
        } catch { self.error = error.localizedDescription }
    }
}
