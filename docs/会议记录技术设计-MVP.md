# TBOX 录音转写与 AI 会议纪要技术设计（MVP）

> 文档状态：已确认，作为后续实现依据  
> 创建时间：2026-08-13  
> 最低系统：macOS 14.0  
> 关联产品文档：[录音转写与 AI 会议纪要产品方案](./会议记录产品方案-MVP.md)

## 一、现有工程基线

当前工程使用 Swift、AppKit/SwiftUI、ScreenCaptureKit 和 AVFoundation，已具备：

- `ScreenRecorder`：通过 ScreenCaptureKit 录制屏幕和系统声音，使用 AVAssetWriter 输出 MP4。
- `RecordingControlPanel`：录制计时、暂停/继续、停止。
- `AppDelegate`：菜单栏入口、全局快捷键、普通录屏生命周期。
- `SettingsView`：基础设置窗口骨架。

现有 `ScreenRecorder` 适合“屏幕 + 系统声音 → 单个 MP4”的普通录屏，但不直接承担录音转写：

- 当前没有实际采集和写入麦克风音轨。
- 普通录屏以视频帧启动 writer，会议音频不应依赖视频帧。
- 单文件长时间写入不利于崩溃恢复和断点转写。
- 录音转写需要独立音轨、分段清单、转写状态和长期会话数据。

因此新增独立 `Meeting`（录音转写）模块。代码目录暂保留 `Meeting` 命名以减少实现歧义；产品界面统一使用“录音转写”。复用权限检查、控制条样式、ScreenCaptureKit 经验和日志基础，但不把录音转写状态塞入 `ScreenRecorder`。

## 二、设计目标

### 2.1 必须保证

- 录音关键路径完全本地化，不依赖网络。
- 系统声音和麦克风分轨、分段保存。
- 每个完成分段都能够独立播放和转写。
- 崩溃后可以根据磁盘数据恢复会话。
- ASR 通过适配器隔离；LLM 仅作为可选的 AI 纪要增强，也必须独立适配。
- 逐字稿、说话人和纪要版本拥有稳定的数据模型。
- 所有密钥只存放在 Keychain。

### 2.2 非目标

- 实时音频流上传或实时逐字稿。
- 声纹识别。
- 视频和会议音频复用同一个 writer。
- 首版插件化模型市场。

## 三、总体架构

```text
┌─────────────────────────────────────────────────────────┐
│              Recording Transcription UI                 │
│  会话列表 │ 录音控制条 │ 逐字稿编辑 │ AI 纪要 │ 模型设置 │
└──────────────────────────┬──────────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────────┐
│                MeetingSessionCoordinator                │
│   录音状态机 │ 转写任务 │ 恢复流程 │ 保存策略 │ 前后台切换     │
└───────────────┬──────────────────┬──────────────────────┘
                │                  │
┌───────────────▼────────────┐  ┌──▼──────────────────────┐
│       Local Capture        │  │     Processing         │
│ SystemAudioCapture         │  │ TranscriptionService   │
│ MicrophoneCapture          │  │ TranscriptAssembler    │
│ SegmentedAudioWriter       │  │ OptionalAISummaryService│
│ RecordingManifest          │  │ ExportService          │
└───────────────┬────────────┘  └──┬──────────────────────┘
                │                  │
┌───────────────▼──────────────────▼──────────────────────┐
│                       Storage                           │
│ SessionStore │ KeychainStore │ ProviderConfigStore      │
│ 音频分段      │ transcript.json │ summaries/*.md          │
└──────────────────────────┬──────────────────────────────┘
                           │ 用户明确发起处理后
┌──────────────────────────▼──────────────────────────────┐
│              User-configured HTTPS Services            │
│             ASR Provider       LLM Provider             │
└─────────────────────────────────────────────────────────┘
```

## 四、建议工程结构

