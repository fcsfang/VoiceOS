import SwiftUI
import AppKit
import VoiceOSCore
import VoiceOSPlatform

struct WorkspaceMonitorView: View {
    @Environment(\.workspacePalette) private var palette
    @ObservedObject var model: ControlCenter
    @ObservedObject private var operations = ControlCenter.monitorOperations

    @State private var selectedReportID: String?
    @State private var historyExpanded = false
    @State private var expandedItems: Set<String> = []
    @State private var qqPythonPath = ""
    @State private var qqKeyPath = ""
    @State private var qqAccount = ""
    @State private var qqScriptOverride = ""
    @State private var qqStart = Date()
    @State private var qqPythonProbe: QQMonitorPythonProbe?
    @State private var qqPythonChecking = false
    @State private var qqKeyReadable: Bool?
    @State private var qqListedAccount: String?
    @State private var selectedConversationID: String?
    @State private var webhookDraft = ""
    @State private var pendingSourceRemoval: MonitorSource?
    @State private var formLoaded = false
    @State private var showsSettings = false
    @State private var showsAllItems = false
    @State private var handledExpanded = false
    @State private var monitorLoadState: MonitorLoadState = .loading
    @State private var monitorRetrying = false
    @State private var showSlowLoad = false
    @State private var failedItemReportIDs: Set<String> = []
    @State private var earlierOpenSummary = MonitorOpenItemsSummary()
    @State private var qqSaveFeedback = ""
    @State private var qqSaveFailed = false

    @State private var expandedItemDetails = Set<String>()
    private enum MonitorLoadState: Equatable { case loading, loaded, failed }

    private var monitorLoaded: Bool { monitorLoadState == .loaded }

    var body: some View {
        VStack(alignment: .leading, spacing: WorkspaceMetrics.sectionGap) {
            WorkspacePageHeading(title: "消息监测") {
                Picker("消息监测页面", selection: $showsSettings) {
                    Text("报告").tag(false)
                    Text("设置").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 172)
                .accessibilityIdentifier("monitor.page")
            }
            VStack(alignment: .leading, spacing: WorkspaceMetrics.sectionGap) {
                if showsSettings {
                    settingsSection
                    sourceStatusSection
                } else {
                    monitorLoadFailureNotice
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 24) {
                            todayReportSection.frame(minWidth: 520)
                            Divider()
                            runBar.frame(width: 196, alignment: .leading)
                        }
                        VStack(alignment: .leading, spacing: 16) {
                            todayReportSection
                            runBar
                        }
                    }
                    DisclosureGroup(isExpanded: $historyExpanded) {
                        historySection
                    } label: {
                        WorkspaceSectionHeading("历史报告", count: monitorLoaded ? String(earlierReports.count) : nil)
                    }
                    .accessibilityIdentifier("monitor.history.toggle")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            model.monitorPageVisible = true
            model.markMonitorAttentionSeen()
            if !formLoaded {
                formLoaded = true
                let loaded = MonitorQQSettingsStore.loadResult()
                model.recordMonitorQQSettingsLoad(decodeFailed: loaded.decodeFailed)
                let user = loaded.settings
                qqPythonPath = user.pythonPath.isEmpty ? MonitorQQSettingsStore.resolvedPythonPath(user) : user.pythonPath
                qqKeyPath = user.keyPath
                qqAccount = user.account
                qqScriptOverride = user.scriptPathOverride
                qqStart = Date()
            }
            consumeMonitorSettingsRequest()
            if showsSettings { probeQQDependenciesIfNeeded() }
            Task {
                await model.ensureBuiltinMonitorSources()
                let loaded = await model.reloadMonitorState()
                monitorLoadState = loaded ? .loaded : .failed
                markLatestItemsFailure()
                earlierOpenSummary = await model.monitorOpenItemsSummary(todayKey: todayKey)
                model.markMonitorAttentionSeen()
            }
        }
        .onDisappear { model.monitorPageVisible = false }
        .onChange(of: showsSettings) { _, shows in
            if shows { probeQQDependenciesIfNeeded() }
        }
        .onChange(of: model.monitorSettingsRequested) { _, _ in
            consumeMonitorSettingsRequest()
        }
        .onChange(of: model.monitorReports) { _, _ in
            markLatestItemsFailure()
            Task { await refreshEarlierOpenSummary() }
        }
        .onChange(of: model.monitorItemsByReport) { _, _ in
            markLatestItemsFailure()
        }
        .onChange(of: model.monitorChecking) { wasChecking, isChecking in
            guard wasChecking, !isChecking else { return }
            announceMonitorCheckCompletion()
        }
        .workspaceSlowLoading(monitorLoadState == .loading, into: $showSlowLoad)
        .alert("删除监测来源？", isPresented: Binding(
            get: { pendingSourceRemoval != nil },
            set: { if !$0 { pendingSourceRemoval = nil } })) {
            Button("取消", role: .cancel) { pendingSourceRemoval = nil }
            Button("删除", role: .destructive) {
                if let source = pendingSourceRemoval { Task { await model.removeMonitorSource(source) } }
                pendingSourceRemoval = nil
            }
        } message: {
            Text("将删除「\(pendingSourceRemoval?.displayName ?? "")」及其已采集消息与游标；已有报告与事项保留。")
        }
    }

    private var todayKey: String { MonitorSourceConfigParser.dayString(Date()) }

