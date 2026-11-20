/// A theme is a concern the user keeps returning to; everything below the bar
/// stays a clue. Manual topics are the user's own judgment and always qualify.
public enum TopicLevel: Sendable, Equatable {
    case theme
    case clue

    public static let minimumMaterials = 3
    public static let minimumDistinctDays = 3

    public static func classify(materialCount: Int, distinctDays: Int, manual: Bool) -> TopicLevel {
        if manual { return .theme }
        return materialCount >= minimumMaterials && distinctDays >= minimumDistinctDays ? .theme : .clue
    }
}