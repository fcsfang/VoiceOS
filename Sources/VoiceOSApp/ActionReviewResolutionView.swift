import SwiftUI
import VoiceOSCore

struct ActionReviewResolutionControl: View {
    @Environment(\.workspacePalette) private var palette
    @ObservedObject var model: ControlCenter
    let pair: ActionReviewPair
    @State private var saving = false
    @State private var error = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("行动关系待核对").font(.headline)
            VStack(alignment: .leading, spacing: 3) {
                Text("之前的记录：" + pair.oldTitle).font(.callout)
                Text("这次识别：" + pair.newTitle).font(.callout)
            }
            if !pair.quote.isEmpty {
                Text("依据原话：" + pair.quote).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(3).textSelection(.enabled)
            }
            HStack(spacing: 10) {
                Button("两件事") { resolve(.different) }.disabled(saving)
                Button("同一件事") { resolve(.same) }.disabled(saving || !pair.isMergeable)
            }
            if let reason = pair.mergeBlockedReason {
                Text(reason).font(.caption).foregroundStyle(palette.warning)
            }
            if !error.isEmpty { Text(error).font(.caption).foregroundStyle(palette.danger) }
        }
    }

    private func resolve(_ relation: ActionReviewRelation) {
        Task {
            saving = true
            if !(await model.resolveActionReview(pair, judgment: relation)) { error = model.status }
            saving = false
        }
    }
}

struct ActionReviewAcknowledgementControl: View {
    @Environment(\.workspacePalette) private var palette
    @ObservedObject var model: ControlCenter
    let expressionID: String
    @State private var confirming = false
    @State private var error = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button("已核对当前理解") { confirming = true }.disabled(model.savingAction)
            if !error.isEmpty { Text(error).font(.caption).foregroundStyle(palette.danger) }
        }
        .alert("已核对当前理解？", isPresented: $confirming) {
            Button("已核对当前理解") { acknowledge() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只记录你已核对；AI 提取保持原样，不再因此暂停。之后若重新理解，会按新的理解再核对一次。")
        }
    }

    private func acknowledge() {
        Task {
            if !(await model.acknowledgeActionReview(expressionID: expressionID)) { error = model.status }
        }
    }
}
