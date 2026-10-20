import Foundation

extension VoiceOSStore {
    /// Explicitly understand one personal turn through the existing cognition/action pipeline.
    /// Discussion replies and entry history are not added to this request or endorsed by it.
    public func understandConversationUserTurn(conversationID:String,turnID:String,using port:any ModelPort) async throws -> [String] {
        let session=try conversation(id:conversationID)
        guard session.validity == "current",let turn=try conversationUserTurns(conversationID:conversationID).first(where: { $0.id == turnID }) else { throw VoiceOSError("请选择尚未冻结的个人发言；AI回复不能冒充用户表达") }
        let context=try prepareLocalTranscriptContext(sourceIDs:[turn.sourceID])
        guard let source=context.sources.first,source.origin == "user",source.speaker == "user",source.transcriptVersionID == turn.transcriptVersionID else { throw VoiceOSError("个人发言版本已变化，请核对原文") }
        return try await understandSource(sourceID:turn.sourceID,using:port)
    }
}
