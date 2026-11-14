import VoiceOSCore

struct ActionChangeReceipt {
    let successorID: String?
    let keptSuccessorID: String?
}

extension ControlCenter {
    var canUndoActionChange: Bool { !actionUndoStack.isEmpty }

    func recordActionChange(_ action: ActionRecord, from: LocalActionState, to: LocalActionState, successorID: String? = nil) {
        actionUndoStack.record(ActionUndoEntry(actionID: action.id, title: action.title, from: from, to: to, successorID: successorID))
    }

    func undoLastActionChange() async {
        guard !savingAction else { status = "正在保存其他更改，请稍后重试"; return }
        guard let store else { status = "资料库尚未打开"; return }
        guard let entry = actionUndoStack.popLast() else { status = "没有可撤销的行动变更"; return }
        let record: ActionRecord
        do {
            guard let current = try await store.actions(includeHistory: true).first(where: { $0.id == entry.actionID }) else {
                status = "找不到这条行动"
                return
            }
            record = current
        } catch {
            status = error.localizedDescription
            return
        }
        guard record.state == entry.to.rawValue else { status = "这条行动已变化，无法撤销"; return }
        isUndoingActionChange = true; defer { isUndoingActionChange = false }
        let receipt = await changeAction(record, state: entry.from, successorID: entry.successorID)
        if actionRecords.first(where: { $0.id == entry.actionID })?.state == entry.from.rawValue {
            status = "已撤销「\(entry.title)」的变更" + (receipt?.keptSuccessorID == nil ? "" : " · 下一次已保留")
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