```text
TBOX/TBOX/
├── Meeting/
│   ├── Model/
│   │   ├── MeetingSession.swift
│   │   ├── RecordingManifest.swift
│   │   ├── Transcript.swift
│   │   └── MeetingSummary.swift
│   ├── Recording/
│   │   ├── MeetingRecorder.swift
│   │   ├── SystemAudioCapture.swift
│   │   ├── MicrophoneCapture.swift
│   │   └── SegmentedAudioWriter.swift
│   ├── Processing/
│   │   ├── TranscriptionCoordinator.swift
│   │   ├── TranscriptAssembler.swift
│   │   ├── SummaryCoordinator.swift
│   │   └── ContextWindowPlanner.swift
│   ├── Providers/
│   │   ├── ASRProvider.swift
│   │   ├── OpenAICompatibleASRProvider.swift
│   │   ├── LLMProvider.swift
│   │   └── OpenAICompatibleLLMProvider.swift
│   ├── Storage/
│   │   ├── MeetingSessionStore.swift
│   │   ├── ProviderConfigStore.swift
│   │   └── KeychainStore.swift
│   ├── UI/
│   │   ├── MeetingListView.swift
│   │   ├── MeetingStartView.swift
│   │   ├── MeetingControlPanel.swift
│   │   ├── TranscriptEditorView.swift
│   │   ├── SummaryEditorView.swift
│   │   └── ModelProviderSettingsView.swift
│   └── MeetingSessionCoordinator.swift
└── Recording/
    └── ScreenRecorder.swift             # 普通录屏，不承载会议逻辑
```

早期实现可以合并小文件，但模块边界和数据职责必须保持不变。

## 五、录音架构

### 5.1 音源策略

| 音源 | 实现 | 最低系统 | 默认说话人 |
| --- | --- | --- | --- |
| 系统声音 | ScreenCaptureKit `SCStream` 的 `.audio` 输出 | macOS 14 | 其他参会人 |
| 麦克风 | AVAudioEngine input node tap | macOS 14 | 我 |

即使较新系统能够通过 ScreenCaptureKit 提供麦克风输出，MVP 仍优先使用 AVAudioEngine，使 macOS 14/15 行为一致，并支持明确选择输入设备。后续验证稳定后再考虑统一管线。

### 5.2 分轨原则

- 稳定区分本机用户和远端参会人。
- 独立检测某一路静音、设备断开或写入失败。
- ASR 可以分别转写，再按时间戳合并。
- 用户可以只删除或重转写某一路。

不得在录音阶段直接把两路混为单轨；播放时可以临时混音。

### 5.3 统一音频规格

- 采样率：48 kHz。
- 声道：单声道；系统声音写入前下混。
- 编码：AAC-LC，建议 64–96 kbps/轨。
- 容器：M4A。
- 分段时长：默认 5 分钟，可根据 ASR 限制生成更小的上传副本。

设备格式不同时使用 `AVAudioConverter`。转换、编码和磁盘写入使用专用串行队列，不能阻塞主线程或 ScreenCaptureKit 回调。

### 5.4 分段写入

```text
audio/
├── system/
│   ├── 000001.m4a
│   ├── 000002.m4a
│   └── current.partial
└── microphone/
    ├── 000001.m4a
    ├── 000002.m4a
    └── current.partial
```

写入规则：

1. 新分段先写临时文件。
2. writer 正常完成并校验可读后，原子重命名为正式文件。
3. `recording-manifest.json` 采用“写临时文件 + 原子替换”。
4. 正式分段记录音源、序号、会话时间范围、时长、字节数和校验状态。
5. 应用崩溃后隔离无法读取的临时文件，保留所有完成分段。

不要等录音结束才生成清单，也不要把所有音频只写入一个长文件。

### 5.5 时间同步

两条采集管线统一映射到单调递增的 host clock：

- 开始时记录 `sessionStartHostTime` 和墙上时间 `createdAt`。
- 每个 buffer 保存相对 `sessionStartHostTime` 的时间。
- manifest 保存 `startOffsetMs` 和 `endOffsetMs`。
- 暂停时记录 pause event，恢复后从展示时间轴扣除暂停间隔。
- ASR 返回的分段内时间戳加上分段偏移，转换为会话时间。

禁止用 `Date()` 为每个音频 buffer 计时；系统时间调整会破坏时间轴。

### 5.6 录音状态机

```text
idle → preparing → recording ⇄ paused → finalizing → pendingTranscription

preparing/recording/paused/finalizing
  → interrupted（应用、设备或磁盘异常）
```

