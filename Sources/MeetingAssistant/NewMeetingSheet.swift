import SwiftUI
import MeetingAssistantCore

struct NewMeetingSheet: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var captureMode = "all"
    @State private var selectedProcessID: Int32?
    @State private var captureMicrophone = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("开始新会议")
                        .font(.title2.bold())
                    Text("系统音频始终采集；麦克风可按需开启。")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消") { dismiss() }
            }

            Form {
                TextField("会议标题（可选）", text: $title)

                Picker("系统音频来源", selection: $captureMode) {
                    Text("全部系统声音").tag("all")
                    Text("指定会议应用").tag("application")
                }
                .pickerStyle(.segmented)

                if captureMode == "application" {
                    Picker("会议应用", selection: $selectedProcessID) {
                        Text("请选择应用").tag(Int32?.none)
                        ForEach(app.availableApplications) { application in
                            Text(application.name).tag(Int32?.some(application.processID))
                        }
                    }
                }

                Toggle("同时采集我的麦克风", isOn: $captureMicrophone)
                Text("默认关闭。会议开始后仍可随时开启或关闭。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .formStyle(.grouped)

            if app.modelState == .loading {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("首次启动正在下载并编译约 632 MB 的本地模型，请保持网络连接。")
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Label("原始音频不会保存或上传", systemImage: "lock.shield")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("开始会议") {
                    Task {
                        await app.startMeeting(
                            title: title,
                            scope: selectedScope,
                            captureMicrophone: captureMicrophone
                        )
                        if app.isMeetingActive { dismiss() }
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(app.isStartingMeeting || (captureMode == "application" && selectedProcessID == nil))
            }
        }
        .padding(24)
        .frame(width: 620)
        .task { await app.loadAvailableApplications() }
    }

    private var selectedScope: CaptureScope {
        guard captureMode == "application",
              let selectedProcessID,
              let application = app.availableApplications.first(where: { $0.processID == selectedProcessID }) else {
            return .allSystemAudio
        }
        return application.scope
    }
}
