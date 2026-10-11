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
            VStack(alignment: .leading, spacing: 6) {
                Text("Firebaseの設定ファイルや.xcconfigなど、レビューに必要なファイルを追加してください。Gitのignore設定で除外されているファイルを選べます。")
                Text("次に作るレビュー環境の同じ相対パスにコピーします。コピー後に変更がなければ、レビュー終了時に削除します。")
            }.font(.callout).foregroundStyle(.secondary)
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
                .overlay { if paths.isEmpty { Text("コピーするファイルはありません").foregroundStyle(.secondary) } }
            if let error { Text(error).foregroundStyle(.red).font(.caption).textSelection(.enabled) }
            HStack {
                Button("ファイルを追加…", systemImage: "plus") {
                    choosing = true
                    Task { @MainActor in
                        defer { choosing = false }
                        let files = await MacIntegration.chooseCopyFiles(repository: repository)
                        do {
                            let added = try files.map { try model.coordinator.relativeCopyPath($0, repository: repository) }
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
            Text("複数の候補が見つかりました。レビューで使うプロジェクトまたはworkspaceを選んでください。").foregroundStyle(.secondary)
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
    @Bindable var configuration: BuildConfigurationModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Schemeと実行先").font(.title2.bold())
            Text("このレビューに適用します。同じリポジトリの次のレビューにも使います。").foregroundStyle(.secondary)
            Picker("Scheme", selection: Binding(get: { configuration.scheme }, set: {
                configuration.selectScheme($0)
            })) {
                if configuration.schemes.isEmpty { Text(model.busy ? "取得中…" : "Schemeがありません").tag("") }
                ForEach(configuration.schemes, id: \.self) { Text($0).tag($0) }
            }.disabled(model.busy)
            HStack {
                Picker("実行先", selection: $configuration.destinationID) {
                    if configuration.destinations.isEmpty { Text(model.busy ? "取得中…" : "実行先を取得してください").tag("") }
                    ForEach(configuration.destinations) { Text($0.label).tag($0.id) }
                }
                Button("実行先を取得") { model.loadDestinations(configuration) }.disabled(configuration.scheme.isEmpty || model.busy)
            }.disabled(model.busy)
            VStack(alignment: .leading, spacing: 6) {
                Text("実行先はMacまたはiOS Simulatorを選べます。テストは選んだ実行先で行います。")
                if configuration.settings?.destination.platform == "iOS Simulator" {
                    Text("「Simulatorで起動」は、選んだ端末と同じ機種・OSのレビュー専用端末を使います。このレビューで同じ機種・OSの端末を作成済みなら、端末とデータを再利用します。")
                }
            }.font(.caption).foregroundStyle(.secondary)
            if model.busy { ProgressView().controlSize(.small) }
            if let error = configuration.error { ScrollView { Text(error).foregroundStyle(.red).textSelection(.enabled) }.frame(maxHeight: 160) }
            HStack {
                Button("再取得") { model.reloadBuildConfiguration(configuration) }
                Spacer()
                Button("キャンセル") { model.buildConfiguration = nil }
                Button("保存") { model.saveBuildSettings(configuration) }.buttonStyle(.borderedProminent)
                    .disabled(configuration.settings == nil)
            }.disabled(model.busy)
        }.padding(24).frame(width: 650).interactiveDismissDisabled(model.busy)
    }
}
