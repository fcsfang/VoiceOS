@testable import VoiceOSCore

/// A fake port's merge: dedupes identical candidate themes across batches by
/// title and summary and unions their viewpoints, which is what the real merge
/// request must do. Fixtures share it so every scenario exercises the same
/// apply path after the merge stage.
func mergedSkeletonMerge(_ input: TopicSkeletonMergeInput, responseID: String) -> TopicSkeletonMergeResult {
    var topics: [TopicSkeletonTopic] = [], index: [String: Int] = [:]
    for batch in input.batches {
        for candidate in batch.topics {
            let key = candidate.title + "\u{0}" + candidate.summary
            if let existing = index[key] {
                let topic = topics[existing]
                topics[existing] = TopicSkeletonTopic(topicID: topic.topicID, title: topic.title, summary: topic.summary,
                                                      questions: topic.questions,
                                                      viewpointIDs: topic.viewpointIDs + candidate.viewpointIDs)
            } else {
                index[key] = topics.count
                topics.append(TopicSkeletonTopic(topicID: candidate.topicID, title: candidate.title, summary: candidate.summary,
                                                 questions: [], viewpointIDs: candidate.viewpointIDs))
            }
        }
    }
    return TopicSkeletonMergeResult(briefing: "已合并 \(input.batches.count) 批骨架候选。",
                                    topics: topics, responseID: responseID)
}
