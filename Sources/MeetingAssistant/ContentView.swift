import SwiftUI
import MeetingAssistantCore

struct ContentView: View {
    @EnvironmentObject private var app: AppModel
    @State private var showNewMeeting = false
    @State private var selectedMeetingID: UUID?
    @State private var editingMeeting: MeetingRecord?
    @State private var deletingMeeting: MeetingRecord?
    @State private var isManaging = false
    @State private var batchSelection: Set<UUID> = []
    @State private var showBatchMove = false
    @State private var showBatchDeleteConfirmation = false

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Button {
                        showNewMeeting = true
                    } label: {
                        Label("开始新会议", systemImage: "record.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(app.isMeetingActive || isManaging)

                    Button(isManaging ? "完成" : "管理") {
                        isManaging.toggle()
                        batchSelection.removeAll()
                    }
                    .controlSize(.large)
                    .disabled(app.isMeetingActive || app.meetings.isEmpty)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)

                List(selection: $selectedMeetingID) {
                    ForEach(meetingGroups) { group in
                        Section(group.title) {
                            ForEach(group.meetings) { meeting in
                                MeetingRow(
                                    meeting: meeting,
                                    selected: app.document?.record.id == meeting.id,
                                    batchSelection: isManaging ? Binding(
                                        get: { batchSelection.contains(meeting.id) },
                                        set: { selected in
                                            if selected { batchSelection.insert(meeting.id) }
                                            else { batchSelection.remove(meeting.id) }
                                        }
                                    ) : nil,
                                    edit: { editingMeeting = meeting },
                                    delete: { deletingMeeting = meeting }
                                )
                                .tag(meeting.id)
                                .listRowInsets(EdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 10))
                                .disabled(app.isMeetingActive && app.document?.record.id != meeting.id)
                                .contextMenu {
                                    if !isManaging {
                                        Button("编辑名称与分类", systemImage: "pencil") { editingMeeting = meeting }
                                        Button("移到废纸篓", systemImage: "trash", role: .destructive) { deletingMeeting = meeting }
                                            .disabled(app.isMeetingActive)
                                    }
                                }
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .overlay {
                    if app.meetings.isEmpty {
                        ContentUnavailableView("暂无会议记录", systemImage: "tray")
                            .controlSize(.small)
                    }
                }

                if isManaging {
                    Divider()
                    VStack(spacing: 8) {
                        HStack {
                            Button(batchSelection.count == app.meetings.count ? "取消全选" : "全选") {
                                if batchSelection.count == app.meetings.count {
                                    batchSelection.removeAll()
                                } else {
                                    batchSelection = Set(app.meetings.map(\.id))
                                }
                            }
                            Spacer()
                            Text("已选 \(batchSelection.count) 项")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        HStack(spacing: 8) {
                            Button("移动到分类…", systemImage: "folder") { showBatchMove = true }
                                .frame(maxWidth: .infinity)
                                .disabled(batchSelection.isEmpty)
                            Button("移到废纸篓", systemImage: "trash", role: .destructive) {
                                showBatchDeleteConfirmation = true
                            }
                            .frame(maxWidth: .infinity)
                            .disabled(batchSelection.isEmpty)
                        }
                    }
                    .padding(10)
                }
            }
            .navigationTitle("会议记录")
            .navigationSplitViewColumnWidth(min: 250, ideal: 290, max: 360)
        } detail: {
            if let document = app.document {
                MeetingDetailView(document: document)
            } else {
                WelcomeView { showNewMeeting = true }
            }
        }
        .onAppear { selectedMeetingID = app.document?.record.id }
        .onChange(of: selectedMeetingID) { _, id in
            guard id != app.document?.record.id else { return }
            if app.isMeetingActive {
                selectedMeetingID = app.document?.record.id
            } else {
                Task { await app.selectMeeting(id) }
            }
        }
        .onChange(of: app.document?.record.id) { _, id in selectedMeetingID = id }
        .sheet(isPresented: $showNewMeeting) {
            NewMeetingSheet()
                .environmentObject(app)
        }
        .sheet(item: $editingMeeting) { meeting in
            MeetingEditSheet(meeting: meeting, existingCategories: app.categories) { title, category in
                Task { await app.updateMeeting(meeting.id, title: title, category: category) }
            }
        }
        .sheet(isPresented: $showBatchMove) {
            BatchMoveSheet(existingCategories: app.categories) { category in
                let ids = batchSelection
                batchSelection.removeAll()
                Task { await app.moveMeetings(ids, toCategory: category) }
            }
        }
        .confirmationDialog(
            "将“\(deletingMeeting?.title ?? "这场会议")”移到废纸篓？",
            isPresented: Binding(
                get: { deletingMeeting != nil },
                set: { if !$0 { deletingMeeting = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("移到废纸篓", role: .destructive) {
                guard let id = deletingMeeting?.id else { return }
                deletingMeeting = nil
                Task { await app.moveMeetingToTrash(id) }
            }
            Button("取消", role: .cancel) { deletingMeeting = nil }
        } message: {
            Text("会议记录会保留在 macOS 废纸篓中，可在清空前恢复。")
        }
        .confirmationDialog(
            "将选中的 \(batchSelection.count) 场会议移到废纸篓？",
            isPresented: $showBatchDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("移到废纸篓", role: .destructive) {
                let ids = batchSelection
                batchSelection.removeAll()
                Task { await app.moveMeetingsToTrash(ids) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这些会议记录可在清空 macOS 废纸篓前恢复。")
        }
        .alert("MeetingAssistant", isPresented: Binding(
            get: { app.errorMessage != nil },
            set: { if !$0 { app.errorMessage = nil } }
        )) {
            Button("屏幕录制设置") { app.openPrivacySettings(.screenRecording) }
            Button("麦克风设置") { app.openPrivacySettings(.microphone) }
            Button("好", role: .cancel) { app.errorMessage = nil }
        } message: {
            Text(app.errorMessage ?? "")
        }
    }

    private var meetingGroups: [MeetingGroup] {
        let grouped = Dictionary(grouping: app.meetings) { $0.category ?? "未分类" }
        return grouped.keys.sorted {
            if $0 == $1 { return false }
            if $0 == "未分类" { return true }
            if $1 == "未分类" { return false }
            return $0.localizedStandardCompare($1) == .orderedAscending
        }.map { MeetingGroup(title: $0, meetings: grouped[$0] ?? []) }
    }
}

private struct MeetingGroup: Identifiable {
    var id: String { title }
    var title: String
    var meetings: [MeetingRecord]
}

private struct MeetingRow: View {
    var meeting: MeetingRecord
    var selected: Bool
    var batchSelection: Binding<Bool>?
    var edit: () -> Void
    var delete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if let batchSelection {
                Toggle("", isOn: batchSelection)
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                    .accessibilityLabel("选择\(meeting.title)")
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(meeting.title)
                    .fontWeight(selected ? .semibold : .regular)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(meeting.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(meeting.captureScope.displayName)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if meeting.status != .finished {
                Circle()
                    .fill(meeting.status == .paused ? .orange : .red)
                    .frame(width: 7, height: 7)
                    .accessibilityLabel(meeting.status == .paused ? "已暂停" : "进行中")
            }

            if batchSelection == nil {
                Menu {
                    Button("编辑名称与分类", systemImage: "pencil", action: edit)
                    Divider()
                    Button("移到废纸篓", systemImage: "trash", role: .destructive, action: delete)
                        .disabled(meeting.status != .finished)
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 22, height: 22)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("管理\(meeting.title)")
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

private struct BatchMoveSheet: View {
    @Environment(\.dismiss) private var dismiss
    let existingCategories: [String]
    let move: (String?) -> Void
    @State private var category = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("移动到分类")
                .font(.title2.bold())
            TextField("分类名称；留空表示未分类", text: $category)
            if !existingCategories.isEmpty {
                Picker("已有分类", selection: $category) {
                    Text("未分类").tag("")
                    ForEach(existingCategories, id: \.self) { Text($0).tag($0) }
                }
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("移动") {
                    move(category)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(22)
        .frame(width: 420)
    }
}

private struct MeetingEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    let meeting: MeetingRecord
    let existingCategories: [String]
    let save: (String, String?) -> Void
    @State private var title: String
    @State private var category: String

    init(meeting: MeetingRecord, existingCategories: [String], save: @escaping (String, String?) -> Void) {
        self.meeting = meeting
        self.existingCategories = existingCategories
        self.save = save
        _title = State(initialValue: meeting.title)
        _category = State(initialValue: meeting.category ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("管理会议记录")
                .font(.title2.bold())

            Form {
                TextField("会议名称", text: $title)
                HStack {
                    TextField("分类（例如：项目 A）", text: $category)
                    if !existingCategories.isEmpty {
                        Menu("已有分类") {
                            Button("未分类") { category = "" }
                            ForEach(existingCategories, id: \.self) { value in
                                Button(value) { category = value }
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Text("分类会直接显示在左侧栏中；没有记录时分类会自动消失。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("取消") { dismiss() }
                Button("保存更改") {
                    save(title, category)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 520)
    }
}

private struct WelcomeView: View {
    var start: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            DualChannelMark()

            VStack(spacing: 8) {
                Text("听见双方，记住重点")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Text("“我”和“其他人”分轨本地转写，摘要、决策与待办随会议持续更新。")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
            }

            Button("开始新会议", action: start)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

            Label("音频只在本机内存中处理，不保存、不上传", systemImage: "lock.shield.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}

private struct DualChannelMark: View {
    private let heights: [CGFloat] = [12, 24, 40, 28, 52, 34, 18]

    var body: some View {
        HStack(spacing: 10) {
            channel(title: "我", icon: "mic.fill", color: .blue, values: heights)
            channel(title: "其他人", icon: "speaker.wave.2.fill", color: .purple, values: heights.reversed())
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 22))
    }

    private func channel<S: Sequence>(title: String, icon: String, color: Color, values: S) -> some View where S.Element == CGFloat {
        VStack(spacing: 10) {
            HStack(alignment: .center, spacing: 4) {
                ForEach(Array(values.enumerated()), id: \.offset) { _, height in
                    Capsule()
                        .fill(color.gradient)
                        .frame(width: 5, height: height)
                }
            }
            Label(title, systemImage: icon)
                .font(.caption.bold())
                .foregroundStyle(color)
        }
        .frame(width: 118, height: 94)
        .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 16))
    }
}
