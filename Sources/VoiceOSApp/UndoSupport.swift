import VoiceOSCore

struct ActionChangeReceipt {
    let successorID: String?
    let keptSuccessorID: String?
}

extension ControlCenter {
    var canUndoChange: Bool { !actionUndoStack.isEmpty }

    func recordActionChange(_ action: ActionRecord, from: LocalActionState, to: LocalActionState, successorID: String? = nil) {
        actionUndoStack.record(ActionUndoEntry(actionID: action.id, title: action.title, from: from, to: to, successorID: successorID))
    }

    func undoLastChange() async {
        guard !savingAction else { status = "正在保存其他更改，请稍后重试"; return }
        guard let store else { status = "资料库尚未打开"; return }
        guard !actionUndoStack.isEmpty else { status = "没有可撤销的变更"; return }
        var skipped = false
        while let change = actionUndoStack.popLast() {
            switch await undo(change, store: store) {
            case .applied(let message):
                status = (skipped ? UndoSkip.objectChanged.message + " · " : "") + message
                return
            case .skipped:
                skipped = true
            case .failed(let message):
                status = message
                return
            }
        }
        status = UndoSkip.objectChanged.message
    }

    private enum UndoResult {
        case applied(String)
        case skipped
        case failed(String)
    }

    private func undo(_ change: WorkspaceChange, store: VoiceOSStore) async -> UndoResult {
        switch change {
        case .action(let entry):
            let records: [ActionRecord]
            do { records = try await store.actions(includeHistory: true) } catch { return .failed(error.localizedDescription) }
            guard let record = records.first(where: { $0.id == entry.actionID }),
                  entry.skipReason(current: LocalActionState(rawValue: record.state)) == nil else { return .skipped }
            isUndoingActionChange = true; defer { isUndoingActionChange = false }
            let receipt = await changeAction(record, state: entry.from, successorID: entry.successorID)
            guard actionRecords.first(where: { $0.id == entry.actionID })?.state == entry.from.rawValue else { return .failed(status) }
            return .applied("已撤销「\(entry.title)」的变更" + (receipt?.keptSuccessorID == nil ? "" : " · 下一次已保留"))
        case .materialDisposition(let change):
            let sources: [SourceRecord]
            do { sources = try await store.sources() } catch { return .failed(error.localizedDescription) }
            guard change.skipReason(current: Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0.disposition) })) == nil else { return .skipped }
            do { try await store.setMaterialDisposition(sourceIDs: change.sourceIDs, disposition: change.from) } catch { return .failed(error.localizedDescription) }
            await refresh()
            return .applied("已撤销处置；理解与暂停不会回滚")
        case .materialTitle(let change):
            let sources: [SourceRecord]
            do { sources = try await store.sources() } catch { return .failed(error.localizedDescription) }
            guard let source = sources.first(where: { $0.id == change.sourceID }),
                  change.skipReason(currentTitle: source.presentation?.manualTitle) == nil else { return .skipped }
            do { try await store.renameRecording(sourceID: change.sourceID, title: change.from) } catch { return .failed(error.localizedDescription) }
            await refresh(); queueRecordingTitles()
            return .applied("已撤销「\(change.title)」的改名")
        }
    }

    func recurrenceDueLabel(_ successorID: String?) async -> String {
        guard let successorID, let store else { return "" }
        let records = (try? await store.actions(includeHistory: true)) ?? []
        guard let record = records.first(where: { $0.id == successorID }),
              let due = record.intent?.reminderFields?.desired?.due, due != .none else { return "" }
        return " · 下一次 " + due.shortLabel
    }
}
