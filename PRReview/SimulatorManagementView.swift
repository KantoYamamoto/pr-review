import SwiftUI

struct SimulatorManagementView: View {
    @Bindable var model: ReviewModel
    @State private var deleting: ManagedSimulator?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("レビュー専用Simulator").font(.title2.bold())
            Text("繰り返し起動すると同じ機種・OSの端末を再利用します。レビュー終了後に残した端末もここで削除できます。削除すると端末内のアプリとデータが失われます。")
                .foregroundStyle(.secondary)
            List(model.state.simulators ?? []) { owned in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(owned.label).font(.headline)
                        Spacer()
                        Button("削除…", role: .destructive) { deleting = owned }.disabled(model.busy)
                    }
                    Text(owned.runtime).font(.caption)
                    if owned.deviceID == nil { Text("端末の作成・確認が未完了の記録です。").font(.caption).foregroundStyle(.secondary) }
                    Text(owned.name).font(.caption.monospaced()).textSelection(.enabled)
                    Text(model.state.sessions.contains { $0.id == owned.sessionID } ? "レビュー中" : "レビュー終了済み")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(.vertical, 6)
            }.frame(minHeight: 220)
            if (model.state.simulators ?? []).isEmpty { Text("専用Simulatorはありません。").foregroundStyle(.secondary) }
            HStack { Spacer(); Button("閉じる") { model.managingSimulators = false }.disabled(model.busy) }
        }.padding(24).frame(width: 700).interactiveDismissDisabled(model.busy)
            .confirmationDialog("この専用Simulatorとデータを削除しますか？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button("削除", role: .destructive) { if let owned = deleting { deleting = nil; model.removeSimulator(owned) } }
            } message: { Text(deleting?.label ?? "") }
    }
}
