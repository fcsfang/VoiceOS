import VoiceOSCore

extension ControlCenter {
    @discardableResult
    func undoActionState(actionID: String) async -> Bool {
        guard let store else { status = "资料库尚未打开"; return false }
        guard !savingAction else { status = "正在保存其他更改，请稍后重试"; return false }
        let record: ActionRecord
        do {
            guard let current = try await store.actions(includeHistory: true).first(where: { $0.id == actionID }) else {
                status = "找不到可以撤销的行动"
                return false
            }
            record = current
        } catch {
            status = error.localizedDescription
            return false
        }
        guard record.state != LocalActionState.open.rawValue else {
            await refresh()
            return true
        }
        await changeAction(record, state: .open)
        return actionRecords.first(where: { $0.id == actionID })?.state == LocalActionState.open.rawValue
    }

    func focusedActionIDs() async -> Set<String> {
        guard let store else { return [] }
        do { return try await store.focusedActionIDs() }
        catch {
            status = error.localizedDescription
            return []
        }
    }

    func toggleActionFocus(actionID: String) async -> Set<String>? {
        guard let store else { status = "资料库尚未打开"; return nil }
        do {
            _ = try await store.toggleActionFocus(actionID: actionID)
            return try await store.focusedActionIDs()
        } catch {
            status = error.localizedDescription
            return nil
        }
    }
}
