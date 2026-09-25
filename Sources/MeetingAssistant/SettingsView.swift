import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var app: AppModel
    @State private var baseURL = "https://api.openai.com/v1"
    @State private var model = ""
    @State private var apiKey = ""

    var body: some View {
        Form {
            Section("录音权限") {
                LabeledContent("屏幕与系统音频", value: permissionLabel(app.capturePermissions.screenRecordingGranted))
                LabeledContent("麦克风", value: permissionLabel(app.capturePermissions.microphoneGranted))
                HStack {
                    Button("请求授权") {
                        Task { await app.requestCapturePermissions() }
                    }
                    .buttonStyle(.borderedProminent)
                    Button("屏幕录制设置") { app.openPrivacySettings(.screenRecording) }
                    Button("麦克风设置") { app.openPrivacySettings(.microphone) }
                }
                Text("权限状态会在应用重新获得焦点时刷新。屏幕录制授权后，macOS 可能要求重新启动应用。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("本地转写模型") {
                LabeledContent("模型", value: WhisperPipelineFactory.modelName)
                LabeledContent("状态", value: app.modelState.label)
                Button(modelButtonTitle) {
                    Task { await app.prepareModel() }
                }
                .disabled(app.modelState == .loading || app.modelState == .ready)
                Text("模型约 632 MB，下载完成后转写完全离线运行。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("OpenAI 兼容分析 API") {
                TextField("Base URL", text: $baseURL, prompt: Text("https://api.openai.com/v1"))
                TextField("模型名", text: $model, prompt: Text("例如 gpt-5-mini"))
                SecureField("API Key", text: $apiKey)
                HStack {
                    Button("保存") { app.saveAPISettings(baseURL: baseURL, model: model, apiKey: apiKey) }
                        .buttonStyle(.borderedProminent)
                    Button("测试连接") {
                        Task { await app.testAPI(baseURL: baseURL, model: model, apiKey: apiKey) }
                    }
                    Spacer()
                    if let status = app.settingsStatus {
                        Text(status).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("API Key 存储在 macOS Keychain。发送到 API 的只有已定稿文字、会议分析和你的问题，不包含音频。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 10)
        .onAppear {
            app.refreshCapturePermissions()
            baseURL = UserDefaults.standard.string(forKey: "llm.baseURL") ?? "https://api.openai.com/v1"
            model = UserDefaults.standard.string(forKey: "llm.model") ?? ""
            apiKey = KeychainStore.readAPIKey()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            app.refreshCapturePermissions()
        }
    }

    private func permissionLabel(_ granted: Bool) -> String {
        granted ? "已授权" : "未授权"
    }

    private var modelButtonTitle: String {
        if case .failed = app.modelState { return "重试" }
        return "下载或加载模型"
    }
}
