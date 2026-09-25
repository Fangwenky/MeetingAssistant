# MeetingAssistant

一个开源、本地优先的实时会议助手，提供原生 macOS 版和 Windows 版。它会分别采集系统声音与麦克风，用本地 Whisper 模型转写，并可通过 OpenAI Chat Completions 兼容接口（包括兼容模式的 MiniMax API）校订转写、生成摘要和回答会议问题。

## 功能

- 系统音频标记为“其他人”，麦克风标记为“我”；麦克风默认关闭，可随时启停。
- 两路音频使用统一会议时间线，未稳定文字会持续更新，定稿片段按时间排序。
- 结束会议时使用本地临时音频执行全程复核；临时文件随后删除，音频不会上传 API。
- API 每隔约 30 秒更新摘要、决策、待办和风险，并支持流式会议问答。
- 本地会议历史、分类、重命名和批量管理（macOS）；Markdown、TXT、SRT 导出（Windows 首版提供 Markdown）。
- API Key 存在 macOS Keychain 或 Windows Credential Locker 后端，不写入会议文件。

## 下载

从 [Releases](../../releases) 下载：

- `MeetingAssistant-macOS-arm64.dmg`：Apple Silicon、macOS 15+。
- `MeetingAssistant-Windows-x64.zip`：Windows 10/11 x64。

两个版本均未使用商业代码签名证书。首次打开时，macOS Gatekeeper 或 Windows SmartScreen 可能要求手动确认。首次转写还会下载本地模型，因此需要联网并预留模型空间；下载完成后，本地转写无需联网。

## macOS

macOS 版使用 SwiftUI、ScreenCaptureKit 和 WhisperKit/Core ML。它可以采集全部系统声音或指定应用，会议记录位于：

```text
~/Library/Application Support/MeetingAssistant/Meetings/
```

首次使用需要授予“屏幕与系统音频录制”和麦克风权限。API Key 存在 Keychain。

### macOS 源码构建

要求 Apple Silicon、macOS 15+ 和 Xcode 16+：

```sh
swift run MeetingAssistantChecks
zsh Scripts/build-app.sh release
open .build/MeetingAssistant.app
```

## Windows

Windows 版使用 Python/Tkinter、WASAPI loopback、SoundCard 和 faster-whisper。会议记录位于：

```text
%LOCALAPPDATA%\MeetingAssistant\Meetings\
```

默认本地模型是 `small`，可在设置中改为 faster-whisper 支持的模型名称。系统音频依赖 Windows WASAPI 回环设备；蓝牙耳机或特殊声卡若不暴露回环端点，需在 Windows 声音设置中启用相应设备。

### Windows 源码运行

要求 Python 3.12：

```powershell
py -3.12 -m venv .venv
.venv\Scripts\Activate.ps1
pip install -r windows\requirements.txt
python windows\meeting_assistant.py
```

最小自检：

```powershell
python windows\meeting_assistant.py --self-check
```

## API 设置

填写 Base URL（应包含版本路径，例如 `https://api.openai.com/v1`）、兼容模型名和 API Key。应用只会发送最终文字、既有分析和用户问题，不上传音频。未配置 API 时，本地转写、历史和导出仍可使用。

## 隐私与数据

每场会议目录包含 `metadata.json`、`transcript.jsonl`、`analysis.json` 和 `qa.jsonl`。为了结束时复核，会议进行期间会在系统临时目录保存短期 PCM/WAV 数据；正常结束或进程退出后由系统或应用清理，不写入会议目录。

## 发布

推送 `v*` 标签会触发 GitHub Actions，在真实的 macOS arm64 与 Windows x64 runner 上执行检查、构建安装包并创建 GitHub Release。

## License

[MIT](LICENSE)
