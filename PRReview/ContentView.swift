import SwiftUI
import AppKit

struct ContentView: View {
    @Bindable var model: ReviewModel
    var body: some View {
        NavigationSplitView {
            List(selection: $model.selected) {
                Section("レビュー中 · \(model.state.sessions.count)") {
                    ForEach(model.state.sessions) { session in
                        VStack(alignment: .leading, spacing: 5) {
                            Text("#\(session.number)  \(session.title)").font(.headline).lineLimit(2)
                            Text(session.repository.slug).font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 5).tag(session.id)
                    }
                }
                Section("登録リポジトリ") {
                    ForEach(model.state.repositories) { repo in
                        HStack {
                            Text(repo.slug).font(.caption).lineLimit(1)
                            Spacer()
                            Button { model.editingRepository = repo } label: { Image(systemName: "doc.on.doc") }
                                .buttonStyle(.borderless).help("コピーするファイルを設定")
                                .accessibilityLabel("\(repo.slug)のコピー設定").disabled(model.busy)
                        }
                    }
                    Button("リポジトリ登録", systemImage: "folder.badge.plus") { model.addRepository() }.disabled(model.busy)
                }
            }.navigationTitle("PR Review")
                .navigationSplitViewColumnWidth(min: 230, ideal: 280)
        } detail: {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    TextField("https://github.com/owner/repo/pull/123", text: $model.input)
                        .textFieldStyle(.roundedBorder).onSubmit { model.create() }
                    Button("レビュー開始") { model.create() }.buttonStyle(.borderedProminent)
                        .disabled(model.busy || model.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let session = model.session { SessionDetailView(model: model, session: session) }
                else {
                    ContentUnavailableView("作業を残したまま、PRをレビュー。", systemImage: "arrow.triangle.branch",
                        description: Text("初回はローカルリポジトリを登録してください。\n別のworktreeを作り、Xcodeで開きます。"))
                    Spacer()
                }
                Divider()
                HStack {
                    if model.busy { ProgressView().controlSize(.small) }
                    Text(model.activity).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if model.coordinator.hasUnsavedChanges {
                        Button("状態を再保存") { model.retrySave() }.disabled(model.busy)
                    }
                }
            }.padding(24)
            .toolbar {
                if let session = model.session {
                    ToolbarItemGroup {
                        Button("Xcodeで開く", systemImage: "hammer") { model.open(session) }.disabled(model.busy)
                        Button("最新コミットを取得", systemImage: "arrow.clockwise") { model.update(session) }.disabled(model.busy)
                    }
                    ToolbarSpacer(.fixed)
                    ToolbarItemGroup {
                        Link(destination: URL(string: session.prURL)!) { Label("GitHubのPR", systemImage: "link") }
                        Button("Finder", systemImage: "folder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: session.path) }
                        Button("レビュー終了…", systemImage: "checkmark.circle") { model.checkRemoval(session) }.disabled(model.busy)
                    }
                }
            }.disabled(model.shuttingDown)
        }
        .sheet(item: $model.editingRepository) { CopySettingsView(model: model, repository: $0) }
        .sheet(item: $model.projectSelection) { ProjectSelectionView(model: model, selection: $0) }
        .sheet(item: $model.buildConfiguration) { BuildSettingsView(model: model, configuration: $0) }
        .alert("確認", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("閉じる") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .confirmationDialog("レビュー環境を削除しますか？", isPresented: Binding(get: { model.removal != nil }, set: { if !$0 { model.removal = nil } }), titleVisibility: .visible) {
            Button("環境を削除", role: .destructive) {
                if let session = model.removal { model.removal = nil; model.remove(session) }
            }
        } message: {
            Text("このPR用のworktree、未変更のコピー設定、Xcodeの画面状態、専用ビルドデータを削除します。Xcodeの該当プロジェクトを閉じ、未保存の編集がないことを確認してください。")
        }
    }
}

struct SessionDetailView: View {
    @Bindable var model: ReviewModel
    let session: Session
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(session.repository.slug).font(.subheadline).foregroundStyle(.secondary)
                Text("#\(session.number)  \(session.title)").font(.title.bold()).textSelection(.enabled)
                Label("レビュー中のコミット: \(session.sha.prefix(10))", systemImage: "point.3.connected.trianglepath.dotted").font(.callout)
                Text("作成: \(session.createdAt.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                if let date = session.updatedAt { Text("最終更新: \(date.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
                if !(session.copiedFiles ?? []).isEmpty { Text("コピーした設定: \(session.copiedFiles?.count ?? 0)ファイル").font(.caption).foregroundStyle(.secondary) }
                Text("更新・終了前にXcodeの該当プロジェクトを閉じてください。未保存の編集は検出できません。")
                    .font(.callout).foregroundStyle(.secondary)
                Divider()
                HStack {
                    Text("ビルド・テスト").font(.headline)
                    Spacer()
                    Button("設定…", systemImage: "slider.horizontal.3") { model.configureBuild(session) }.disabled(model.busy)
                }
                if let settings = session.repository.buildSettings {
                    Text("\(settings.scheme) · \(settings.destination.label)").font(.callout)
                    HStack {
                        Button("ビルド", systemImage: "hammer.fill") { model.runBuild(session, action: .build) }.buttonStyle(.borderedProminent)
                        Button("テスト", systemImage: "testtube.2") { model.runBuild(session, action: .test) }
                    }.disabled(model.busy)
                } else { Text("「設定…」でSchemeと実行先を選択してください。").foregroundStyle(.secondary) }
                Text("選択したPRのビルドスクリプトを実行します。依存関係の準備・プロジェクト生成が必要な場合は先にXcode等で行ってください。")
                    .font(.caption).foregroundStyle(.secondary)
                if model.runningBuild == session.id {
                    HStack { ProgressView().controlSize(.small); Text("実行中…"); Spacer(); Button("中断") { model.cancelBuild() } }
                    Text(model.liveLog.isEmpty ? "ログを待っています…" : model.liveLog)
                        .font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach((session.buildRecords ?? []).reversed()) { record in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Label("\(record.action.label)：\(record.status.label)", systemImage: record.status == .succeeded ? "checkmark.circle" : "exclamationmark.circle")
                            Spacer()
                            Button("ログ") { model.openArtifact(record.logPath, session: session) }
                            if let path = record.resultPath { Button("テスト結果") { model.openArtifact(path, session: session) } }
                        }
                        Text("\(record.sha.prefix(10)) · \(record.configuration.scheme) · \(record.configuration.destination.label)")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(record.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                        if record.sha != session.sha { Text("過去のコミットの結果です。").font(.caption).foregroundStyle(.orange) }
                        if record.sourceModified { Text("実行中に変更が検出されたため、コミットの確認結果として扱えません。").font(.caption).foregroundStyle(.orange) }
                    }.padding(.vertical, 8)
                }
                Divider()
                Text(session.path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
