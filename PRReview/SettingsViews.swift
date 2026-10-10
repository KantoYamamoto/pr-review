import SwiftUI

struct CopySettingsView: View {
    @Bindable var model: ReviewModel
    let repository: Repository
    @State private var paths: [String]
    @State private var error: String?
    @State private var choosing = false
    init(model: ReviewModel, repository: Repository) {
        self.model = model; self.repository = repository
        _paths = State(initialValue: repository.copyPaths ?? [])
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("レビュー環境にコピーするファイル").font(.title2.bold())
            Text(repository.slug).foregroundStyle(.secondary)
            Text("GitでignoreされているFirebase設定や.xcconfigを選択します。同じ相対パスへコピーし、変更がなければレビュー終了時に片付けます。設定は新しく作るレビュー環境に適用します。")
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
            }.disabled(model.busy || choosing)
                .overlay { if paths.isEmpty { Text("コピー対象は未設定です").foregroundStyle(.secondary) } }
            if let error { Text(error).foregroundStyle(.red).font(.caption).textSelection(.enabled) }
            HStack {
                Button("ファイルを追加…", systemImage: "plus") {
                    choosing = true
                    Task { @MainActor in
                        defer { choosing = false }
                        let files = await MacIntegration.chooseCopyFiles(repository: repository)
                        do {
                            let added = try files.map { try model.coordinator.service.relativeCopyPath($0, repository: repository) }
                            paths = Array(Set(paths + added)).sorted(); error = nil
                        } catch { self.error = error.localizedDescription }
                    }
                }
                Spacer()
                Button("キャンセル") { model.editingRepository = nil }
                Button("保存") { error = nil; model.saveCopies(repository, paths: paths) { error = $0 } }.buttonStyle(.borderedProminent)
            }.disabled(model.busy || choosing)
        }.padding(24).frame(width: 580, height: 460)
            .interactiveDismissDisabled(model.busy || choosing)
    }
}

struct ProjectSelectionView: View {
    @Bindable var model: ReviewModel
    let selection: ProjectSelection
    @State private var selected: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("開くXcodeプロジェクトを選択").font(.headline)
            Text("複数の候補が見つかりました。workspaceは一覧の先頭に表示します。").foregroundStyle(.secondary)
            List(selection: $selected) {
                ForEach(selection.entries, id: \.self) { entry in
                    Label(entry, systemImage: entry.hasSuffix(".xcworkspace") ? "square.stack" : "hammer").tag(entry)
                }
            }.frame(minHeight: 180).disabled(model.busy)
            if let error = model.projectSelectionError { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Button("手動で選択…") { model.chooseProjectManually(root: selection.root) }
                Spacer()
                Button("キャンセル") { model.projectSelection = nil; model.activity = "登録をキャンセルしました。" }
                Button("登録") {
                    if let selected { model.registerRepository(root: selection.root, entry: selected) }
                }.buttonStyle(.borderedProminent).disabled(selected == nil)
            }.disabled(model.busy)
        }.padding(24).frame(width: 620).interactiveDismissDisabled(model.busy)
    }
}

struct BuildSettingsView: View {
    @Bindable var model: ReviewModel
    let session: Session
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("ビルド・テストの設定").font(.title2.bold())
            Text("このレビューと、次に作るレビュー環境の既定値として保存します。").foregroundStyle(.secondary)
            Picker("Scheme", selection: Binding(get: { model.buildScheme }, set: {
                model.buildScheme = $0; model.buildDestinations = []; model.buildDestinationID = ""
            })) {
                if model.buildSchemes.isEmpty { Text("Schemeなし").tag("") }
                ForEach(model.buildSchemes, id: \.self) { Text($0).tag($0) }
            }.disabled(model.busy)
            HStack {
                Picker("実行先", selection: $model.buildDestinationID) {
                    if model.buildDestinations.isEmpty { Text("実行先を取得してください").tag("") }
                    ForEach(model.buildDestinations) { Text($0.label).tag($0.id) }
                }
                Button("実行先を取得") { model.loadDestinations(session) }.disabled(model.buildScheme.isEmpty || model.busy)
            }.disabled(model.busy)
            Text("macOSとiOS Simulatorに対応します。実機へのインストールやSimulatorの作成は行いません。")
                .font(.caption).foregroundStyle(.secondary)
            if model.busy { ProgressView().controlSize(.small) }
            if let error = model.buildSettingsError { ScrollView { Text(error).foregroundStyle(.red).textSelection(.enabled) }.frame(maxHeight: 160) }
            HStack {
                Button("再取得") { model.configureBuild(session) }
                Spacer()
                Button("キャンセル") { model.configuringBuild = nil }
                Button("保存") { model.saveBuildSettings(session) }.buttonStyle(.borderedProminent)
                    .disabled(model.buildScheme.isEmpty || model.buildDestinationID.isEmpty)
            }.disabled(model.busy)
        }.padding(24).frame(width: 650).interactiveDismissDisabled(model.busy)
    }
}
