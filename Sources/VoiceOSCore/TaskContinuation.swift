import Foundation

struct ExistingRecordingTask: Codable {
    let id: String
    let version: Int
    let title: String
    let state: String
    let claimID: String
    let claimReviewVersion: Int
    let statement: String
    let references: [ClaimReference]
    let policyVersions: [String: Int]
}

struct OrganizedTaskContinuation: Decodable {
    let relation: String
    let target: ExistingRecordingTask
    let notes: String
}

extension VoiceOSStore {
    // Reuse task identities and feedback; only authorized current text is sent to the model.
    func existingRecordingTasks(excludingSourceIDs: Set<String> = []) throws -> [ExistingRecordingTask] {
        let claims = Dictionary(uniqueKeysWithValues: try candidateClaims().map { ($0.id, $0) })
        var result: [ExistingRecordingTask] = []
        for action in try actions(includeHistory: true) where action.kind == "task" && action.intentActor == "user" && action.validity == "current" && ["open", "completed"].contains(action.state) {
            guard let claim = claims[action.claimID], claim.reviewVersion == action.claimReviewVersion,
                  !claim.references.isEmpty, claim.references.allSatisfy({ !excludingSourceIDs.contains($0.sourceID) }) else { continue }
            var policies: [String: Int] = [:]
            for sourceID in Set(claim.references.map(\.sourceID)) {
                let policy = try sourcePolicy(sourceID: sourceID)
                if !policy.localOnly { policies[sourceID] = policy.version }
            }
            guard policies.count == Set(claim.references.map(\.sourceID)).count else { continue }
            result.append(.init(id: action.id, version: action.version, title: action.title, state: action.state,
                                claimID: claim.id, claimReviewVersion: claim.reviewVersion, statement: claim.statement,
                                references: claim.references, policyVersions: policies))
        }
        return result.sorted { $0.id < $1.id }
    }

    @discardableResult
    public func writeExistingTaskInput(to file: URL, excludingSourceIDs: [String] = []) throws -> Int {
        let tasks = try existingRecordingTasks(excludingSourceIDs: Set(excludingSourceIDs))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(tasks).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return tasks.count
    }

    func validateTaskContinuations(_ links: [OrganizedTaskContinuation], excludingSourceIDs: Set<String>) throws {
        let current = Dictionary(uniqueKeysWithValues: try existingRecordingTasks(excludingSourceIDs: excludingSourceIDs).map { ($0.id, $0) })
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        for link in links {
            guard ["repeat", "progress", "outcome"].contains(link.relation), let task = current[link.target.id],
                  try encoder.encode(task) == encoder.encode(link.target), link.relation != "repeat" || task.state == "open" else {
                throw VoiceOSError("原任务或授权已变化，接续结果尚未接入；请重试整理以重新核对")
            }
        }
    }

    func recordTaskContinuation(_ link: OrganizedTaskContinuation, claimID: String, quote: String, recordingSourceID: String, commandID: String) throws {
        let feedback = FeedbackIntent(actionID: link.target.id, actionVersion: link.target.version,
                                      kind: link.relation == "outcome" ? .outcome : .reflection,
                                      recordingSourceID: recordingSourceID, organizedClaimID: claimID, relation: link.relation)
        // Save the user's verbatim excerpt, never the model's explanation as user-authored text.
        _ = try recordExpression(quote, commandID: commandID, feedback: feedback)
    }
}