`MeetingRecorder` 只管理采集和落盘状态；转写和可选 AI 纪要状态由 `MeetingSessionCoordinator` 管理，避免一个枚举混合硬件状态与网络任务状态。

### 5.7 磁盘保护

- 开始前检查可用空间，低于安全阈值时阻止开始。
- 录制中周期检查；低于停止阈值时完成当前可完成分段并停止。
- 按两路音轨和码率估算占用，在开始界面显示。
- 写入异常立即在控制条展示，不能只写日志。

## 六、会话存储

### 6.1 根目录

```text
~/Library/Application Support/TBOX/Meetings/<session-id>/
```

```text
<session-id>/
├── session.json
├── recording-manifest.json
├── events.json
├── audio/system/*.m4a
├── audio/microphone/*.m4a
├── transcription-jobs.json
├── transcription/*.json
├── transcript.json
├── transcript.md
└── summaries/
    ├── <summary-id>.json
    └── <summary-id>.md
```

首版可以使用轻量 `index.json` 加速列表，但真实数据以会话目录为准。索引损坏时必须能扫描目录重建。

### 6.2 会话数据

```json
{
  "schemaVersion": 1,
  "id": "UUID",
  "title": "客户需求沟通",
  "createdAt": "2026-08-13T10:00:00+08:00",
  "endedAt": "2026-08-13T11:03:20+08:00",
  "durationMs": 3800000,
  "state": "readyForReview",
  "enabledSources": ["system", "microphone"],
  "selectedInputDeviceID": "device-id",
  "transcriptRevision": 3,
  "lastError": null
}
```

所有 JSON 包含 `schemaVersion`，读取时执行显式迁移。枚举出现未知值时保留数据并展示兼容性错误，不能直接删除。

### 6.3 分段清单

```json
{
  "schemaVersion": 1,
  "segments": [
    {
      "id": "UUID",
      "source": "microphone",
      "sequence": 1,
      "relativePath": "audio/microphone/000001.m4a",
      "startOffsetMs": 0,
      "endOffsetMs": 300000,
      "durationMs": 300000,
      "byteCount": 2710043,
      "status": "ready"
    }
  ]
}
```

## 七、转写管线

### 7.1 Provider 协议

```swift
protocol ASRProvider {
    func validateConfiguration() async throws -> ASRCapabilities
    func transcribe(
        audioURL: URL,
        options: TranscriptionOptions
    ) async throws -> ProviderTranscript
}
```

`ASRCapabilities` 至少描述格式与文件上限、时间戳能力、说话人分离能力和语言。首版提供 OpenAI-compatible 风格适配器，但不能假设所有供应商字段完全一致；差异收敛在 Provider 内部。

### 7.2 任务粒度和持久化

每个“音频分段 × 音源”对应一个任务：

```json
{
  "segmentID": "UUID",
  "providerConfigID": "UUID",
  "status": "succeeded",
  "attemptCount": 1,
  "providerRequestID": "optional",
  "resultRelativePath": "transcription/system-000001.json",
  "lastErrorCode": null
}
```

- 每完成一个任务立即持久化。
- 重试只处理失败或未开始任务。
- 取消保留成功结果。
- 401/403 不自动无限重试；5xx、超时和临时网络错误有限指数退避。
- 同一分段避免并发重复提交；供应商支持时使用稳定任务 ID 作为幂等键。

### 7.3 规范化与合并

```json
{
  "id": "UUID",
  "startMs": 728400,
  "endMs": 736900,
  "source": "system",
  "speakerID": "provider-speaker-2",
  "speakerName": "说话人 2",
  "text": "我们希望第一期先解决内部协作的问题。",
  "confidence": 0.94
}
```

合并规则：

1. 将分段内时间转换为会话绝对偏移。
2. 麦克风无 speaker 时设为 `local-user`，显示“我”。
3. 系统声音无 speaker 时设为 `remote-unknown`，显示“其他参会人”。
4. 按 `startMs` 排序；相同时间不同音源保留为独立段落。
5. 只在同音源、同说话人且间隔小于阈值时合并相邻短段。
6. 保存原始 Provider 结果，便于排错和重新组装。