    private func localizedReportDate(_ key: String) -> String {
        guard let date = TimestampFormatting.dayKey.date(from: key) else { return key }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    private var qqNeedsFullDiskAccess: Bool {
        model.monitorQQDiagnostics.contains { !$0.ok && $0.needsFullDiskAccess }
            || QQMonitorPermissionGuidance.matches(model.monitorQQConversationStatus)
    }

    private var runBar: some View {
        VStack(alignment: .leading, spacing: WorkspaceMetrics.rowGap) {
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    Task {
                        await model.runMonitorCheck()
                        markLatestItemsFailure()
                        await refreshEarlierOpenSummary()
                    }
                } label: {
                    HStack(spacing: 7) {
                        if model.monitorChecking { ProgressView().controlSize(.small) }
                        Text(model.monitorChecking ? "正在检查（\(model.monitorPhase)）" : "立即检查")
                    }
                }
                .buttonStyle(.workspaceSecondary)
                .disabled(model.monitorChecking)
                .accessibilityLabel(model.monitorChecking ? "正在检查消息监测" : "立即检查消息监测")
                .accessibilityIdentifier("monitor.runCheck")
                Text(model.monitorNextRunText).vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
            }
            if !model.monitorStatus.isEmpty {
                Text(model.monitorStatus).vosFont(WorkspaceText.meta)
                    .foregroundStyle(palette.secondaryText).textSelection(.enabled)
            }
        }
    }

    private func announceMonitorCheckCompletion() {
        guard let report = model.monitorLatestReport else {
            AccessibilityNotification.Announcement("检查结束").post()
            return
        }
        switch report.state {
        case .failed:
            AccessibilityNotification.Announcement("检查未完成").post()
        case .incomplete:
            AccessibilityNotification.Announcement("检查结束，不完整，" + monitorOpenCountText()).post()
        case .complete:
            AccessibilityNotification.Announcement("检查完成，" + monitorOpenCountText()).post()
        }
    }

    private func monitorOpenCountText() -> String {
        let open = model.monitorOpenItemCount
        return open > 0 ? "\(open) 项待办" : "没有待办"
    }


    @ViewBuilder private var monitorLoadFailureNotice: some View {
        if monitorLoadState == .failed {
            HStack(spacing: 10) {
                WorkspaceNoticeText(message: model.monitorStatus.isEmpty
                                    ? "读取监测数据失败，报告与来源状态未能载入。"
                                    : "读取监测数据失败：" + model.monitorStatus,
                                    severity: .danger)
                Button {
                    Task { await retryMonitorLoad() }
                } label: {
                    HStack(spacing: 7) {
                        if monitorRetrying { ProgressView().controlSize(.small) }
                        Text("重新读取")
                    }
                }
                    .buttonStyle(.workspaceSecondaryCompact)
                    .disabled(monitorRetrying)
                    .accessibilityIdentifier("monitor.load.retry")
            }
            .accessibilityIdentifier("monitor.load.failure")
        }
    }

    private func retryMonitorLoad() async {
        guard !monitorRetrying else { return }
        monitorRetrying = true
        showSlowLoad = false
        defer { monitorRetrying = false }
        let loaded = await model.reloadMonitorState()
        monitorLoadState = loaded ? .loaded : .failed
        markLatestItemsFailure()
        earlierOpenSummary = await model.monitorOpenItemsSummary(todayKey: todayKey)
    }

    @ViewBuilder private var todayReportSection: some View {
        if monitorLoadState == .loading, !showSlowLoad {
            EmptyView()
        } else {
            WorkspaceSettingsCard(title: "今日报告", subtitle: todayReportSubtitle) {
                if monitorLoadState == .loading {
                    monitorLoadingRow("正在读取今日报告…")
                        .padding(.horizontal, 20)
                        .padding(.bottom, 4)
                } else if let report = model.monitorLatestReport, report.reportDate == todayKey {
                    reportCardContent(report: report, isLatest: true)
                } else if monitorLoadState == .failed {
                    Text("暂时无法读取今日报告。修复后点「重新读取」。")
                        .vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(model.monitorLatestReport.map { "最近一次报告是 " + $0.reportDate + "；今天还没有检查。" }
                             ?? "还没有报告；点击「立即检查」开始第一次检查。")
                            .vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
                        earlierOpenItemsHint
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                }
            }
        }
    }

    private var todayReportSubtitle: String? {
        guard monitorLoadState != .loading,
              let report = model.monitorLatestReport, report.reportDate == todayKey else { return nil }
        return localizedReportDate(report.reportDate) + " · " + ControlCenter.monitorStateText(report.state)
    }

    private var earlierReports: [MonitorReport] {
        model.monitorReports.filter { $0.reportDate != todayKey }
    }

    private var historySection: some View {
        Group {
            VStack(alignment: .leading, spacing: 12) {
                if monitorLoadState == .loading {
                    if showSlowLoad { monitorLoadingRow("正在读取历史报告…") }
                } else if earlierReports.isEmpty {
                    Text(monitorLoadState == .failed ? "暂时无法读取历史报告。" : "还没有更早的历史报告。")
                        .vosFont(WorkspaceText.meta)
                        .foregroundStyle(palette.secondaryText).padding(.vertical, 10)
                } else {
                    ForEach(earlierReports) { report in
                        WorkspaceRow(
                            title: report.headline.isEmpty ? "未命名报告" : report.headline,
                            subtitle: localizedReportDate(report.reportDate) + " · " + ControlCenter.monitorStateText(report.state)
                                + " · " + ControlCenter.monitorDeliveryText(report),
                            icon: report.reportDate == todayKey ? "doc.text" : "doc.text.magnifyingglass",
                            trailing: selectedReportID == report.id ? "收起" : "查看",
                            trailingStyle: .link) {
                            revealReport(report)
                        }.accessibilityIdentifier("monitor.history." + report.id)
                        if selectedReportID == report.id {
                            reportBody(report: report).padding(.leading, 20).padding(.bottom, 16)
                        }
                    }
                }
                if monitorLoaded, model.monitorReports.count >= ControlCenter.monitorReportLimit,
                   ControlCenter.monitorReportLimit < ControlCenter.monitorReportLimitCap {
                    Button("载入更早报告") { loadMoreReports() }
                        .buttonStyle(.workspaceQuietCompact)
                        .accessibilityIdentifier("monitor.history.loadMore")
                }
            }
            .padding(.horizontal, 20)
        }
    }


    private func reportCardContent(report: MonitorReport, isLatest: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            itemsView(report: report)
            if isLatest { earlierOpenItemsHint }
            WorkspaceListDivider()
            VStack(alignment: .leading, spacing: 10) {
                if report.state == .failed {
                    Text(report.headline).vosFont(WorkspaceText.rowTitle)
                    Text(report.summary).vosFont(WorkspaceText.body)
                } else if !report.headline.isEmpty || !report.summary.isEmpty {
                    DisclosureGroup("报告摘要") {
                        VStack(alignment: .leading, spacing: 6) {
                            if !report.headline.isEmpty { Text(report.headline).vosFont(WorkspaceText.rowTitle) }
                            if !report.summary.isEmpty { Text(report.summary).vosFont(WorkspaceText.body) }
                        }.textSelection(.enabled).padding(.vertical, 6)
                    }
                }
                HStack(spacing: 16) {
                    Text(ControlCenter.monitorDeliveryText(report)).vosFont(WorkspaceText.meta)
                        .foregroundStyle(report.deliveryState == "failed" ? palette.warning : palette.secondaryText)
                    Spacer()
                    if isLatest {
                        if report.state == .failed {
                            Button("去设置") { showsSettings = true }
                                .buttonStyle(.workspaceQuietCompact)
                                .accessibilityIdentifier("monitor.report.settings")
                            Button("重新检查") {
                                Task {
                                    await model.runMonitorCheck()
                                    markLatestItemsFailure()
                                    await refreshEarlierOpenSummary()
                                }
                            }
                                .buttonStyle(.workspaceSecondaryCompact)
                                .disabled(model.monitorChecking)
                                .accessibilityIdentifier("monitor.report.recheck")
                        } else if model.monitorPushConfigured {
                            Button { Task { await model.pushLatestMonitorReport() } } label: {
                                HStack(spacing: 7) {
                                    if operations.push == .report { ProgressView().controlSize(.small) }
                                    Text(operations.push == .report ? "正在推送…" : "立即推送今日报告")
                                }
                            }
                                .buttonStyle(.workspaceSecondaryCompact)
                                .disabled(operations.push != nil || model.monitorChecking)
                                .accessibilityIdentifier("monitor.report.push")
                        } else {
                            Button("配置微信推送") { showsSettings = true }
                                .buttonStyle(.workspaceQuietCompact)
                                .accessibilityIdentifier("monitor.report.pushConfigure")
                        }
                    }
                }
                if isLatest, !model.monitorPushStatus.isEmpty {
                    Text(model.monitorPushStatus).vosFont(WorkspaceText.meta)
                        .foregroundStyle(palette.secondaryText).textSelection(.enabled)
                }
                sourceFailureReasons(report)
                if let generated = ControlCenter.monitorGeneratedText(report) {
                    Text(generated).vosFont(WorkspaceText.caption).foregroundStyle(palette.secondaryText)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    @ViewBuilder private func reportBody(report: MonitorReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !report.summary.isEmpty {
                Text(report.summary).vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
            }
            HStack(spacing: 16) {
                Text(ControlCenter.monitorStateText(report.state)).vosFont(WorkspaceText.meta)
                Text(itemCountText(report)).vosFont(WorkspaceText.meta.size, monospacedDigit: true)
                    .foregroundStyle(palette.secondaryText)
                Text(ControlCenter.monitorDeliveryText(report)).vosFont(WorkspaceText.meta)
                    .foregroundStyle(report.deliveryState == "failed" ? palette.warning : palette.secondaryText)
                if let generated = ControlCenter.monitorGeneratedText(report) {
                    Text(generated).vosFont(WorkspaceText.meta).foregroundStyle(palette.tertiaryText)
                }
            }
            sourceFailureReasons(report)
            itemsView(report: report)
        }
    }

    @ViewBuilder private func itemsView(report: MonitorReport) -> some View {
        switch MonitorItemsPresentation.resolve(items: model.monitorItemsByReport[report.id],
                                                loadFailed: failedItemReportIDs.contains(report.id)) {
        case .loading:
            monitorLoadingRow("正在读取事项…")
        case .failed:
            HStack(spacing: 12) {
                Text("事项读取失败。")
                    .vosFont(WorkspaceText.meta).foregroundStyle(palette.warning)
                Button("重新读取") { Task { await loadItems(report) } }
                    .buttonStyle(.workspaceSecondaryCompact)
                    .accessibilityIdentifier(report.id == model.monitorLatestReport?.id
                                             ? "monitor.report.retryItems"
                                             : "monitor.report.retryItems." + report.id)
                Spacer()
            }.padding(.vertical, 6)
        case .empty:
            Text(emptyItemsText(report))
                .vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText).padding(.vertical, 6)
        case .items:
            let items = model.monitorItemsByReport[report.id] ?? []
            let openItems = items.filter { $0.status == .open }
            if openItems.count < items.count {
                Picker("事项筛选", selection: $showsAllItems) {
                    Text("未处理").tag(false)
                    Text("全部").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize(horizontal: true, vertical: false)
                .padding(.top, 4)
                .accessibilityIdentifier("monitor.filter")
            }
            ForEach([MonitorItemCategory.applicable, .needsCheck], id: \.self) { category in
                let group = openItems.filter { $0.category == category }
                if !group.isEmpty {
                    Text((category == .applicable ? "适用" : "待核对") + " \(group.count)")
                        .vosFont(WorkspaceText.meta.size, weight: .semibold, design: .default, monospacedDigit: true)
                        .foregroundStyle(palette.secondaryText).padding(.top, WorkspaceMetrics.groupGap)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(group) { item in itemView(item) }
                }
            }
            if openItems.isEmpty {
                let handledCount = items.count - openItems.count
                Text(handledCount > 0 && !showsAllItems
                     ? "已处理 \(handledCount) 项，切换「全部」查看"
                     : "没有未处理的事项。")
                    .vosFont(WorkspaceText.meta.size, monospacedDigit: true).foregroundStyle(palette.tertiaryText).padding(.vertical, 6)
            }
            if showsAllItems {
                let handled = items.filter { $0.status != .open }
                if !handled.isEmpty {
                    DisclosureGroup(isExpanded: $handledExpanded) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(handled) { item in itemView(item) }
                        }.padding(.top, 6)
                    } label: {
                        Text("已处理（\(handled.count)）")
                            .vosFont(WorkspaceText.meta.size, weight: .semibold, design: .default, monospacedDigit: true)
                            .foregroundStyle(palette.secondaryText)
                            .accessibilityAddTraits(.isHeader)
                    }.padding(.top, 8)
                }
            }
        }
    }

    private func itemCountText(_ report: MonitorReport) -> String {
        guard let items = model.monitorItemsByReport[report.id] else {
            return failedItemReportIDs.contains(report.id) ? "事项读取失败" : "正在读取事项…"
        }
        let tally = MonitorItemTally(items: items)
        return "未处理 \(tally.open) · 已处理 \(tally.handled)"
    }

    private func emptyItemsText(_ report: MonitorReport) -> String {
        switch report.state {
        case .failed: return "报告未完成，暂无事项。"
        case .incomplete: return "检查不完整，可能漏项"
        case .complete: return "没有需要关注的事项。"
        }
    }

    private func monitorLoadingRow(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
        }.padding(.vertical, 8)
    }

    private func revealReport(_ report: MonitorReport) {
        guard selectedReportID != report.id else {
            selectedReportID = nil
            return
        }
        selectedReportID = report.id
        Task { await loadItems(report) }
    }

    private func expandEarlierReport(_ reportID: String) {
        historyExpanded = true
        guard let report = model.monitorReports.first(where: { $0.id == reportID }) else { return }
        selectedReportID = report.id
        Task { await loadItems(report) }
    }

    private func loadItems(_ report: MonitorReport) async {
        failedItemReportIDs.remove(report.id)
        _ = await model.loadMonitorItems(reportID: report.id)
        if model.monitorItemsByReport[report.id] == nil { failedItemReportIDs.insert(report.id) }
    }

    private func markLatestItemsFailure() {
        guard let latest = model.monitorLatestReport else { return }
        if model.monitorItemsByReport[latest.id] == nil { failedItemReportIDs.insert(latest.id) }
        else { failedItemReportIDs.remove(latest.id) }
    }

    private func refreshEarlierOpenSummary() async {
        earlierOpenSummary = await model.monitorOpenItemsSummary(todayKey: todayKey)
    }

    private func loadMoreReports() {
        Task {
            await model.loadMoreMonitorReports()
            markLatestItemsFailure()
            await refreshEarlierOpenSummary()
        }
    }

    @ViewBuilder private var earlierOpenItemsHint: some View {
        let summary = earlierOpenSummary
        if summary.earlierCount > 0 || summary.unreachableCount > 0 {
            HStack(spacing: 10) {
                if summary.earlierCount > 0 {
                    WorkspaceBadge(text: "\(summary.earlierCount) 项", tone: .warning)
                    Text("更早报告还有 \(summary.earlierCount) 项未处理"
                         + (summary.earliestReportDate.map { "（最早 \($0)）" } ?? ""))
                        .vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
                }
                Spacer(minLength: 0)
                if summary.unreachableCount > 0 {
                    Text("另有 \(summary.unreachableCount) 项在更早报告里")
                        .vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
                    if ControlCenter.monitorReportLimit < ControlCenter.monitorReportLimitCap {
                        Button("载入更早报告") { loadMoreReports() }
                            .buttonStyle(.workspaceQuietCompact)
                            .accessibilityIdentifier("monitor.earlierOpen.loadMore")
                    }
                }
                if summary.earlierCount > 0, let reportID = summary.earliestReportID {
                    Button("展开最早的报告") { expandEarlierReport(reportID) }
                        .buttonStyle(.workspaceQuietCompact)
                        .accessibilityIdentifier("monitor.earlierOpen.expand")
                }
            }
            .padding(.vertical, 6)
        }
    }

    private func itemView(_ item: MonitorItem) -> some View {
        let expanded = expandedItemDetails.contains(item.id)
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                if expanded { expandedItemDetails.remove(item.id) } else { expandedItemDetails.insert(item.id) }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption).foregroundStyle(palette.secondaryText).frame(width: 12)
                    Text(item.title).vosFont(WorkspaceText.rowTitle.size, weight: .medium)
                        .strikethrough(item.status == .dismissed)
                    Spacer(minLength: 12)
                    Text(timeLabel(item))
                        .vosFont(WorkspaceText.meta)
                        .foregroundStyle(item.deadlineDate == nil && item.deadlineText == nil
                                         ? palette.tertiaryText : palette.secondaryText)
                }
                .padding(.vertical, 10).padding(.horizontal, 6)
                .contentShape(Rectangle()).workspaceHoverHighlight()
            }.buttonStyle(.plain)
                .accessibilityLabel(itemRowAccessibilityLabel(item))
                .accessibilityValue(expanded ? "已展开" : "已收起")
                .accessibilityIdentifier("monitor.item." + item.id + ".details")
            if expanded {
                VStack(alignment: .leading, spacing: 10) {
                    if !item.suggestedAction.isEmpty {
                        Text(item.suggestedAction).vosFont(WorkspaceText.body).foregroundStyle(palette.secondaryText)
                    }
                    if let uncertainty = item.uncertainty, !uncertainty.isEmpty {
                        Text(uncertainty).vosFont(WorkspaceText.meta).foregroundStyle(palette.warning)
                    }
                    evidenceView(item)
                    HStack(spacing: 12) {
                        if item.status == .open {
                            Button("标记完成") {
                                Task {
                                    await model.setMonitorItemStatus(item, status: .done)
                                    await refreshEarlierOpenSummary()
                                }
                            }
                                .buttonStyle(.workspaceSecondaryCompact)
                                .accessibilityIdentifier("monitor.item." + item.id + ".complete")
                            Button("不适用") {
                                Task {
                                    await model.setMonitorItemStatus(item, status: .dismissed)
                                    await refreshEarlierOpenSummary()
                                }
                            }
                                .buttonStyle(.workspaceQuietCompact)
                                .accessibilityIdentifier("monitor.item." + item.id + ".dismiss")
                        } else {
                            Button("重新打开") {
                                Task {
                                    await model.setMonitorItemStatus(item, status: .open)
                                    await refreshEarlierOpenSummary()
                                }
                            }
                                .buttonStyle(.workspaceQuietCompact)
                                .accessibilityIdentifier("monitor.item." + item.id + ".reopen")
                        }
                        Spacer()
                    }
                }.padding(.leading, 28).padding(.bottom, 10)
            }
            WorkspaceListDivider()
        }
    }

    private func timeLabel(_ item: MonitorItem) -> String {
        guard let time = item.deadlineText, !time.isEmpty else { return item.deadlineDate ?? "时间待核对" }
        guard let match = item.evidenceQuote.range(of: time) else { return time }
        let before = item.evidenceQuote[..<match.lowerBound].suffix(16)
            .trimmingCharacters(in: CharacterSet(charactersIn: "：: "))
        for label in ["报名截止", "网申截止", "截止", "宣讲时间", "考试时间", "活动时间"] {
            if before.hasSuffix(label) || before.hasSuffix(label + "时间") { return label + " · " + time }
        }
        if before.hasSuffix("宣讲安排\n时间") { return "宣讲时间 · " + time }
        return time
    }

    private func itemRowAccessibilityLabel(_ item: MonitorItem) -> String {
        let status = item.status == .done ? "已完成" : item.status == .dismissed ? "已忽略" : "待办"
        let deadline = timeLabel(item)
        return [status, item.title, deadline].joined(separator: "，")
    }

    @ViewBuilder private func evidenceView(_ item: MonitorItem) -> some View {
        let evidence = model.monitorEvidence[item.id] ?? []
        DisclosureGroup(isExpanded: Binding(
            get: { expandedItems.contains(item.id) },
            set: { expanded in
                if expanded { expandedItems.insert(item.id) } else { expandedItems.remove(item.id) }
            })) {
            VStack(alignment: .leading, spacing: 10) {
                if !item.whyRelevant.isEmpty { Text(item.whyRelevant).vosFont(WorkspaceText.meta) }
                if let conditions = item.conditions, !conditions.isEmpty { Text("条件：" + conditions).vosFont(WorkspaceText.meta) }
                if item.relatedItemID != nil { Text("已更新关联事项，处理状态已保留。").vosFont(WorkspaceText.meta) }
                Text(item.evidenceQuote).vosFont(WorkspaceText.body)
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) { Rectangle().fill(palette.border).frame(width: 2) }
                    .textSelection(.enabled)
                ForEach(evidence) { entry in
                    let body = evidenceBody(entry)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(evidenceLine(entry)).vosFont(WorkspaceText.meta)
                                .foregroundStyle(palette.secondaryText)
                            if let urlText = entry.url, let url = URL(string: urlText) {
                                Button("在浏览器打开原文") { NSWorkspace.shared.open(url) }
                                    .buttonStyle(.workspaceQuietCompact)
                            }
                            Spacer()
                        }
                        if entry.missing {
                            Text("原文未找到").vosFont(WorkspaceText.meta).foregroundStyle(palette.warning)
                        } else {
                            if !body.isEmpty {
                                Text(body).vosFont(WorkspaceText.meta).textSelection(.enabled)
                            }
                            if let quote = entry.replyQuote {
                                Text(quote).vosFont(WorkspaceText.meta)
                                    .foregroundStyle(palette.secondaryText).textSelection(.enabled)
                            }
                        }
                    }
                }
            }.padding(.top, 6)
        } label: {
            Text("原文与来源").vosFont(WorkspaceText.meta.size, weight: .medium)
        }.accessibilityIdentifier("monitor.item." + item.id + ".evidence")
    }

    private func evidenceLine(_ entry: MonitorItemEvidence) -> String {
        if entry.missing { return entry.sourceName }
        guard entry.sourceKind == .qqGroup else {
            if let title = entry.title, !title.isEmpty { return entry.sourceName + " · " + title }
            return entry.sourceName
        }
        var parts: [String] = ["QQ 群消息"]
        if let sender = entry.sender, !sender.isEmpty { parts.append(sender) }
        if let sentAt = entry.sentAt { parts.append(ControlCenter.monitorTimeText(sentAt)) }
        return parts.joined(separator: " · ")
    }

    private func evidenceBody(_ entry: MonitorItemEvidence) -> String {
        [MonitorEvidenceBuilder.kindLabel(entry.kind), entry.excerpt]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }

    @ViewBuilder private func sourceFailureReasons(_ report: MonitorReport) -> some View {
        if report.sourceStatusUnreadable {
            Text("状态无法读取").vosFont(WorkspaceText.meta).foregroundStyle(palette.warning)
        }
        let failures = report.sourceStatus.filter { !$0.ok }
        if !failures.isEmpty {
            DisclosureGroup("查看失败来源原因") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(failures, id: \.sourceID) { status in
                        Text(status.displayName + "：" + (status.error ?? "原因未知"))
                            .vosFont(WorkspaceText.meta).textSelection(.enabled)
                    }
                }.padding(.top, 6)
            }.vosFont(WorkspaceText.meta)
        }
    }

    private var sourceStatusSection: some View {
        WorkspaceSettingsCard(title: "来源状态") {
            if monitorLoadState == .loading {
                if showSlowLoad {
                    monitorLoadingRow("正在读取来源状态…")
                        .padding(.horizontal, 20)
                        .padding(.bottom, 4)
                }
            } else if monitorLoadState == .failed, model.monitorSources.isEmpty {
                Text("暂时无法读取来源状态。").vosFont(WorkspaceText.meta)
                    .foregroundStyle(palette.secondaryText)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
            } else if monitorLoaded, !model.monitorSources.contains(where: { $0.kind == .qqGroup }) {
                WorkspaceSettingsRow(title: "未添加 QQ 群来源", showsDivider: false) {
                    Button("去设置") { showsSettings = true }
                        .buttonStyle(.workspaceQuietCompact)
                        .accessibilityIdentifier("monitor.sources.settings")
                }
            }
            ForEach(model.monitorSources) { source in
                sourceRow(source)
            }
            ForEach(ControlCenter.monitorBuiltinWebsites) { item in
                if monitorLoaded, model.monitorSource(forBuiltinURL: item.url) == nil {
                    WorkspaceSettingsRow(title: "内置栏目未添加：\(item.name)") {
                        Button("添加内置来源") {
                            Task { await model.ensureBuiltinMonitorSources(restoreMissing: true) }
                        }
                            .buttonStyle(.workspaceSecondaryCompact)
                            .disabled(operations.addingBuiltinSources)
                            .accessibilityIdentifier("monitor.sources.addBuiltin")
                    }
                }
            }
        }
    }

    @ViewBuilder private func sourceRow(_ source: MonitorSource) -> some View {
        let stat = model.monitorSourceStats[source.id]
        WorkspaceSettingsRow(title: source.displayName, subtitle: sourceSubtitle(source)) {
            HStack(spacing: 10) {
                Toggle("启用", isOn: Binding(
                    get: { source.enabled },
                    set: { value in Task { await model.setMonitorSourceEnabled(source, enabled: value) } }))
                    .toggleStyle(.switch).labelsHidden().controlSize(.small)
                    .disabled(operations.sourceBusy.contains(source.id))
                    .accessibilityLabel((source.enabled ? "停用" : "启用") + "来源 " + source.displayName)
                    .accessibilityIdentifier("monitor.source." + source.id + ".enabled")
                Button("删除", role: .destructive) { pendingSourceRemoval = source }
                    .buttonStyle(.workspaceDestructive)
                    .accessibilityIdentifier("monitor.source." + source.id + ".delete")
            }
        }
        Text(sourceStatText(source, stat)).vosFont(WorkspaceText.meta)
            .foregroundStyle(stat?.lastError == nil ? palette.secondaryText : palette.warning)
            .textSelection(.enabled)
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
        WorkspaceSettingsRow(title: "从这里开始读取", subtitle: startNote(source), showsDivider: false) {
            DatePicker("", selection: Binding(
                get: { model.monitorSourceStartDate(source) ?? Date() },
                set: { date in Task { await setStart(source, date) } }),
                displayedComponents: source.kind == .qqGroup ? [.date, .hourAndMinute] : [.date])
                .labelsHidden().datePickerStyle(.field)
                .frame(minWidth: source.kind == .qqGroup ? 190 : 130)
                .disabled(operations.sourceBusy.contains(source.id))
                .accessibilityLabel("来源起始时间：" + source.displayName)
                .accessibilityIdentifier("monitor.source." + source.id + ".start")
        }
    }

    private func sourceSubtitle(_ source: MonitorSource) -> String {
        let kind = source.kind == .qqGroup ? "QQ 群" : "官网栏目"
        guard !source.enabled else { return kind }
        return [kind, "已停用，不参与每日检查；历史消息保留。"].joined(separator: " · ")
    }

    private func setStart(_ source: MonitorSource, _ date: Date) async {
        if source.kind == .qqGroup {
            await model.setMonitorQQStart(source, date: date)
        } else {
            await model.setMonitorWebsiteStart(source, date: date)
        }
    }

    private func sourceStatText(_ source: MonitorSource, _ stat: MonitorSourceStat?) -> String {
        var parts: [String] = []
        if let lastSuccess = stat?.lastSuccessAt {
            parts.append("最近成功采集：" + ControlCenter.monitorTimeText(lastSuccess))
        } else {
            parts.append("尚未成功采集")
        }
        if let error = stat?.lastError, !error.isEmpty {
            parts.append("最近错误：" + error)
        }
        parts.append("已采集 \(stat?.messageCount ?? 0) 条消息")
        if source.kind == .qqGroup {
            if let latest = stat?.latestMessageAt {
                parts.append("本地库最新消息：" + ControlCenter.monitorTimeText(latest))
            } else {
                parts.append("本地库还没有该群消息")
            }
        }
        return parts.joined(separator: " · ")
    }

    private func startNote(_ source: MonitorSource) -> String {
        switch model.monitorSourceStart(source) {
        case .invalid:
            return "配置无效"
        case .unset:
            return "尚未设置起始时间"
        case .date(let date):
            if source.kind == .qqGroup {
                return "将从 " + date.formatted(date: .abbreviated, time: .shortened) + " 开始读取，更早的群消息不导入"
            }
            return "起始日期 " + MonitorSourceConfigParser.dayString(date) + "；无发布时间的栏目条目仍会检查"
        }
    }

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: WorkspaceMetrics.sectionGap) {
            if model.monitorSettingsDecodeFailed || model.monitorQQSettingsDecodeFailed {
                WorkspaceNoticeText(message: "设置无法读取，已使用默认值，请重新保存", severity: .warning)
            }
            WorkspaceSettingsCard(title: "检查计划") {
                VStack(alignment: .leading, spacing: 14) {
                    scheduleSettings
                    WorkspaceListDivider()
                    authorizationSettings
                }
                .padding(.horizontal, 20).padding(.bottom, 14)
            }
            WorkspaceSettingsCard(title: "微信推送") {
                VStack(alignment: .leading, spacing: 14) { pushSettings }
                    .padding(.horizontal, 20).padding(.bottom, 14)
            }
            WorkspaceSettingsCard(title: "QQ 群读取") {
                VStack(alignment: .leading, spacing: 14) { qqSettings }
                    .padding(.horizontal, 20).padding(.bottom, 14)
            }
            if !model.monitorStatus.isEmpty {
                Text(model.monitorStatus).vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText).textSelection(.enabled)
            }
        }
    }

    private var scheduleSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("每日自动检查").vosFont(WorkspaceText.rowTitle)
                .help("应用退出时不自动运行，下次启动会补跑。")
            HStack(spacing: 12) {
                DatePicker("检查时间", selection: Binding(
                    get: { model.monitorScheduleDate },
                    set: { model.setMonitorScheduleTime($0) }),
                    displayedComponents: .hourAndMinute)
                    .labelsHidden().datePickerStyle(.field).frame(minWidth: 110)
                    .accessibilityLabel("每日检查时间")
                    .accessibilityIdentifier("monitor.settings.schedule.time")
                Text("默认 09:00；每天最多一次。").vosFont(WorkspaceText.meta)
                    .foregroundStyle(palette.secondaryText)
            }
            Text(model.monitorNextRunText).vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
        }
    }

    private var authorizationSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("允许云端分析监测内容", isOn: Binding(
                get: { model.monitorSettings.cloudAnalysisAuthorized },
                set: { value in model.updateMonitorSettings { $0.cloudAnalysisAuthorized = value } }))
                .toggleStyle(.switch).frame(maxWidth: 420, alignment: .leading)
                .accessibilityIdentifier("monitor.settings.cloudAuthorized")
                .help("默认关闭；关闭时检查在分析前停止。")
            Text("仅发送所选来源的新增原文；密钥与整库不发送。")
                .vosFont(WorkspaceText.caption).foregroundStyle(palette.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var pushSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("通道", selection: Binding(
                get: { model.monitorSettings.pushChannel?.rawValue ?? "" },
                set: { raw in model.setMonitorPushChannel(MonitorPushChannel(rawValue: raw)) })) {
                Text("未配置").tag("")
                Text("企业微信群机器人").tag(MonitorPushChannel.wecom.rawValue)
                Text("Server酱式").tag(MonitorPushChannel.serverChan.rawValue)
            }.pickerStyle(.segmented).frame(maxWidth: 420)
                .accessibilityLabel("推送通道")
                .accessibilityIdentifier("monitor.settings.push.channel")
            if let channel = model.monitorSettings.pushChannel {
                Text(channel.webhookHint).vosFont(WorkspaceText.caption).foregroundStyle(palette.tertiaryText)
            }
            HStack(spacing: 10) {
                SecureField("推送地址", text: $webhookDraft)
                    .workspaceFieldSurface().frame(maxWidth: 420)
                    .accessibilityLabel("推送地址")
                    .accessibilityIdentifier("monitor.settings.push.webhook")
                Button("保存地址") {
                    if model.saveMonitorWebhook(webhookDraft) { webhookDraft = "" }
                }
                    .buttonStyle(.workspaceSecondary)
                    .disabled(webhookDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("monitor.settings.push.save")
            }
            HStack(spacing: 8) {
                WorkspaceBadge(text: model.monitorWebhookTail.isEmpty ? "未保存地址" : "已保存 · 尾号 " + model.monitorWebhookTail,
                               tone: model.monitorWebhookTail.isEmpty ? .neutral : .success)
                Text("地址只保存在系统钥匙串。").vosFont(WorkspaceText.caption).foregroundStyle(palette.tertiaryText)
            }
            HStack(spacing: 12) {
                Button { Task { await model.sendMonitorPushTest() } } label: {
                    HStack(spacing: 7) {
                        if operations.push == .test { ProgressView().controlSize(.small) }
                        Text(operations.push == .test ? "正在发送测试…" : "发送测试")
                    }
                }
                    .buttonStyle(.workspaceQuiet)
                    .disabled(operations.push != nil || model.monitorSettings.pushChannel == nil)
                    .accessibilityIdentifier("monitor.settings.push.test")
                Button { Task { await model.pushLatestMonitorReport() } } label: {
                    HStack(spacing: 7) {
                        if operations.push == .report { ProgressView().controlSize(.small) }
                        Text(operations.push == .report ? "正在推送…" : "立即推送今日报告")
                    }
                }
                    .buttonStyle(.workspaceQuiet)
                    .disabled(operations.push != nil || model.monitorLatestReport == nil)
                    .accessibilityIdentifier("monitor.settings.push.pushNow")
                Spacer()
            }
            if !model.monitorTestPushStatus.isEmpty {
                Text(model.monitorTestPushStatus).vosFont(WorkspaceText.meta)
                    .foregroundStyle(palette.secondaryText).textSelection(.enabled)
            }
            if let report = model.monitorLatestReport {
                HStack(spacing: 8) {
                    Text("最近投递").vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
                    WorkspaceBadge(text: deliveryBadgeText(report), tone: deliveryBadgeTone(report))
                    if report.deliveryState == "failed", let error = report.deliveryError, !error.isEmpty {
                        Text(error).vosFont(WorkspaceText.caption).foregroundStyle(palette.tertiaryText).lineLimit(1)
                    }
                }
            }
            if !model.monitorPushStatus.isEmpty {
                Text(model.monitorPushStatus).vosFont(WorkspaceText.meta)
                    .foregroundStyle(palette.secondaryText).textSelection(.enabled)
            }
        }
    }

    private func deliveryBadgeText(_ report: MonitorReport) -> String {
        switch report.deliveryState {
        case "delivered": return "已推送"
        case "failed": return "推送失败"
        default: return "尚未推送"
        }
    }

    private func deliveryBadgeTone(_ report: MonitorReport) -> WorkspaceBadge.Tone {
        switch report.deliveryState {
        case "delivered": return .success
        case "failed": return .warning
        default: return .neutral
        }
    }

    private var qqSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("只保存路径、账号与群标识；密钥内容不会复制、进入日志或模型，也不会修改 QQ 或系统安全设置。")
                .vosFont(WorkspaceText.caption).foregroundStyle(palette.tertiaryText)
            pathRow("Python 解释器", text: $qqPythonPath, check: pythonCheck, choose: choosePython)
            pathRow("密钥文件", text: $qqKeyPath, check: keyCheck, choose: chooseKeyFile)
            HStack(spacing: 10) {
                Text("账号").vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
                    .frame(minWidth: 90, alignment: .leading).fixedSize(horizontal: true, vertical: false)
                TextField("可选，留空自动选择", text: $qqAccount)
                    .workspaceFieldSurface().frame(maxWidth: 360)
            }
            DisclosureGroup("高级") {
                VStack(alignment: .leading, spacing: 8) {
                    pathRow("读取脚本", text: $qqScriptOverride, choose: chooseScript)
                    Text("留空时自动查找应用包或仓库中的 scripts/qqmonitor/qq_read_range.py。")
                        .vosFont(WorkspaceText.caption).foregroundStyle(palette.tertiaryText)
                }.padding(.top, 8)
            }
            HStack(spacing: 12) {
                Button("保存 QQ 设置") { saveQQSettings() }
                    .buttonStyle(.workspaceSecondary)
                    .accessibilityIdentifier("monitor.settings.qq.save")
                Button {
                    saveQQSettings()
                    Task { await model.diagnoseMonitorQQ() }
                } label: {
                    HStack(spacing: 7) {
                        if operations.qq == .diagnose { ProgressView().controlSize(.small) }
                        Text(operations.qq == .diagnose ? "正在检查…" : "检查 QQ 依赖")
                    }
                }
                    .buttonStyle(.workspaceQuiet)
                    .disabled(operations.qq != nil)
                    .accessibilityIdentifier("monitor.settings.qq.diagnose")
                Button {
                    saveQQSettings()
                    Task {
                        qqListedAccount = await model.loadQQMonitorConversations()
                        if let account = qqListedAccount, let id = selectedConversationID,
                           model.monitorQQConversations.contains(where: { $0.id == id }) {
                            qqAccount = account
                        }
                    }
                } label: {
                    HStack(spacing: 7) {
                        if operations.qq == .list { ProgressView().controlSize(.small) }
                        Text(operations.qq == .list ? "正在列出群…" : "列出群")
                    }
                }
                    .buttonStyle(.workspaceQuiet)
                    .disabled(operations.qq != nil)
                    .accessibilityIdentifier("monitor.settings.qq.list")
                if !model.monitorQQDiagnosisStatus.isEmpty {
                    Text(model.monitorQQDiagnosisStatus).vosFont(WorkspaceText.meta)
                        .foregroundStyle(palette.secondaryText)
                }
            }
            if !qqSaveFeedback.isEmpty {
                Text(qqSaveFeedback).vosFont(WorkspaceText.meta)
                    .foregroundStyle(qqSaveFailed ? palette.warning : palette.secondaryText)
                    .textSelection(.enabled)
            }
            if !model.monitorQQDiagnostics.isEmpty {
                // Passing checks collapse into one line; only the ones that need
                // action are listed, so a healthy setup reads as one quiet fact.
                let failing = model.monitorQQDiagnostics.filter { !$0.ok }
                let passing = model.monitorQQDiagnostics.filter(\.ok)
                VStack(alignment: .leading, spacing: 6) {
                    if !passing.isEmpty {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(palette.success).accessibilityHidden(true)
                            Text(failing.isEmpty ? "环境检查全部通过（\(passing.count) 项）" : "\(passing.count) 项检查通过")
                                .vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
                        }
                        .help(passing.map { $0.title + "：" + $0.detail }.joined(separator: "\n"))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("通过：" + passing.map(\.title).joined(separator: "、"))
                    }
                    ForEach(failing) { item in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: item.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(item.ok ? palette.success : palette.warning)
                                .accessibilityHidden(true)
                            Text(item.title).vosFont(WorkspaceText.meta.size, weight: .semibold)
                            Text(item.detail).vosFont(WorkspaceText.meta)
                                .foregroundStyle(palette.secondaryText).textSelection(.enabled)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel((item.ok ? "通过，" : "需要处理，") + item.title + "，" + item.detail)
                    }
                }
            }
            if qqNeedsFullDiskAccess {
                VStack(alignment: .leading, spacing: 8) {
                    Text(QQMonitorPermissionGuidance.text).vosFont(WorkspaceText.meta)
                        .foregroundStyle(palette.warning).fixedSize(horizontal: false, vertical: true)
                    Button("打开系统设置") { openFullDiskAccessSettings() }
                        .buttonStyle(.workspaceQuiet)
                        .accessibilityIdentifier("monitor.settings.qq.openPrivacy")
                }
                .padding(10)
                .background(palette.warning.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: WorkspaceMetrics.controlRadius))
            }
            if !model.monitorQQConversationStatus.isEmpty {
                Text(model.monitorQQConversationStatus).vosFont(WorkspaceText.meta)
                    .foregroundStyle(palette.secondaryText).textSelection(.enabled)
            }
            if !model.monitorQQConversations.isEmpty {
                conversationPicker
            }
        }
    }

    private func probeQQDependenciesIfNeeded() {
        let keyPath = qqKeyPath.trimmingCharacters(in: .whitespacesAndNewlines)
        qqKeyReadable = keyPath.isEmpty ? nil : QQMonitorHelper.keyIsReadable(keyPath)
        let pythonPath = qqPythonPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pythonPath.isEmpty, qqPythonProbe == nil, !qqPythonChecking else { return }
        qqPythonChecking = true
        Task {
            let probe = await QQMonitorHelper().checkPython(pythonPath)
            qqPythonChecking = false
            qqPythonProbe = probe
        }
    }

    private func consumeMonitorSettingsRequest() {
        guard model.monitorSettingsRequested else { return }
        model.monitorSettingsRequested = false
        showsSettings = true
    }

    private var pythonCheck: (text: String, ok: Bool?)? {
        if qqPythonChecking { return ("正在检查…", nil) }
        guard let probe = qqPythonProbe else { return nil }
        return (probe.label, probe == .available)
    }

    private var keyCheck: (text: String, ok: Bool?)? {
        guard let readable = qqKeyReadable else { return nil }
        return readable ? ("可用", true) : ("不可用：文件缺失、为空或不可读", false)
    }

    private func pathRow(_ label: String, text: Binding<String>,
                         check: (text: String, ok: Bool?)? = nil,
                         choose: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Text(label).vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
                    .frame(minWidth: 90, alignment: .leading).fixedSize(horizontal: true, vertical: false)
                TextField(label, text: text)
                    .workspaceFieldSurface().frame(maxWidth: 360)
                Button("选择…", action: choose).buttonStyle(.workspaceQuietCompact)
            }
            if let check {
                Text(check.text).vosFont(WorkspaceText.caption)
                    .foregroundStyle(check.ok == true ? palette.success
                                     : check.ok == false ? palette.warning : palette.secondaryText)
            }
        }
    }

    private var conversationPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("选择要监测的群")
                .vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
            ForEach(model.monitorQQConversations) { conversation in
                Button {
                    selectedConversationID = conversation.id
                    if let account = qqListedAccount { qqAccount = account }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: selectedConversationID == conversation.id
                              ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(selectedConversationID == conversation.id
                                             ? palette.accent : palette.secondaryText)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(conversation.name).vosFont(WorkspaceText.body)
                            Text(conversationDetail(conversation)).vosFont(WorkspaceText.caption)
                                .foregroundStyle(palette.tertiaryText)
                        }
                        Spacer()
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityLabel("选择群 " + conversation.name)
                    .accessibilityIdentifier("monitor.settings.qq.conversation." + conversation.id)
            }
            HStack(spacing: 12) {
                Text("从这里开始读取").vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
                DatePicker("", selection: $qqStart, displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden().datePickerStyle(.field).frame(minWidth: 190)
                    .accessibilityLabel("QQ 起点")
                    .accessibilityIdentifier("monitor.settings.qq.start")
                Button {
                    guard let id = selectedConversationID,
                          let conversation = model.monitorQQConversations.first(where: { $0.id == id }) else { return }
                    Task {
                        if await model.addQQMonitorSource(conversation, start: qqStart) {
                            selectedConversationID = nil
                        }
                    }
                } label: {
                    HStack(spacing: 7) {
                        if operations.qq == .add { ProgressView().controlSize(.small) }
                        Text(operations.qq == .add ? "正在添加…" : "添加所选群")
                    }
                }
                    .buttonStyle(.workspaceSecondary)
                    .disabled(operations.qq != nil || selectedConversationID == nil)
                    .accessibilityIdentifier("monitor.settings.qq.addSelected")
                Spacer()
            }
        }.padding(.top, 4)
    }

    private func conversationDetail(_ conversation: QQMonitorConversation) -> String {
        var parts: [String] = []
        if let latest = conversation.latestAt {
            parts.append("最新消息 " + latest.formatted(date: .abbreviated, time: .shortened))
        } else {
            parts.append("没有最近消息")
        }
        parts.append("会话 " + conversation.id)
        return parts.joined(separator: " · ")
    }

    private func choosePython() {
        let panel = NSOpenPanel()
        panel.title = "选择已安装 qqnt-export-macos 的 Python"
        panel.prompt = "使用"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        let executableOnly = ExecutableOnlyPanelDelegate()
        panel.delegate = executableOnly
        panel.begin { response in
            withExtendedLifetime(executableOnly) {
                guard response == .OK, let url = panel.url else { return }
                qqPythonPath = url.path
                qqPythonProbe = nil
                qqPythonChecking = true
                Task {
                    let probe = await QQMonitorHelper().checkPython(url.path)
                    qqPythonChecking = false
                    qqPythonProbe = probe
                }
            }
        }
    }

    private func chooseKeyFile() {
        let panel = NSOpenPanel()
        panel.title = "选择 QQ 密钥文件"
        panel.prompt = "使用"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        panel.begin { response in
            if response == .OK, let url = panel.url {
                qqKeyPath = url.path
                qqKeyReadable = QQMonitorHelper.keyIsReadable(url.path)
            }
        }
    }

    private func chooseScript() {
        let panel = NSOpenPanel()
        panel.title = "选择 qq_read_range.py"
        panel.prompt = "使用"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.begin { response in
            if response == .OK, let url = panel.url { qqScriptOverride = url.path }
        }
    }

    private func saveQQSettings() {
        var settings = MonitorQQSettingsStore.load()
        settings.pythonPath = qqPythonPath
        settings.keyPath = qqKeyPath
        settings.account = qqAccount
        settings.scriptPathOverride = qqScriptOverride
        qqSaveFailed = !model.saveMonitorQQSettings(settings)
        qqSaveFeedback = model.monitorStatus
    }

    private func openFullDiskAccessSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
        if !NSWorkspace.shared.open(url) {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
        }
    }
}

private final class ExecutableOnlyPanelDelegate: NSObject, NSOpenSavePanelDelegate {
    func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return true }
        return isDirectory.boolValue || FileManager.default.isExecutableFile(atPath: url.path)
    }
}
