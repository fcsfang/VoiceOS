import SwiftUI
import VoiceOSCore

/// Content-first home: a timeline of recent recordings on the left, the
/// selected recording's own thoughts on the right. The map is a secondary view.
struct RecentContentHome: View {
    @Environment(\.workspacePalette) private var palette
    @ObservedObject var model: ControlCenter
    let openSource: (String) -> Void
    let capture: () -> Void
    @State private var selectedID: String?

    private var days: [RecentContentDay] { RecentContentIndex.build(sources: model.records, claims: model.claims) }
    private var items: [RecentContentItem] { days.flatMap(\.items) }
    private var selected: RecentContentItem? {
        items.first { $0.id == selectedID } ?? items.first { !$0.thoughts.isEmpty } ?? items.first
    }

    var body: some View {
        if items.isEmpty {
            empty
        } else {
            HStack(spacing: 0) {
                timeline.frame(width: 264)
                Rectangle().fill(palette.border).frame(width: 1)
                reader
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 14) {
            Text("还没有可以回看的内容").font(.title3.weight(.medium))
            Text("录一段想法，或写下几句。整理完成后，这里按时间显示你说过的想法。")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
            Button("记录想法") { capture() }.buttonStyle(.borderedProminent)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var timeline: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(days) { day in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(dayLabel(day.date)).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).padding(.horizontal, 10)
                        ForEach(day.items) { item in
                            Button { selectedID = item.id } label: { row(item) }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("recent.item")
                        }
                    }
                }
            }.padding(14)
        }
    }

    private func row(_ item: RecentContentItem) -> some View {
        let isSelected = selected?.id == item.id
        return VStack(alignment: .leading, spacing: 3) {
            Text(timeLabel(item.date)).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(item.title).font(.system(size: 13.5, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(palette.text).lineLimit(2).multilineTextAlignment(.leading)
            if !item.thoughts.isEmpty {
                Text("\(item.thoughts.count) 条想法").font(.system(size: 11)).foregroundStyle(.secondary)
            } else if item.kind == .feedback {
                Text("\(item.excerpts.count) 段反馈").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(isSelected ? palette.selection : .clear, in: RoundedRectangle(cornerRadius: 9))
    }

    @ViewBuilder private var reader: some View {
        if let item = selected {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(meta(item)).font(.system(size: 12)).foregroundStyle(.secondary)
                    Text(item.title).font(.system(size: 22, weight: .semibold)).textSelection(.enabled)
                    if !item.summary.isEmpty {
                        Text(item.summary).font(.system(size: 14)).lineSpacing(5).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    if item.kind == .feedback {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(Array(item.excerpts.enumerated()), id: \.offset) { index, excerpt in
                                if index > 0 { Divider() }
                                Text(excerpt).font(.system(size: 14.5)).lineSpacing(4).textSelection(.enabled)
                            }
                        }
                    }
                    if !item.thoughts.isEmpty {
                        Text("这次记录里的想法").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).padding(.top, 4)
                        VStack(alignment: .leading, spacing: 11) {
                            ForEach(item.thoughts) { thought in
                                HStack(alignment: .top, spacing: 10) {
                                    Circle().fill(palette.accent).frame(width: 5, height: 5).padding(.top, 8)
                                    Text(thought.statement).font(.system(size: 15)).lineSpacing(5).textSelection(.enabled)
                                }
                            }
                        }
                    }
                    if item.kind == .material, let first = item.sourceIDs.first {
                        Button("打开材料") { openSource(first) }.buttonStyle(.bordered).padding(.top, 4)
                    }
                }
                .frame(maxWidth: 720, alignment: .leading)
                .padding(30)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .id(item.id)
        } else {
            Color.clear
        }
    }

    private func meta(_ item: RecentContentItem) -> String {
        var parts = [dateLabel(item.date), timeLabel(item.date)]
        parts.append(item.kind == .feedback ? "行动反馈" : "材料")
        if !item.thoughts.isEmpty { parts.append("\(item.thoughts.count) 条想法") }
        return parts.joined(separator: " · ")
    }

    private func dayLabel(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "今天" }
        if calendar.isDateInYesterday(date) { return "昨天" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = calendar.isDate(date, equalTo: Date(), toGranularity: .year) ? "M月d日" : "yyyy年M月d日"
        return formatter.string(from: date)
    }

    private func dateLabel(_ date: Date) -> String { dayLabel(date) }

    private func timeLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}
