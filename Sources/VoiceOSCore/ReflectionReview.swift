import Foundation

public extension ReflectionPeriod {
    var reviewTitle: String {
        switch self {
        case .day: "找回这一天的思考现场"
        case .week: "连起这一周的认识"
        case .month: "看看这个月的认识变化"
        }
    }

    var reviewPurpose: String {
        switch self {
        case .day:
            "找回当天接触的材料、当时的想法与发生背景，留下值得继续思考的问题。"
        case .week:
            "围绕关心的问题，连接一周的材料与实践，辨认共同机制、不同条件、冲突和未解问题。"
        case .month:
            "根据用户前后真实表达和实践反馈，辨认认识如何形成、得到支持、被限定或修正；资料不足时明确指出。"
        }
    }

    func reviewPrompt(dateLabel: String, questionTitle: String? = nil) -> String {
        let subject = questionTitle.flatMap { title in
            title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : title
        }.map { "这次请聚焦我持续关心的问题「\($0)」。" } ?? ""
        let opening = "请和我一起回顾\(dateLabel)。\(subject)\(reviewPurpose)"
        let focus: String
        switch self {
        case .day:
            focus = "选出值得留下的思考，结合原话说明我当时为什么这样想；区分我自己的表达、接触的外部观点与你的推论。"
        case .week:
            focus = "说明这些材料共同回答了什么、观点在什么条件下相容或冲突，以及我还缺少哪些依据。提出跨主题联系时，请给出两侧原文依据、共同机制、差异和类比可能失效的边界。"
        case .month:
            focus = "如有前后表达，请并排比较我原先与现在的判断，说明哪些材料或实际结果可能支持这种变化；区分新增认识、条件补充与判断修正。没有前后原话时，请说明还不能确认变化。转写纠错不算认识成长，完成任务也不等于学会知识。"
        }
        return """
        \(opening)
        \(focus)
        每个关键判断都请附可打开的原文依据；新增联系和解释标为 AI 待核对推论，不替我认可。
        最后选择一个有依据、值得继续探索的问题，给出一份我能修改的小验证建议：要检验的判断、可以尝试什么、观察什么，以及结果不支持时怎样修正。建议不代表我已承诺，也不自动创建任务。若资料不足，请明确缺什么，不强行生成结论或实验。
        """
    }
}

/// These are editable discussion drafts. Selecting one never sends a request
/// or creates a task on the user's behalf.
public enum ReflectionReviewFollowup: String, CaseIterable, Sendable {
    case connection, counterexample, experiment

    public var label: String {
        switch self {
        case .connection: "核对联系"
        case .counterexample: "找反例"
        case .experiment: "设计小验证"
        }
    }

    public var prompt: String {
        switch self {
        case .connection:
            "请核对刚才提出的跨主题联系：分别引用两侧材料，解释共同机制、条件差异以及类比可能失效的边界。如果证据不足或联系牵强，请明确指出并修正。请将尚未证实的联系标为 AI 待核对推论。"
        case .counterexample:
            "请从已有资料寻找刚才判断的反例或不同条件，附原文依据，并说明它们会怎样限定或修正这个判断。没有实际反例时请直接说明；可以提出假设情形供我检验，但要明确标为假设。"
        case .experiment:
            "请把刚才一个值得验证的判断，写成我能修改的小验证建议：要检验的判断、可尝试什么、观察什么，以及结果不支持时怎样修正。区分已有结果与建议，不替我承诺、创建任务或声称已执行。"
        }
    }
}

public extension ConversationReflectionFocus {
    var reviewPurpose: String {
        isTopicOverview ? "跨时间梳理这个主题的当前理解、形成依据、不同判断、实践结果和未解问题；时间用于解释演化，不按周切断思考。" : reviewPeriod.reviewPurpose
    }

    var topicReviewPrompt: String {
        """
        请围绕「\(question?.title ?? "这个主题")」，跨时间梳理我们已经积累的全部关联材料。
        先说明当前理解及尚未解决的问题，再用原话和实际记录解释这些判断怎样形成、得到支持、被限定或改变。连接不同时间的材料，不把同一个主题切成独立周报。
        区分个人判断、外部观点和 AI 待核对推论；AI 代办报告是交付物，不代表我已认可结论或完成了实际验证。没有前后原话时不声称认识改变，纠错不算成长。
        每个关键判断附原文依据。最后提出一个最值得继续探索的问题，以及可修改的小验证建议；不替我承诺执行。
        """
    }

    /// Old saved discussions predate the explicit period field. Their date
    /// interval remains usable, including days across daylight-saving changes.
    var reviewPeriod: ReflectionPeriod {
        if let period { return period }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneID) ?? .current
        let days = calendar.dateComponents([.day], from: start, to: end).day ?? 0
        if days <= 1 { return .day }
        if days <= 7 { return .week }
        return .month
    }
}
