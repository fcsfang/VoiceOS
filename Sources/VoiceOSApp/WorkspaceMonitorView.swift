import SwiftUI
import AppKit
import VoiceOSCore
import VoiceOSPlatform

struct WorkspaceMonitorView: View {
    @Environment(\.workspacePalette) private var palette
    @ObservedObject var model: ControlCenter

    @State private var selectedReportID: String?
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
    @State private var monitorLoaded = false
    @State private var failedItemReportIDs: Set<String> = []
    @State private var qqSaveFeedback = ""
    @State private var qqSaveFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: WorkspaceMetrics.sectionGap) {
            WorkspaceHeading(eyebrow: "每日消息监测", title: "消息监测",
                             subtitle: "每天检查一次 QQ 班级群与学院官网；需要行动的事项在这里跟进，微信收到每日汇总。")
            Picker("消息监测页面", selection: $showsSettings) {
                Text("报告").tag(false)
                Text("设置").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 172)
            .accessibilityIdentifier("monitor.page")
            if showsSettings {
                settingsSection
            } else {
                runBar
                todayReportSection
                historySection
                sourceStatusSection
            }
        }
        .onAppear {
            model.markMonitorAttentionSeen()
            if !formLoaded {
                formLoaded = true
                let user = MonitorQQSettingsStore.load()
                qqPythonPath = user.pythonPath.isEmpty ? MonitorQQSettingsStore.resolvedPythonPath(user) : user.pythonPath
                qqKeyPath = user.keyPath
                qqAccount = user.account
                qqScriptOverride = user.scriptPathOverride
                qqStart = Date()
            }
            Task {
                await model.ensureBuiltinMonitorSources()
                await model.reloadMonitorState()
                monitorLoaded = true
                model.markMonitorAttentionSeen()
            }
        }
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

    private var qqNeedsFullDiskAccess: Bool {
        model.monitorQQDiagnostics.contains { !$0.ok && $0.needsFullDiskAccess }
            || QQMonitorPermissionGuidance.matches(model.monitorQQConversationStatus)
    }

    private var runBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Button {
                    Task { await model.runMonitorCheck() }
                } label: {
                    HStack(spacing: 7) {
                        if model.monitorChecking { ProgressView().controlSize(.small) }
                        Text(model.monitorChecking ? "正在检查（\(model.monitorPhase)）" : "立即检查")
                    }
                }
                .disabled(model.monitorChecking)
                .accessibilityLabel(model.monitorChecking ? "正在检查消息监测" : "立即检查消息监测")
                .accessibilityIdentifier("monitor.runCheck")
                Text(model.monitorNextRunText).vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
            }
            if !model.monitorStatus.isEmpty {
                Text(model.monitorStatus).vosFont(WorkspaceText.meta)
                    .foregroundStyle(palette.secondaryText).textSelection(.enabled)
            }
            Text("每天最多自动检查一次。应用退出后不会自动运行，下次启动会补跑；运行中每 10 分钟只比对时间，不读 QQ、不调模型。")
                .vosFont(WorkspaceText.caption).foregroundStyle(palette.tertiaryText)
        }
    }

    @ViewBuilder private var todayReportSection: some View {
        if !monitorLoaded {
            WorkspaceSection(title: "今日报告", icon: "doc.text") {
                monitorLoadingRow("正在读取今日报告…")
            }
        } else if let report = model.monitorLatestReport, report.reportDate == todayKey {
            reportSection(title: "今日报告", report: report, isLatest: true)
        } else {
            WorkspaceSection(title: "今日报告",
                             subtitle: model.monitorLatestReport.map { "最近一次报告是 " + $0.reportDate + "；今天还没有检查。" }
                                ?? "还没有报告；点击「立即检查」开始第一次检查。",
                             icon: "doc.text") {
                Text("检查会先从已启用的来源采集，再按授权情况交给模型分析。云端分析未授权时不会发送任何原文。")
                    .vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText).padding(.vertical, 10)
            }
        }
    }

    private var earlierReports: [MonitorReport] {
        model.monitorReports.filter { $0.reportDate != todayKey }
    }

    private var historySection: some View {
        WorkspaceSection(title: "历史报告", subtitle: "最近 30 次检查中早于今天的报告；点开查看同结构内容。",
                         icon: "clock.arrow.circlepath", count: monitorLoaded ? earlierReports.count : nil) {
            if !monitorLoaded {
                monitorLoadingRow("正在读取历史报告…")
            } else if earlierReports.isEmpty {
                Text("还没有更早的历史报告。").vosFont(WorkspaceText.meta)
                    .foregroundStyle(palette.secondaryText).padding(.vertical, 10)
            } else {
                ForEach(earlierReports) { report in
                    WorkspaceRow(
                        title: report.headline.isEmpty ? "未命名报告" : report.headline,
                        subtitle: report.reportDate + " · " + ControlCenter.monitorStateText(report.state)
                            + " · " + ControlCenter.monitorDeliveryText(report),
                        icon: report.reportDate == todayKey ? "doc.text" : "doc.text.magnifyingglass",
                        trailing: selectedReportID == report.id ? "收起" : "查看") {
                        revealReport(report)
                    }.accessibilityIdentifier("monitor.history." + report.id)
                    if selectedReportID == report.id {
                        reportBody(report: report).padding(.leading, 20).padding(.bottom, 16)
                    }
                }
            }
        }
    }

    private func reportSection(title: String, report: MonitorReport, isLatest: Bool) -> some View {
        WorkspaceSection(title: title,
                         subtitle: report.reportDate + " · " + ControlCenter.monitorStateText(report.state),
                         icon: "doc.text") {
            VStack(alignment: .leading, spacing: 10) {
                Text(report.headline.isEmpty ? "没有标题" : report.headline).vosFont(WorkspaceText.rowTitle)
                if !report.summary.isEmpty {
                    Text(report.summary).vosFont(WorkspaceText.body)
                        .foregroundStyle(palette.secondaryText).lineSpacing(4)
                }
                HStack(spacing: 16) {
                    Text(itemCountText(report)).vosFont(WorkspaceText.meta)
                        .foregroundStyle(palette.secondaryText)
                    Text(ControlCenter.monitorDeliveryText(report)).vosFont(WorkspaceText.meta)
                        .foregroundStyle(report.deliveryState == "failed" ? palette.warning : palette.secondaryText)
                    Spacer()
                    if isLatest {
                        if report.state == .failed {
                            Button("去设置") { showsSettings = true }.vosFont(WorkspaceText.meta)
                                .accessibilityIdentifier("monitor.report.settings")
                            Button("重新检查") { Task { await model.runMonitorCheck() } }
                                .disabled(model.monitorChecking).vosFont(WorkspaceText.meta)
                                .accessibilityIdentifier("monitor.report.recheck")
                        } else {
                            Button("立即推送今日报告") { Task { await model.pushLatestMonitorReport() } }
                                .disabled(model.monitorChecking).vosFont(WorkspaceText.meta)
                                .accessibilityIdentifier("monitor.report.push")
                        }
                    }
                }
                sourceFailureReasons(report)
                itemsView(report: report)
            }.padding(.vertical, 12)
        }
    }

    @ViewBuilder private func reportBody(report: MonitorReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !report.summary.isEmpty {
                Text(report.summary).vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
            }
            HStack(spacing: 16) {
                Text(ControlCenter.monitorStateText(report.state)).vosFont(WorkspaceText.meta)
                Text(itemCountText(report)).vosFont(WorkspaceText.meta)
                    .foregroundStyle(palette.secondaryText)
                Text(ControlCenter.monitorDeliveryText(report)).vosFont(WorkspaceText.meta)
                    .foregroundStyle(report.deliveryState == "failed" ? palette.warning : palette.secondaryText)
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
            Text("事项读取失败，请收起后重新展开重试。")
                .vosFont(WorkspaceText.meta).foregroundStyle(palette.warning).padding(.vertical, 6)
        case .empty:
            Text(emptyItemsText(report))
                .vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText).padding(.vertical, 6)
        case .items:
            let items = model.monitorItemsByReport[report.id] ?? []
            let openItems = items.filter { $0.status == .open }
            Picker("事项筛选", selection: $showsAllItems) {
                Text("未处理").tag(false)
                Text("全部").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 140)
            .padding(.top, 4)
            .accessibilityIdentifier("monitor.filter")
            ForEach([MonitorItemCategory.applicable, .needsCheck], id: \.self) { category in
                let group = openItems.filter { $0.category == category }
                if !group.isEmpty {
                    Text((category == .applicable ? "适用" : "待核对") + " \(group.count)")
                        .vosFont(WorkspaceText.meta.size, weight: .semibold)
                        .foregroundStyle(palette.secondaryText).padding(.top, 8)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(group) { item in itemView(item) }
                }
            }
            if openItems.isEmpty {
                Text("没有未处理的事项。")
                    .vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText).padding(.vertical, 6)
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
                            .vosFont(WorkspaceText.meta.size, weight: .semibold)
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
        case .failed: return "报告未完成，暂无事项。先处理上方原因，再重新检查。"
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
        failedItemReportIDs.remove(report.id)
        Task {
            _ = await model.loadMonitorItems(reportID: report.id)
            if model.monitorItemsByReport[report.id] == nil { failedItemReportIDs.insert(report.id) }
        }
    }

    private func itemView(_ item: MonitorItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: item.status == .done ? "checkmark.circle.fill"
                        : item.status == .dismissed ? "xmark.circle" : "circle")
                    .foregroundStyle(item.status == .done ? palette.success : palette.secondaryText)
                Text(item.title).vosFont(WorkspaceText.rowTitle)
                    .strikethrough(item.status == .dismissed)
                Spacer()
                Text(item.deadlineText ?? (item.deadlineDate.map { "截止 " + $0 } ?? "截止待核对"))
                    .vosFont(WorkspaceText.meta)
                    .foregroundStyle(item.deadlineDate == nil && item.deadlineText == nil
                                     ? palette.warning : palette.secondaryText)
            }
            Text("为什么相关：" + item.whyRelevant).vosFont(WorkspaceText.body)
            Text("建议行动：" + item.suggestedAction).vosFont(WorkspaceText.body)
                .foregroundStyle(palette.secondaryText)
            if let conditions = item.conditions, !conditions.isEmpty {
                Text("条件：" + conditions).vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
            }
            if let uncertainty = item.uncertainty, !uncertainty.isEmpty {
                Text("待核对：" + uncertainty).vosFont(WorkspaceText.meta).foregroundStyle(palette.warning)
            }
            if item.relatedItemID != nil {
                Text("与已有事项关联，本次更新了原事项并保留你的处理状态。")
                    .vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
            }
            evidenceView(item)
            HStack(spacing: 12) {
                if item.status == .open {
                    Button("标记完成") { Task { await model.setMonitorItemStatus(item, status: .done) } }
                        .vosFont(WorkspaceText.meta)
                        .accessibilityIdentifier("monitor.item." + item.id + ".complete")
                    Button("不适用") { Task { await model.setMonitorItemStatus(item, status: .dismissed) } }
                        .vosFont(WorkspaceText.meta)
                        .accessibilityIdentifier("monitor.item." + item.id + ".dismiss")
                } else {
                    Button("重新打开") { Task { await model.setMonitorItemStatus(item, status: .open) } }
                        .vosFont(WorkspaceText.meta)
                        .accessibilityIdentifier("monitor.item." + item.id + ".reopen")
                }
                Spacer()
            }
        }
        .padding(14)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: WorkspaceMetrics.panelRadius))
        .overlay {
            RoundedRectangle(cornerRadius: WorkspaceMetrics.panelRadius)
                .strokeBorder(palette.border.opacity(0.7), lineWidth: 1)
        }
        .padding(.bottom, 6)
    }

    @ViewBuilder private func evidenceView(_ item: MonitorItem) -> some View {
        let evidence = model.monitorEvidence[item.id] ?? []
        DisclosureGroup(isExpanded: Binding(
            get: { expandedItems.contains(item.id) },
            set: { expanded in
                if expanded { expandedItems.insert(item.id) } else { expandedItems.remove(item.id) }
            })) {
            VStack(alignment: .leading, spacing: 10) {
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
                                Button("在浏览器打开原文") { NSWorkspace.shared.open(url) }.vosFont(WorkspaceText.meta)
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
        WorkspaceSection(title: "来源状态",
                         subtitle: "QQ 显示 VoiceOS 本地库中的最新消息时间；没有新消息不等于采集失败，失败会单独标出。",
                         icon: "antenna.radiowaves.left.and.right") {
            if !monitorLoaded {
                monitorLoadingRow("正在读取来源状态…")
            } else if !model.monitorSources.contains(where: { $0.kind == .qqGroup }) {
                HStack(spacing: 12) {
                    Text("未添加 QQ 群来源").vosFont(WorkspaceText.body)
                    Button("去设置") { showsSettings = true }.vosFont(WorkspaceText.meta)
                        .accessibilityIdentifier("monitor.sources.settings")
                    Spacer()
                }.padding(.vertical, 8)
            }
            ForEach(model.monitorSources) { source in
                sourceRow(source)
            }
            ForEach(ControlCenter.monitorBuiltinWebsites) { item in
                if monitorLoaded, model.monitorSource(forBuiltinURL: item.url) == nil {
                    HStack(spacing: 12) {
                        Text("内置栏目未添加：\(item.name)").vosFont(WorkspaceText.body)
                        Button("添加内置来源") {
                            Task { await model.ensureBuiltinMonitorSources(restoreMissing: true) }
                        }.vosFont(WorkspaceText.meta)
                        .accessibilityIdentifier("monitor.sources.addBuiltin")
                        Spacer()
                    }.padding(.vertical, 8)
                }
            }
        }
    }

    @ViewBuilder private func sourceRow(_ source: MonitorSource) -> some View {
        let stat = model.monitorSourceStats[source.id]
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: source.kind == .qqGroup ? "bubble.left.and.bubble.right" : "globe")
                    .foregroundStyle(palette.secondaryText)
                Text(source.displayName).vosFont(WorkspaceText.rowTitle)
                Text(source.kind == .qqGroup ? "QQ 群" : "官网栏目").vosFont(WorkspaceText.meta)
                    .foregroundStyle(palette.tertiaryText)
                Spacer()
                Toggle("启用", isOn: Binding(
                    get: { source.enabled },
                    set: { value in Task { await model.setMonitorSourceEnabled(source, enabled: value) } }))
                    .toggleStyle(.switch).labelsHidden().controlSize(.small)
                    .accessibilityLabel((source.enabled ? "停用" : "启用") + "来源 " + source.displayName)
                    .accessibilityIdentifier("monitor.source." + source.id + ".enabled")
                Button("删除", role: .destructive) { pendingSourceRemoval = source }
                    .vosFont(WorkspaceText.meta)
                    .accessibilityIdentifier("monitor.source." + source.id + ".delete")
            }
            if !source.enabled {
                Text("已停用，不参与每日检查；历史消息保留。").vosFont(WorkspaceText.meta)
                    .foregroundStyle(palette.secondaryText)
            }
            Text(sourceStatText(source, stat)).vosFont(WorkspaceText.meta)
                .foregroundStyle(stat?.lastError == nil ? palette.secondaryText : palette.warning)
                .textSelection(.enabled)
            HStack(spacing: 12) {
                Text("从这里开始读取").vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
                DatePicker("", selection: Binding(
                    get: { model.monitorSourceStartDate(source) ?? Date() },
                    set: { date in Task { await setStart(source, date) } }),
                    displayedComponents: source.kind == .qqGroup ? [.date, .hourAndMinute] : [.date])
                    .labelsHidden().datePickerStyle(.field)
                    .frame(width: source.kind == .qqGroup ? 190 : 130)
                    .accessibilityLabel("来源起始时间：" + source.displayName)
                    .accessibilityIdentifier("monitor.source." + source.id + ".start")
                Text(startNote(source)).vosFont(WorkspaceText.caption)
                    .foregroundStyle(palette.tertiaryText)
                Spacer()
            }
        }
        .padding(.vertical, 10)
        WorkspaceListDivider()
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
        guard let date = model.monitorSourceStartDate(source) else { return "尚未设置起始时间" }
        if source.kind == .qqGroup {
            return "将从 " + date.formatted(date: .abbreviated, time: .shortened) + " 开始读取，更早的群消息不导入"
        }
        return "起始日期 " + MonitorSourceConfigParser.dayString(date) + "；无发布时间的栏目条目仍会检查"
    }

    private var settingsSection: some View {
        WorkspaceSection(title: "检查设置", subtitle: "时间、授权、推送与 QQ 依赖", icon: "slider.horizontal.3") {
            scheduleSettings
            Divider().padding(.vertical, 12)
            authorizationSettings
            Divider().padding(.vertical, 12)
            pushSettings
            Divider().padding(.vertical, 12)
            qqSettings
        }
    }

    private var scheduleSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("每日自动检查").vosFont(WorkspaceText.rowTitle)
            HStack(spacing: 12) {
                DatePicker("检查时间", selection: Binding(
                    get: { model.monitorScheduleDate },
                    set: { model.setMonitorScheduleTime($0) }),
                    displayedComponents: .hourAndMinute)
                    .labelsHidden().datePickerStyle(.field).frame(width: 110)
                    .accessibilityLabel("每日检查时间")
                    .accessibilityIdentifier("monitor.settings.schedule.time")
                Text("默认 09:00；每天最多一次。").vosFont(WorkspaceText.meta)
                    .foregroundStyle(palette.secondaryText)
            }
            Text(model.monitorNextRunText).vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
            Text("应用退出后不会自动运行；下次启动会补跑漏掉的一天。检查开始前只比对时间，不读 QQ、不调模型。")
                .vosFont(WorkspaceText.caption).foregroundStyle(palette.tertiaryText)
        }
    }

    private var authorizationSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("允许云端分析监测内容", isOn: Binding(
                get: { model.monitorSettings.cloudAnalysisAuthorized },
                set: { value in model.updateMonitorSettings { $0.cloudAnalysisAuthorized = value } }))
                .toggleStyle(.switch).frame(maxWidth: 420, alignment: .leading)
                .accessibilityIdentifier("monitor.settings.cloudAuthorized")
            Text("开启后，所选来源的新增原文（QQ 群消息与官网正文）会发送给已配置的文本模型分析。模型密钥与整个数据库不会发送。默认关闭；关闭时检查会停在分析前，不偷偷发送。")
                .vosFont(WorkspaceText.caption).foregroundStyle(palette.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var pushSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("微信推送").vosFont(WorkspaceText.rowTitle)
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
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 420)
                    .accessibilityLabel("推送地址")
                    .accessibilityIdentifier("monitor.settings.push.webhook")
                Button("保存地址") {
                    if model.saveMonitorWebhook(webhookDraft) { webhookDraft = "" }
                }.disabled(webhookDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("monitor.settings.push.save")
            }
            Text(model.monitorWebhookTail.isEmpty
                 ? "尚未保存推送地址；地址只保存在系统钥匙串。"
                 : "已保存：尾号 " + model.monitorWebhookTail)
                .vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
            HStack(spacing: 12) {
                Button("发送测试") { Task { await model.sendMonitorPushTest() } }
                    .disabled(model.monitorSettings.pushChannel == nil)
                    .accessibilityIdentifier("monitor.settings.push.test")
                Button("立即推送今日报告") { Task { await model.pushLatestMonitorReport() } }
                    .disabled(model.monitorLatestReport == nil)
                    .accessibilityIdentifier("monitor.settings.push.pushNow")
                Spacer()
            }
            if !model.monitorTestPushStatus.isEmpty {
                Text(model.monitorTestPushStatus).vosFont(WorkspaceText.meta)
                    .foregroundStyle(palette.secondaryText).textSelection(.enabled)
            }
            if let report = model.monitorLatestReport {
                Text("最近投递：" + ControlCenter.monitorDeliveryText(report))
                    .vosFont(WorkspaceText.meta)
                    .foregroundStyle(report.deliveryState == "failed" ? palette.warning : palette.secondaryText)
            }
            if !model.monitorPushStatus.isEmpty {
                Text(model.monitorPushStatus).vosFont(WorkspaceText.meta)
                    .foregroundStyle(palette.secondaryText).textSelection(.enabled)
            }
        }
    }

    private var qqSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("QQ 群读取").vosFont(WorkspaceText.rowTitle)
            Text("只保存路径、账号与群标识；密钥文件内容不会复制、不会进入日志或模型。应用不会修改 QQ 或系统安全设置。")
                .vosFont(WorkspaceText.caption).foregroundStyle(palette.tertiaryText)
            pathRow("Python 解释器", text: $qqPythonPath, check: pythonCheck, choose: choosePython)
            pathRow("密钥文件", text: $qqKeyPath, check: keyCheck, choose: chooseKeyFile)
            HStack(spacing: 10) {
                Text("账号").vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
                    .frame(width: 90, alignment: .leading)
                TextField("可选；留空自动选择（多数情况留空即可）", text: $qqAccount)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 360)
            }
            DisclosureGroup("高级") {
                VStack(alignment: .leading, spacing: 8) {
                    pathRow("读取脚本", text: $qqScriptOverride, choose: chooseScript)
                    Text("留空时自动查找应用包或仓库中的 scripts/qqmonitor/qq_read_range.py。")
                        .vosFont(WorkspaceText.caption).foregroundStyle(palette.tertiaryText)
                }.padding(.top, 8)
            }
            HStack(spacing: 12) {
                Button("保存 QQ 设置") { saveQQSettings() }.vosFont(WorkspaceText.meta)
                    .accessibilityIdentifier("monitor.settings.qq.save")
                Button("检查 QQ 依赖") {
                    saveQQSettings()
                    Task { await model.diagnoseMonitorQQ() }
                }.vosFont(WorkspaceText.meta)
                    .accessibilityIdentifier("monitor.settings.qq.diagnose")
                Button("列出群") {
                    saveQQSettings()
                    Task {
                        qqListedAccount = await model.loadQQMonitorConversations()
                        if let account = qqListedAccount, let id = selectedConversationID,
                           model.monitorQQConversations.contains(where: { $0.id == id }) {
                            qqAccount = account
                        }
                    }
                }.vosFont(WorkspaceText.meta)
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
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(model.monitorQQDiagnostics) { item in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: item.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(item.ok ? palette.success : palette.warning)
                            Text(item.title).vosFont(WorkspaceText.meta.size, weight: .semibold)
                            Text(item.detail).vosFont(WorkspaceText.meta)
                                .foregroundStyle(palette.secondaryText).textSelection(.enabled)
                        }
                    }
                }
                .padding(10)
                .background(palette.selection.opacity(0.35),
                            in: RoundedRectangle(cornerRadius: WorkspaceMetrics.controlRadius))
            }
            if qqNeedsFullDiskAccess {
                VStack(alignment: .leading, spacing: 8) {
                    Text(QQMonitorPermissionGuidance.text).vosFont(WorkspaceText.meta)
                        .foregroundStyle(palette.warning).fixedSize(horizontal: false, vertical: true)
                    Button("打开系统设置") { openFullDiskAccessSettings() }.vosFont(WorkspaceText.meta)
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
            Text("已添加的群来源在「报告」页的「来源状态」中管理启停、起始时间与删除。")
                .vosFont(WorkspaceText.caption).foregroundStyle(palette.tertiaryText)
        }
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
                    .frame(width: 90, alignment: .leading)
                TextField(label, text: text)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 360)
                Button("选择…", action: choose).vosFont(WorkspaceText.meta)
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
            Text("选择要监测的群（同名时按最新消息时间和群号区分，不默认选择）")
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
                    .labelsHidden().datePickerStyle(.field).frame(width: 190)
                    .accessibilityLabel("QQ 起点")
                    .accessibilityIdentifier("monitor.settings.qq.start")
                Button("添加所选群") {
                    guard let id = selectedConversationID,
                          let conversation = model.monitorQQConversations.first(where: { $0.id == id }) else { return }
                    Task {
                        if await model.addQQMonitorSource(conversation, start: qqStart) {
                            selectedConversationID = nil
                        }
                    }
                }.disabled(selectedConversationID == nil)
                    .accessibilityIdentifier("monitor.settings.qq.addSelected")
                Spacer()
            }
            Text("只从所选时间开始读取；更早的群消息不会导入。默认从今天开始。")
                .vosFont(WorkspaceText.caption).foregroundStyle(palette.tertiaryText)
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
