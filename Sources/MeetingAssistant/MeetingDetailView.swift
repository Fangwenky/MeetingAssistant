import SwiftUI
import MeetingAssistantCore

struct MeetingDetailView: View {
    @EnvironmentObject private var app: AppModel
    var document: MeetingDocument
    @State private var title = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            GeometryReader { proxy in
                if proxy.size.width >= 840 {
                    HSplitView {
                        TranscriptView(segments: document.transcript, partialText: app.partialText)
                            .frame(minWidth: 360, idealWidth: 650)
                        AnalysisAndQuestionsView(document: document)
                            .frame(minWidth: 320, idealWidth: 420)
                    }
                } else {
                    TabView {
                        TranscriptView(segments: document.transcript, partialText: app.partialText)
                            .tabItem { Label("转写", systemImage: "text.alignleft") }
                        AnalysisAndQuestionsView(document: document)
                            .tabItem { Label("分析与问答", systemImage: "sparkles") }
                    }
                }
            }
        }
        .navigationTitle("MeetingAssistant")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Button("完整会议记录（Markdown）") { Task { await app.exportCurrentMeeting() } }
                    Button("仅转写（纯文本）") { Task { await app.exportTranscript(as: .plainText) } }
                    Button("字幕（SRT）") { Task { await app.exportTranscript(as: .srt) } }
                } label: {
                    Label("导出", systemImage: "square.and.arrow.up")
                }
                SettingsLink {
                    Label("设置", systemImage: "gearshape")
                }
            }
        }
        .onAppear { title = document.record.title }
        .onChange(of: document.record.id) { _, _ in title = document.record.title }
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                meetingInformation
                Spacer(minLength: 12)
                meetingControls
            }
            VStack(alignment: .leading, spacing: 12) {
                meetingInformation
                meetingControls
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var meetingInformation: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("会议标题", text: $title)
                .textFieldStyle(.plain)
                .font(.title2.bold())
                .lineLimit(1)
                .onSubmit { Task { await app.renameCurrentMeeting(title) } }
            Text(metadataText)
                .lineLimit(2)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var metadataText: String {
        var parts = [
            document.record.startedAt.formatted(date: .long, time: .shortened),
            document.record.captureScope.displayName,
        ]
        if let category = document.record.category { parts.append(category) }
        if document.record.status != .finished {
            parts.append(app.isFinalizing ? "全程复核与总结中" :
                (document.record.status == .paused ? "已暂停" : "转写中"))
        }
        return parts.joined(separator: "  ·  ")
    }

    @ViewBuilder
    private var meetingControls: some View {
        if app.isMeetingActive {
            HStack(spacing: 8) {
                Button {
                    Task { await app.toggleMicrophone() }
                } label: {
                    Label(
                        app.isMicrophoneEnabled ? "关闭麦克风" : "开启麦克风",
                        systemImage: app.isMicrophoneEnabled ? "mic.fill" : "mic.slash.fill"
                    )
                }
                .buttonStyle(.bordered)
                .disabled(app.isFinalizing)
                .tint(app.isMicrophoneEnabled ? .blue : nil)
                .disabled(document.record.status == .paused)
                .help(app.isMicrophoneEnabled ? "停止采集我的声音" : "开始采集并转写我的声音")

                Button {
                    Task { await app.togglePause() }
                } label: {
                    Label(document.record.status == .paused ? "继续" : "暂停", systemImage: document.record.status == .paused ? "play.fill" : "pause.fill")
                }
                .buttonStyle(.bordered)
                .disabled(app.isFinalizing)

                Button(role: .destructive) {
                    Task { await app.endMeeting() }
                } label: {
                    Label(app.isFinalizing ? "全程复核中…" : "结束会议", systemImage: "stop.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(app.isFinalizing)
            }
        }
    }
}

private struct TranscriptView: View {
    var segments: [TranscriptSegment]
    var partialText: [SpeakerSource: LiveTranscript]

    private var items: [TranscriptDisplayItem] {
        let finals = segments.map { TranscriptDisplayItem.final($0) }
        let partials = partialText.compactMap { source, partial -> TranscriptDisplayItem? in
            partial.text.isEmpty ? nil : .partial(source, partial)
        }
        return (finals + partials).sorted { $0.startTime < $1.startTime }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("实时转写", systemImage: "text.alignleft")
                    .font(.headline)
                Spacer()
                Text("\(segments.count) 段")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if segments.isEmpty && partialText.isEmpty {
                            ContentUnavailableView(
                                "等待声音",
                                systemImage: "waveform",
                                description: Text("会议开始后，已定稿的转写会出现在这里。")
                            )
                            .frame(maxWidth: .infinity, minHeight: 360)
                        }
                        ForEach(items) { item in
                            switch item {
                            case let .final(segment):
                                TranscriptRow(segment: segment)
                            case let .partial(source, partial):
                                PartialTranscriptRow(source: source, text: partial.text)
                            }
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(18)
                }
                .onChange(of: segments.count) { _, _ in
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
        }
    }
}

private enum TranscriptDisplayItem: Identifiable {
    case final(TranscriptSegment)
    case partial(SpeakerSource, LiveTranscript)

    var id: String {
        switch self {
        case let .final(segment): "final-\(segment.id)"
        case let .partial(source, _): "partial-\(source.rawValue)"
        }
    }

    var startTime: TimeInterval {
        switch self {
        case let .final(segment): segment.startTime
        case let .partial(_, partial): partial.startTime
        }
    }
}

private struct TranscriptRow: View {
    var segment: TranscriptSegment

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                timestamp
                    .frame(width: 60, alignment: .leading)
                speaker
                    .frame(width: 48, alignment: .leading)
                transcript
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) { timestamp; speaker }
                transcript
            }
        }
    }

    private var timestamp: some View {
        Text(TranscriptAlgorithms.timestamp(segment.startTime))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
    }

    private var speaker: some View {
        Text(segment.source.displayName)
            .font(.caption.bold())
            .foregroundStyle(segment.source == .me ? .blue : .purple)
    }

    private var transcript: some View {
        Text(segment.text)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PartialTranscriptRow: View {
    var source: SpeakerSource
    var text: String

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                ProgressView().controlSize(.small).frame(width: 60)
                sourceLabel.frame(width: 48, alignment: .leading)
                partialText
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) { ProgressView().controlSize(.mini); sourceLabel }
                partialText
            }
        }
    }

    private var sourceLabel: some View {
        Text(source.displayName)
            .font(.caption.bold())
            .foregroundStyle(source == .me ? .blue : .purple)
    }

    private var partialText: some View {
        Text(text)
            .foregroundStyle(.secondary)
            .italic()
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AnalysisAndQuestionsView: View {
    @EnvironmentObject private var app: AppModel
    var document: MeetingDocument
    @State private var question = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("实时分析", systemImage: "sparkles")
                    .font(.headline)
                Spacer()
                if app.isAnalyzing { ProgressView().controlSize(.small) }
                Button("立即更新") { Task { await app.runAnalysis() } }
                    .buttonStyle(.borderless)
                    .disabled(app.isAnalyzing || app.isFinalizing || document.transcript.isEmpty)
            }
            .padding(16)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let error = app.analysisError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    AnalysisSection(title: "摘要", icon: "doc.text", values: document.analysis.summary.isEmpty ? [] : [document.analysis.summary], bullets: false)
                    AnalysisSection(title: "决策", icon: "checkmark.seal", values: document.analysis.decisions)
                    ActionItemsSection(items: document.analysis.actionItems)
                    AnalysisSection(title: "风险与未决问题", icon: "exclamationmark.triangle", values: document.analysis.risks)

                    Divider()
                    Text("会议问答")
                        .font(.headline)
                    if document.questions.isEmpty {
                        Text("可以询问会议中提到的内容。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(document.questions) { item in
                        VStack(alignment: .leading, spacing: 7) {
                            Label(item.question, systemImage: "person.crop.circle")
                                .font(.callout.bold())
                            HStack(alignment: .top) {
                                if item.status == .streaming { ProgressView().controlSize(.mini) }
                                Text(item.answer.isEmpty ? "正在思考…" : item.answer)
                                    .textSelection(.enabled)
                                    .foregroundStyle(item.status == .failed ? .red : .primary)
                            }
                        }
                        .padding(10)
                        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
                .padding(16)
            }

            Divider()
            HStack(alignment: .bottom, spacing: 8) {
                TextField("询问这场会议…", text: $question, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .onSubmit { submit() }
                Button(action: submit) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || app.isAnswering)
            }
            .padding(12)
        }
    }

    private func submit() {
        let value = question
        question = ""
        Task { await app.ask(value) }
    }
}

private struct AnalysisSection: View {
    var title: String
    var icon: String
    var values: [String]
    var bullets = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.subheadline.bold())
            if values.isEmpty {
                Text("暂无")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                    HStack(alignment: .top, spacing: 7) {
                        if bullets { Text("•").foregroundStyle(.secondary) }
                        Text(value).textSelection(.enabled)
                    }
                    .font(.callout)
                }
            }
        }
    }
}

private struct ActionItemsSection: View {
    var items: [ActionItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("待办", systemImage: "checklist")
                .font(.subheadline.bold())
            if items.isEmpty {
                Text("暂无").font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 3) {
                        Text("• \(item.task)")
                        if item.owner != nil || item.due != nil {
                            Text([item.owner.map { "负责人：\($0)" }, item.due.map { "截止：\($0)" }].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.callout)
                }
            }
        }
    }
}