### 7.4 逐字稿修订

`transcript.json` 包含 `revision`、`generatedFromJobSet`、`segments`、`speakerDirectory` 和 `updatedAt`。编辑规范化副本，不覆盖 Provider 原始响应。说话人改名优先修改目录；段落级例外再覆盖显示名。

## 八、可选 AI 会议纪要生成管线

### 8.1 Provider 协议

```swift
protocol LLMProvider {
    func validateConfiguration() async throws -> LLMCapabilities
    func generate(request: LLMRequest) async throws -> LLMResponse
}
```

首版实现 OpenAI-compatible chat/completions 或 responses 风格适配器。该 Provider 只服务于可选 AI 纪要，不影响录音转写；传输格式位于 Provider 内部，业务层不直接拼 HTTP JSON。

### 8.2 输入组装

AI 纪要请求只使用当前 revision 的逐字稿、会话基本信息、用户补充上下文、模板和说话人目录，不向 LLM 上传音频。未配置 LLM 时跳过此管线，逐字稿仍可编辑和导出。Prompt 明确要求：

- 只基于逐字稿，不补造事实。
- 不确定内容标记“待确认”。
- 负责人或日期未明确时不得猜测。
- 模板要求引用时使用 `[HH:MM:SS]`。

### 8.3 长文本处理

```text
逐字稿可一次容纳 → 单次生成最终纪要

逐字稿超限
  → 按时间和段落边界分块
  → 每块生成结构化事实摘要
  → 汇总事实摘要
  → 生成最终纪要
```

- 分块保留少量重叠，避免语义边界断裂。
- 中间摘要落盘，失败时可以续跑。
- 最终生成记录逐字稿 revision。
- token 估算为模板、输出和协议预留空间。

### 8.4 版本化

每次成功生成创建新 `summaryID`，保存模板 ID 与快照、Provider 配置 ID、模型名、逐字稿 revision、创建时间、补充上下文、生成稿和用户编辑稿。重新生成、切换模板或修改逐字稿都不覆盖旧版本。

## 九、模型配置与安全

### 9.1 配置分层

`ProviderConfigStore` 保存配置 ID、类型、显示名、Base URL、模型名、能力、超时、上下文长度和语言等非敏感信息。`KeychainStore` 仅保存 API Key 或访问令牌。

Keychain service 建议使用 `com.local.TBOX.model-provider`，account 使用 provider config UUID，避免以 URL 或用户名作为键。

### 9.2 网络策略

- 使用 `URLSession`，设置连接和整体请求超时。
- 默认只允许 HTTPS。
- 仅对 `localhost`、`127.0.0.1`、`::1` 提供显式 HTTP 开关。
- 不自动跟随 HTTPS 到 HTTP 的降级重定向。
- 日志不得输出 Authorization、完整请求体、逐字稿和含用户标题的完整路径。
- 错误保存规范化错误码；供应商响应正文脱敏并限制长度。

### 9.3 测试连接

- ASR 使用内置短音频或用户明确选择的样本。
- LLM 发送最小测试文本，不发送会议数据。
- 分别验证鉴权、模型和必要能力，不以 HTTP 200 作为唯一标准。

## 十、后台执行与并发

- 每个音源使用独立串行编码队列。
- manifest/session 由单独串行 actor 或队列原子更新。
- 转写默认最多 2 个并发任务，可降为 1。
- 同一会议只允许一个活跃纪要生成任务。
- UI 更新回到 MainActor。
- 关闭主窗口不取消任务；进程退出后下次启动恢复。

任何上传、重试、JSON 解析或模型生成都不能运行在音频 sample callback 上。

## 十一、权限与工程配置

现有工程最低版本为 macOS 14.0，已配置屏幕录制用途说明。录音转写功能还需要：

| 权限/配置 | 用途 | 触发时机 |
| --- | --- | --- |
| 屏幕录制 | 采集系统声音 | 首次启用系统声音 |
| 麦克风 | 采集本机声音 | 首次启用麦克风 |
| `NSMicrophoneUsageDescription` | 系统麦克风权限说明 | 构建时写入 Info.plist |

