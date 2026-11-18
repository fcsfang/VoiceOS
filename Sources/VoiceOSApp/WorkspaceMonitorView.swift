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
    @State private var selectedConversationID: String?
    @State private var webhookDraft = ""
    @State private var pendingSourceRemoval: MonitorSource?
    @State private var formLoaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: WorkspaceMetrics.sectionGap) {
            WorkspaceHeading(eyebrow: "每日消息监测", title: "消息监测",
                             subtitle: "每天检查一次 QQ 班级群与学院官网；需要行动的事项在这里跟进，微信收到每日汇总。")
            runBar
            todayReportSection
            historySection
            sourceStatusSection
            settingsSection
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
        if let report = model.monitorLatestReport, report.reportDate == todayKey {
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

    private var historySection: some View {
        WorkspaceSection(title: "历史报告", subtitle: "最近 30 次检查；点开查看同结构内容。",
                         icon: "clock.arrow.circlepath", count: model.monitorReports.count) {
            if model.monitorReports.isEmpty {
                Text("还没有历史报告。").vosFont(WorkspaceText.meta)
                    .foregroundStyle(palette.secondaryText).padding(.vertical, 10)
            } else {
                ForEach(model.monitorReports) { report in
                    WorkspaceRow(
                        title: report.headline.isEmpty ? "未命名报告" : report.headline,
                        subtitle: report.reportDate + " · " + ControlCenter.monitorStateText(report.state)
                            + " · " + ControlCenter.monitorDeliveryText(report),
                        icon: report.reportDate == todayKey ? "doc.text" : "doc.text.magnifyingglass",
                        trailing: selectedReportID == report.id ? "收起" : "查看") {
                        if selectedReportID == report.id {
                            selectedReportID = nil
                        } else {
                            selectedReportID = report.id
                            Task { await model.loadMonitorItems(reportID: report.id) }
                        }
                    }
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
                    Text("事项 \(report.itemCount) 条").vosFont(WorkspaceText.meta)
                        .foregroundStyle(palette.secondaryText)
                    Text(ControlCenter.monitorDeliveryText(report)).vosFont(WorkspaceText.meta)
                        .foregroundStyle(report.deliveryState == "failed" ? palette.warning : palette.secondaryText)
                    Spacer()
                    if isLatest {
                        Button("立即推送今日报告") { Task { await model.pushLatestMonitorReport() } }
                            .disabled(model.monitorChecking).vosFont(WorkspaceText.meta)
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
                Text(ControlCenter.monitorDeliveryText(report)).vosFont(WorkspaceText.meta)
                    .foregroundStyle(report.deliveryState == "failed" ? palette.warning : palette.secondaryText)
            }
            sourceFailureReasons(report)
            itemsView(report: report)
        }
    }

    @ViewBuilder private func itemsView(report: MonitorReport) -> some View {
        let items = model.monitorItemsByReport[report.id] ?? []
        if items.isEmpty {
            Text(report.state == .failed ? "报告未完成，暂无事项。先处理上方原因，再重新检查。" : "没有需要关注的事项。")
                .vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText).padding(.vertical, 6)
        } else {
            ForEach([MonitorItemCategory.applicable, .needsCheck], id: \.self) { category in
                let group = items.filter { $0.category == category }
                if !group.isEmpty {
                    Text(category == .applicable ? "适用" : "待核对")
                        .vosFont(WorkspaceText.meta.size, weight: .semibold)
                        .foregroundStyle(palette.secondaryText).padding(.top, 8)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(group) { item in itemView(item) }
                }
            }
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
                    Button("不适用") { Task { await model.setMonitorItemStatus(item, status: .dismissed) } }
                        .vosFont(WorkspaceText.meta)
                } else {
                    Button("重新打开") { Task { await model.setMonitorItemStatus(item, status: .open) } }
                        .vosFont(WorkspaceText.meta)
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
            VStack(alignment: .leading, spacing: 8) {
                Text(item.evidenceQuote).vosFont(WorkspaceText.body)
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) { Rectangle().fill(palette.border).frame(width: 2) }
                    .textSelection(.enabled)
                ForEach(evidence) { entry in
                    HStack(spacing: 8) {
                        Text(evidenceLine(entry)).vosFont(WorkspaceText.meta)
                            .foregroundStyle(palette.secondaryText)
                        if let urlText = entry.url, let url = URL(string: urlText) {
                            Button("打开原文") { NSWorkspace.shared.open(url) }.vosFont(WorkspaceText.meta)
                        }
                        Spacer()
                    }
                }
            }.padding(.top, 6)
        } label: {
            Text("原文与来源").vosFont(WorkspaceText.meta.size, weight: .medium)
        }
    }

    private func evidenceLine(_ entry: MonitorItemEvidence) -> String {
        var parts: [String] = [entry.sourceName]
        if let sender = entry.sender, !sender.isEmpty { parts.append(sender) }
        if let sentAt = entry.sentAt { parts.append(ControlCenter.monitorTimeText(sentAt)) }
        if let title = entry.title, !title.isEmpty { parts.append(title) }
        return parts.joined(separator: " · ")
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
            ForEach(model.monitorSources) { source in
                sourceRow(source)
            }
            ForEach(ControlCenter.monitorBuiltinWebsites) { item in
                if model.monitorSource(forBuiltinURL: item.url) == nil {
                    HStack(spacing: 12) {
                        Text("内置栏目未添加：\(item.name)").vosFont(WorkspaceText.body)
                        Button("添加内置来源") {
                            Task { await model.ensureBuiltinMonitorSources(restoreMissing: true) }
                        }.vosFont(WorkspaceText.meta)
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
                Button("删除", role: .destructive) { pendingSourceRemoval = source }
                    .vosFont(WorkspaceText.meta)
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
        WorkspaceSection(title: "设置", subtitle: "时间、授权、推送与 QQ 依赖", icon: "slider.horizontal.3") {
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
            if let channel = model.monitorSettings.pushChannel {
                Text(channel.webhookHint).vosFont(WorkspaceText.caption).foregroundStyle(palette.tertiaryText)
            }
            HStack(spacing: 10) {
                SecureField("推送地址", text: $webhookDraft)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 420)
                Button("保存地址") {
                    if model.saveMonitorWebhook(webhookDraft) { webhookDraft = "" }
                }.disabled(webhookDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Text(model.monitorWebhookTail.isEmpty
                 ? "尚未保存推送地址；地址只保存在系统钥匙串。"
                 : "已保存：尾号 " + model.monitorWebhookTail)
                .vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
            HStack(spacing: 12) {
                Button("发送测试") { Task { await model.sendMonitorPushTest() } }
                    .disabled(model.monitorSettings.pushChannel == nil)
                Button("立即推送今日报告") { Task { await model.pushLatestMonitorReport() } }
                    .disabled(model.monitorLatestReport == nil)
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
            pathRow("Python 解释器", text: $qqPythonPath, choose: choosePython)
            pathRow("密钥文件", text: $qqKeyPath, choose: chooseKeyFile)
            HStack(spacing: 10) {
                Text("账号").vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
                    .frame(width: 90, alignment: .leading)
                TextField("可选；留空自动选择", text: $qqAccount)
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
                Button("检查 QQ 依赖") {
                    saveQQSettings()
                    Task { await model.diagnoseMonitorQQ() }
                }.vosFont(WorkspaceText.meta)
                Button("列出群") {
                    saveQQSettings()
                    Task { await model.loadQQMonitorConversations() }
                }.vosFont(WorkspaceText.meta)
                if !model.monitorQQDiagnosisStatus.isEmpty {
                    Text(model.monitorQQDiagnosisStatus).vosFont(WorkspaceText.meta)
                        .foregroundStyle(palette.secondaryText)
                }
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
            Text("已添加的群来源在上方「来源状态」中管理启停、起始时间与删除。")
                .vosFont(WorkspaceText.caption).foregroundStyle(palette.tertiaryText)
        }
    }

    private func pathRow(_ label: String, text: Binding<String>, choose: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Text(label).vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
                .frame(width: 90, alignment: .leading)
            TextField(label, text: text)
                .textFieldStyle(.roundedBorder).frame(maxWidth: 360)
            Button("选择…", action: choose).vosFont(WorkspaceText.meta)
        }
    }

    private var conversationPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("选择要监测的群（同名时按最新消息时间和群号区分，不默认选择）")
                .vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
            ForEach(model.monitorQQConversations) { conversation in
                Button {
                    selectedConversationID = conversation.id
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
            }
            HStack(spacing: 12) {
                Text("从这里开始读取").vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
                DatePicker("", selection: $qqStart, displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden().datePickerStyle(.field).frame(width: 190)
                Button("添加所选群") {
                    guard let id = selectedConversationID,
                          let conversation = model.monitorQQConversations.first(where: { $0.id == id }) else { return }
                    Task {
                        if await model.addQQMonitorSource(conversation, start: qqStart) {
                            selectedConversationID = nil
                        }
                    }
                }.disabled(selectedConversationID == nil)
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
        panel.begin { response in
            if response == .OK, let url = panel.url { qqPythonPath = url.path }
        }
    }

    private func chooseKeyFile() {
        let panel = NSOpenPanel()
        panel.title = "选择 QQ 密钥文件"
        panel.prompt = "使用"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.begin { response in
            if response == .OK, let url = panel.url { qqKeyPath = url.path }
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
        model.saveMonitorQQSettings(settings)
    }

    private func openFullDiskAccessSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
        if !NSWorkspace.shared.open(url) {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
        }
    }
}
