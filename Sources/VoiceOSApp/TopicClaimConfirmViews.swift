import SwiftUI
import VoiceOSCore

struct TopicUnlinkedReferencesSection: View {
    @ObservedObject var model: ControlCenter
    let topic: ReflectionQuestion
    @State private var confirmedIDs: [String] = []
    @State private var busyClaimID: String?
    @State private var error = ""

    private var candidates: [CandidateClaim] {
        let confirmed = Set(confirmedIDs)
        return model.unlinkedTopicClaimCandidates(topic).filter { !confirmed.contains($0.id) }
    }

    private var confirmed: [CandidateClaim] {
        confirmedIDs.compactMap { id in model.claims.first { $0.id == id } }
    }

    @ViewBuilder var body: some View {
        if !candidates.isEmpty || !confirmed.isEmpty {
            WorkspaceSection(title:"提到这个主题但还没关联",icon:"link.badge.plus",count:candidates.isEmpty ? nil : candidates.count) {
                ForEach(candidates) { claim in
                    row(claim,actionTitle:"确认关联") { confirm(claim) }
                }
                if !confirmed.isEmpty {
                    Text("已确认").vosFont(12, weight: .medium).foregroundStyle(.secondary).padding(.top, 14)
                    ForEach(confirmed) { claim in
                        row(claim,actionTitle:"取消关联") { unconfirm(claim) }
                    }
                }
                if !error.isEmpty { WorkspaceNoticeText(message:error,severity:.danger).padding(.top, 10) }
            }.task { reload() }
        }
    }

    private func row(_ claim: CandidateClaim, actionTitle: String, action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(claim.statement).vosFont(15).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Text(sourceTitle(claim)).vosFont(12).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer(minLength: 12)
            Button(actionTitle,action:action).buttonStyle(.bordered).disabled(busyClaimID != nil)
        }.padding(.vertical, 12)
    }

    private func sourceTitle(_ claim: CandidateClaim) -> String {
        let topicSourceIDs = Set(model.workspaceTopicSources[topic.id] ?? [])
        guard let sourceID = claim.references.map(\.sourceID).first(where: topicSourceIDs.contains) ?? claim.references.first?.sourceID else { return "来源材料" }
        return model.records.first { $0.id == sourceID }?.displayTitle ?? "来源材料"
    }

    private func reload() {
        do { confirmedIDs = try model.confirmedTopicClaimIDs(topicID:topic.id); error = "" }
        catch { self.error = error.localizedDescription }
    }

    private func confirm(_ claim: CandidateClaim) {
        busyClaimID = claim.id
        defer { busyClaimID = nil }
        do { _ = try model.confirmTopicClaim(topicID:topic.id, claimID:claim.id); reload() }
        catch { self.error = error.localizedDescription }
    }

    private func unconfirm(_ claim: CandidateClaim) {
        busyClaimID = claim.id
        defer { busyClaimID = nil }
        do { try model.unconfirmTopicClaim(topicID:topic.id, claimID:claim.id); reload() }
        catch { self.error = error.localizedDescription }
    }
}

extension ControlCenter {
    func unlinkedTopicClaimCandidates(_ topic: ReflectionQuestion) -> [CandidateClaim] {
        let sections = topic.organization?.sections ?? []
        return UnlinkedReferences.candidates(
            topicTitle: topic.title,
            sectionTitles: sections.map(\.title),
            linkedClaimIDs: Set(sections.flatMap(\.claimIDs)),
            topicSourceIDs: Set(workspaceTopicSources[topic.id] ?? []),
            claims: claims
        )
    }

    func confirmedTopicClaimIDs(topicID: String) throws -> [String] {
        guard let store else { return [] }
        return try store.confirmedTopicClaimIDs(topicID: topicID)
    }

    @discardableResult
    func confirmTopicClaim(topicID: String, claimID: String) throws -> Bool {
        guard let store else { throw VoiceOSError("资料库尚未打开") }
        return try store.confirmTopicClaim(topicID: topicID, claimID: claimID)
    }

    func unconfirmTopicClaim(topicID: String, claimID: String) throws {
        guard let store else { throw VoiceOSError("资料库尚未打开") }
        try store.unconfirmTopicClaim(topicID: topicID, claimID: claimID)
    }
}