按音源分别申请权限。只录麦克风不强制申请屏幕录制，只录系统声音不强制申请麦克风。

如果未来启用 App Sandbox，需要评估音频输入、用户选择文件、网络客户端和 Application Support 容器权限；当前工程 `com.apple.security.app-sandbox = false`。

## 十二、启动恢复

应用启动时执行 `MeetingRecoveryService`：

1. 扫描 `recording`、`paused`、`finalizing` 会话。
2. 校验正式音频分段，并修正可安全推导的数据。
3. 隔离损坏或未完成的 `.partial`，不覆盖原文件。
4. 将会话标记为 `interrupted`。
5. 提供“结束并转写”“查看文件”或“删除会话”。
6. 将失去进程持有者的运行中网络任务恢复为可重试状态。

恢复流程不得自动上传或自动删除损坏文件。

## 十三、错误模型

统一分类：

- `permissionDenied`
- `audioDeviceUnavailable`
- `captureInterrupted`
- `diskSpaceLow`
- `diskWriteFailed`
- `providerUnauthorized`
- `providerRateLimited`
- `providerUnavailable`
- `networkUnavailable`
- `invalidProviderResponse`
- `contextLimitExceeded`
- `dataCorrupted`

错误对象区分用户消息、是否可重试和技术诊断；技术诊断不得包含密钥和会议正文。

## 十四、测试计划

### 14.1 单元测试

- host time 到会话 offset 的换算和暂停区间扣除。
- manifest 原子更新、损坏恢复和 JSON schema 迁移。
- 两音源逐字稿排序、合并和说话人映射。
- 上下文分块边界和 token 预算。
- Provider 错误映射。
- Keychain 增删改及普通配置不泄密。

### 14.2 集成测试

- 用生成音频注入两种音源，验证分轨文件。
- 录制跨多个 5 分钟边界并验证文件可读。
- 分段写入期间强制终止测试进程，验证完成分段可恢复。
- Mock ASR 模拟成功、超时、401、429、5xx、无效 JSON。
- Mock LLM 验证单次生成、分段汇总、取消和版本保留。

### 14.3 手工测试矩阵

- macOS 14、15 和当前最新系统。
- 内置麦克风、蓝牙耳机、USB 麦克风；录制中拔出设备。
- 不同会议软件的系统音频。
- 睡眠/唤醒、锁屏、切换音频设备。
- 断网、弱网、限流、密钥失效和磁盘空间不足。
- 30 分钟、2 小时和 4 小时会议。

## 十五、性能和验收指标

- 点击开始到两路稳定写入：目标小于 1 秒。
- 音频回调队列不得执行网络、磁盘扫描或 UI 操作。
- 正常录音时 CPU 目标小于 10%（常见 Apple Silicon 设备参考值）。
- 两路 96 kbps 音频预计不超过约 90 MB/小时，另加少量数据文件。
- 强退后已完成分段恢复率 100%。
- 每个转写分段完成后立即持久化状态。
- 纪要可追溯到逐字稿 revision、模板和模型配置。

## 十六、建议开发顺序

1. 会话模型、目录结构、原子存储和恢复扫描。
2. 麦克风单轨分段录音及权限。
3. ScreenCaptureKit 系统声音单轨分段录音。
4. 双轨同步、暂停/继续、控制条和磁盘保护。
5. ASR Provider、任务持久化、Mock 服务和断点重试。
6. 逐字稿规范化、合并、编辑和说话人管理。
7. LLM Provider、内置模板和单次纪要生成。
8. 长文本分段汇总、版本管理和导出。
9. 设置页、Keychain、连接测试和隐私提示。
10. 长时间、崩溃恢复、设备切换和异常矩阵测试。

不得先做模型生成界面再补可靠录音；录音与恢复验收通过后再接入真实 ASR/LLM。

## 十七、实现前技术验证项

1. AVAudioEngine 与 ScreenCaptureKit buffer 的 host time 映射精度。
2. AAC 分段安全收尾方式和崩溃时最大损失范围。
3. 系统声音下混为单声道对常见会议软件的兼容性。
4. 蓝牙设备切换时 AVAudioEngine 的重建行为。
5. 首批支持的 ASR 接口能力差异和响应规范。
