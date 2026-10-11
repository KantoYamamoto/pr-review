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
                Section("専用Simulator") {
                    Button("専用Simulatorの管理…", systemImage: "iphone") { model.managingSimulators = true }.disabled(model.busy)
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
                    if model.state.repositories.isEmpty {
                        ContentUnavailableView("リポジトリを登録", systemImage: "folder.badge.plus",
                            description: Text("サイドバーの「リポジトリ登録」で、普段使っているローカルリポジトリを選んでください。"))
                    } else if model.state.sessions.isEmpty {
                        ContentUnavailableView("PRのURLを入力", systemImage: "arrow.triangle.branch",
                            description: Text("上の欄にGitHubのPR URLを貼り付け、「レビュー開始」を押してください。\n普段の作業とは別のフォルダで、Xcodeプロジェクトを開きます。"))
                    } else {
                        ContentUnavailableView("レビューを選択", systemImage: "sidebar.left",
                            description: Text("サイドバーから開きたいPRを選んでください。"))
                    }
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
        .sheet(isPresented: $model.managingSimulators) { SimulatorManagementView(model: model) }
        .sheet(item: $model.buildConfiguration) { BuildSettingsView(model: model, configuration: $0) }
        .alert("操作を完了できませんでした", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("閉じる") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .confirmationDialog("レビュー環境を削除しますか？", isPresented: Binding(get: { model.removal != nil }, set: { if !$0 { model.removal = nil } }), titleVisibility: .visible) {
            if let session = model.removal, (model.state.simulators ?? []).contains(where: { $0.sessionID == session.id }) {
                Button("専用Simulatorを残して終了") {
                    model.removal = nil; model.remove(session, keepSimulators: true)
                }
            }
            Button((model.state.simulators ?? []).contains { $0.sessionID == model.removal?.id } ? "専用Simulatorも削除して終了" : "環境を削除", role: .destructive) {
                if let session = model.removal { model.removal = nil; model.remove(session) }
            }
        } message: {
            if (model.state.simulators ?? []).contains(where: { $0.sessionID == model.removal?.id }) {
                Text("Xcodeで編集を保存し、このプロジェクトを閉じてから終了してください。\n\nこのPR用のworktree、コピーしたファイル、Xcodeの画面状態、ビルドデータを削除します。\n\n専用Simulatorも削除すると、端末内のアプリとデータが消えます。残した端末は「専用Simulatorの管理…」から後で削除できます。")
            } else {
                Text("Xcodeで編集を保存し、このプロジェクトを閉じてから終了してください。\n\nこのPR用のworktree、コピーしたファイル、Xcodeの画面状態、ビルドデータを削除します。")
            }
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
                if !(session.copiedFiles ?? []).isEmpty { Text("コピーしたファイル: \(session.copiedFiles?.count ?? 0)件").font(.caption).foregroundStyle(.secondary) }
                Text("更新やレビュー終了の前に、Xcodeで編集を保存し、このプロジェクトを閉じてください。未保存の編集は検出できません。")
                    .font(.callout).foregroundStyle(.secondary)
                Divider()
                HStack {
                    Text("ビルド・テスト・起動").font(.headline)
                    Spacer()
                    Button("設定…", systemImage: "slider.horizontal.3") { model.configureBuild(session) }.disabled(model.busy)
                }
                if let settings = session.repository.buildSettings {
                    Text("\(settings.scheme) · \(settings.destination.label)").font(.callout)
                    HStack {
                        Button("ビルド", systemImage: "hammer.fill") { model.runBuild(session, action: .build) }.buttonStyle(.borderedProminent)
                        Button("テスト", systemImage: "testtube.2") { model.runBuild(session, action: .test) }
                        if settings.destination.platform == "iOS Simulator" {
                            Button("Simulatorで起動", systemImage: "play.fill") { model.runOnSimulator(session) }
                        }
                    }.disabled(model.busy)
                } else { Text("「設定…」でSchemeと実行先を選択してください。").foregroundStyle(.secondary) }
                VStack(alignment: .leading, spacing: 4) {
                    Text("このPRに含まれるビルドスクリプトも実行されます。")
                    Text("依存関係のインストールやプロジェクト生成が必要な場合は、先にレビュー環境で済ませてください。")
                }.font(.caption).foregroundStyle(.secondary)
                if model.runningBuild == session.id {
                    HStack { ProgressView().controlSize(.small); Text("実行中…"); Spacer(); Button("中断") { model.cancelBuild() } }
                    Text(model.liveLog.isEmpty ? "ログを待っています…" : model.liveLog)
                        .font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                if let record = session.simulatorLaunches?.last {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Simulator起動：\(record.status.label)").font(.headline)
                        Text(record.message).textSelection(.enabled)
                        if let name = record.simulatorName { Text(name).font(.caption).textSelection(.enabled) }
                        Text("\(record.sha.prefix(10)) · \(record.date.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                        if record.sha != session.sha { Text("過去のコミットの起動結果です。").font(.caption).foregroundStyle(.orange) }
                        if record.status == .succeeded {
                            Text("Xcode 27では、Device Hubで上の端末名を選ぶと画面を開けます。").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                ForEach((session.buildRecords ?? []).reversed()) { record in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Label("\(record.action.label)：\(record.status.label)", systemImage: record.status == .succeeded ? "checkmark.circle" : "exclamationmark.circle")
                            Spacer()
                            Button("ログ") { model.openArtifact(record.logPath, session: session) }
                            if let path = record.resultPath { Button("Xcodeで結果を開く") { model.openArtifact(path, session: session) } }
                        }
                        Text("\(record.sha.prefix(10)) · \(record.configuration.scheme) · \(record.configuration.destination.label)")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(record.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                        if record.sha != session.sha { Text("過去のコミットの結果です。").font(.caption).foregroundStyle(.orange) }
                        if record.sourceModified { Text("実行後のソースがこのコミットと一致することを確認できませんでした。レビュー環境の変更を確認してから、もう一度実行してください。").font(.caption).foregroundStyle(.orange) }
                    }.padding(.vertical, 8)
                }
                Divider()
                Text(session.path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
