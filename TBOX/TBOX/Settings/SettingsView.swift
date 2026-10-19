import SwiftUI
import AppKit
import ApplicationServices

struct SettingsView: View {
    enum Page: String, CaseIterable, Identifiable {
        case status, shortcuts, records, models, account
        var id: String { rawValue }
        var title: String { ["status":"状态", "shortcuts":"快捷键", "records":"记录", "models":"模型", "account":"账户"][rawValue]! }
        var icon: String { ["status":"circle.dashed.inset.filled", "shortcuts":"keyboard", "records":"tray.full", "models":"sparkles", "account":"person.crop.circle"][rawValue]! }
    }
    @State private var page: Page = .status
    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) { Image(systemName: "camera.viewfinder").font(.system(size: 20)); VStack(alignment: .leading, spacing: 1) { Text("TBOX").font(.system(size: 14, weight: .semibold)); Text("截图与录屏工具").font(.system(size: 11)).foregroundStyle(.secondary) } }.padding(18)
                Divider()
                VStack(alignment: .leading, spacing: 2) { ForEach(Page.allCases) { item in Button { page = item } label: { HStack(spacing: 10) { Image(systemName: item.icon).frame(width: 18); Text(item.title); Spacer() }.font(.system(size: 13)).foregroundStyle(page == item ? Color.primary : Color.secondary).padding(.horizontal, 12).padding(.vertical, 8).background(page == item ? Color.black.opacity(0.07) : .clear) }.buttonStyle(.plain) } }.padding(.horizontal, 8).padding(.top, 12)
                Spacer(); Text("本地客户端 · v0.1").font(.system(size: 10)).foregroundStyle(.tertiary).padding(18)
            }.frame(minWidth: 190).background(Color(nsColor: .windowBackgroundColor).opacity(0.96))
        } detail: { Group { switch page { case .status: StatusPage(); case .shortcuts: ShortcutsPage(); case .records: RecordsPage(); case .models: ModelsPage(); case .account: AccountPage() } }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(Color(nsColor: .windowBackgroundColor)) }.navigationSplitViewStyle(.balanced).frame(minWidth: 860, minHeight: 560)
    }
}

private struct PageHeader: View { let title: String; let subtitle: String; var body: some View { VStack(alignment: .leading, spacing: 5) { Text(title).font(.system(size: 22, weight: .semibold)); Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary) }.padding(.bottom, 22) } }
private struct StatusPage: View {
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("captureNotice") private var captureNotice = true
    @AppStorage("autoUpdate") private var autoUpdate = true
    @State private var screenCaptureAllowed = false
    @State private var accessibilityAllowed = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageHeader(title: "状态", subtitle: "查看服务和系统权限，快速开始一次截图")
                HStack {
                    Circle().fill(.green).frame(width: 8, height: 8)
                    Text("截图服务运行中").font(.system(size: 14, weight: .medium))
                    Spacer()
                    Text("已就绪").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .padding(14)
                .overlay(Rectangle().stroke(Color.secondary.opacity(0.2)))
                SectionTitle("快捷入口")
                HStack(spacing: 10) {
                    ActionButton(title: "开始截图", icon: "camera") {
                        NotificationCenter.default.post(name: .tboxHotkeyTriggered, object: nil)
                    }
                    ActionButton(title: "打开记录文件夹", icon: "folder") {
                        NSWorkspace.shared.open(FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0])
                    }
                }
                SectionTitle("系统权限")
                PermissionRow(title: "屏幕录制", detail: "用于截图和录屏", enabled: screenCaptureAllowed) {
                    openPrivacy("Privacy_ScreenCapture")
                }
                PermissionRow(title: "辅助功能", detail: "用于全局快捷键", enabled: accessibilityAllowed) {
                    openPrivacy("Privacy_Accessibility")
                }
                SectionTitle("应用设置")
                ToggleRow(title: "开机启动", detail: "登录后自动运行 TBOX", isOn: $launchAtLogin)
                ToggleRow(title: "截图完成提示", detail: "截图复制后显示通知", isOn: $captureNotice)
                ToggleRow(title: "自动检查更新", detail: "仅检查版本，不会自动安装", isOn: $autoUpdate)
            }
            .padding(32)
        }
        .onAppear(perform: refreshPermissions)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissions()
        }
    }

    private func refreshPermissions() {
        screenCaptureAllowed = CGPreflightScreenCaptureAccess()
        accessibilityAllowed = AXIsProcessTrusted()
    }

    private func openPrivacy(_ area: String) { if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(area)") { NSWorkspace.shared.open(url) } }
}
private struct ShortcutsPage: View { @AppStorage("captureHotkey") private var captureHotkey = "Ctrl + Shift + A"; @AppStorage("recordHotkey") private var recordHotkey = "Ctrl + Shift + R"; var body: some View { VStack(alignment: .leading, spacing: 0) { PageHeader(title: "快捷键", subtitle: "在系统任意位置快速调用工具"); ShortcutRow(title: "截图", detail: "框选区域并复制到剪贴板", value: $captureHotkey); ShortcutRow(title: "录屏", detail: "录制当前屏幕", value: $recordHotkey); Text("当前版本的快捷键修改会保存到本机；重新注册自定义组合键将在后续版本提供。").font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 18); Spacer() }.padding(32) } }
private struct RecordsPage: View {
    enum Kind: String, CaseIterable {
        case videos = "录屏文件"
        case audio = "录音转写"
    }

    private struct RecordFile: Identifiable {
        let url: URL
        let recordedAt: Date

        var id: URL { url }
    }

    @State private var kind: Kind = .videos
    @State private var files: [RecordFile] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "记录", subtitle: "管理本机保存的录屏和录音文件")
            Picker("记录类型", selection: $kind) {
                ForEach(Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 230)
            .padding(.bottom, 12)

            Divider()

            if files.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: kind == .videos ? "video.slash" : "waveform.slash")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text("暂无文件").font(.system(size: 13))
                    Text(emptyMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    Section {
                        ForEach(files) { file in
                            HStack {
                                Image(systemName: kind == .videos ? "film" : "waveform")
                                    .frame(width: 22)
                                VStack(alignment: .leading) {
                                    Text(file.url.lastPathComponent).font(.system(size: 13))
                                    Text(fileSize(file.url))
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(recordingTime(file.recordedAt))
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 145, alignment: .trailing)
                                Button("打开") { NSWorkspace.shared.open(file.url) }
                                    .buttonStyle(.borderless)
                                    .accessibilityLabel("打开 \(file.url.lastPathComponent)")
                                if kind == .audio {
                                    Button("查看转写") {
                                        NotificationCenter.default.post(
                                            name: .tboxViewRecordingTranscript,
                                            object: file.url
                                        )
                                    }
                                    .buttonStyle(.borderless)
                                    .accessibilityLabel("查看 \(file.url.lastPathComponent) 的转写")
                                }
                                Button("删除") {
                                    try? FileManager.default.removeItem(at: file.url)
                                    try? FileManager.default.removeItem(at: RecordingTranscriptStore.url(for: file.url))
                                    refresh()
                                }
                                .buttonStyle(.borderless)
                                .foregroundStyle(.red)
                                .accessibilityLabel("删除 \(file.url.lastPathComponent)")
                            }
                            .padding(.vertical, 5)
                            .accessibilityElement(children: .contain)
                        }
                    } header: {
                        HStack {
                            Text("文件")
                            Spacer()
                            Text("记录时间").frame(width: 145, alignment: .trailing)
                            Text("操作").frame(width: kind == .audio ? 142 : 72, alignment: .trailing)
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    }
                }
                .listStyle(.inset)
            }

            HStack {
                Button("刷新") { refresh() }.buttonStyle(.bordered)
                Button("打开文件夹") { NSWorkspace.shared.open(currentDirectory) }
                    .buttonStyle(.bordered)
                Spacer()
                Text(directoryHint)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .padding(.top, 10)
        }
        .padding(32)
        .onAppear(perform: refresh)
        .onChange(of: kind) { _, _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .tboxRecordingSaved)) { _ in
            if kind == .audio { refresh() }
        }
    }

    private var currentDirectory: URL {
        switch kind {
        case .videos:
            return FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
        case .audio:
            return RecordingStorage.directory
        }
    }

    private var emptyMessage: String {
        kind == .videos
            ? "录屏保存后会显示在这里"
            : "录音结束后会自动保存并显示在这里"
    }

    private var directoryHint: String {
        kind == .videos
            ? "显示‘影片’和‘下载’中的视频"
            : "录音自动保存在 TBOX 本地目录"
    }

    private func refresh() {
        if kind == .audio {
            try? FileManager.default.createDirectory(
                at: RecordingStorage.directory,
                withIntermediateDirectories: true
            )
        }
        let roots: [URL]
        let extensions: Set<String>
        switch kind {
        case .videos:
            roots = [
                FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0],
                FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            ]
            extensions = ["mp4", "mov", "m4v"]
        case .audio:
            roots = [RecordingStorage.directory]
            extensions = ["m4a", "wav", "mp3", "caf"]
        }
        files = roots
            .flatMap {
                (try? FileManager.default.contentsOfDirectory(
                    at: $0,
                    includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey],
                    options: [.skipsHiddenFiles]
                )) ?? []
            }
            .filter { extensions.contains($0.pathExtension.lowercased()) }
            .map { RecordFile(url: $0, recordedAt: recordingDate($0)) }
            .sorted { $0.recordedAt > $1.recordedAt }
    }

    private func recordingDate(_ url: URL) -> Date {
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return values?.creationDate ?? values?.contentModificationDate ?? .distantPast
    }

    private func recordingTime(_ date: Date) -> String {
        guard date != .distantPast else { return "记录时间未知" }
        return date.formatted(date: .numeric, time: .shortened)
    }

    private func fileSize(_ url: URL) -> String {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}
private struct ModelsPage: View {
    @State private var refreshID = UUID()
    @AppStorage(RecordingTranscriptionPreferences.allowSystemSpeechFallbackKey)
    private var allowSystemSpeechFallback = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "模型", subtitle: "管理本地高精度录音转写能力")

            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: "waveform.badge.magnifyingglass")
                        .font(.system(size: 24))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("本地高精度转写").font(.system(size: 15, weight: .semibold))
                        Text("Whisper Large v3 · 中文及多语言")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Label(
                        TBOXTranscriptionModel.isInstalled ? "模型已就绪" : "首次使用时下载",
                        systemImage: TBOXTranscriptionModel.isInstalled ? "checkmark.circle.fill" : "arrow.down.circle"
                    )
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(TBOXTranscriptionModel.isInstalled ? .green : .orange)
                }

                Divider()
                InfoRow(title: "转写引擎", value: TBOXTranscriptionModel.engineVersion)
                InfoRow(title: "模型版本", value: TBOXTranscriptionModel.modelName)
                InfoRow(title: "模型体积", value: TBOXTranscriptionModel.approximateDownloadSize)
                InfoRow(title: "处理方式", value: "本机离线 · VAD 智能分段 · 词级时间戳")

                HStack {
                    Button("刷新状态") { refreshID = UUID() }
                        .buttonStyle(.bordered)
                    Button("打开模型文件夹") {
                        try? FileManager.default.createDirectory(
                            at: TBOXTranscriptionModel.storageDirectory,
                            withIntermediateDirectories: true
                        )
                        NSWorkspace.shared.open(TBOXTranscriptionModel.storageDirectory)
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                }
            }
            .padding(18)
            .background(Color(nsColor: .controlBackgroundColor))
            .overlay(Rectangle().stroke(Color.secondary.opacity(0.2)))
            .id(refreshID)

            SectionTitle("隐私与降级策略")
            Text("模型下载完成后，录音仅在本机通过 Apple Neural Engine / GPU 处理，不上传录音。默认不会把录音交给系统在线语音服务。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 620, alignment: .leading)

            ToggleRow(
                title: "允许系统兼容识别",
                detail: "仅在本地模型失败时使用；macOS 可能通过网络处理录音",
                isOn: $allowSystemSpeechFallback
            )

            Text("首次转写需要联网下载模型；完成后可离线使用。模型由 Argmax WhisperKit 提供，固定为经过验证的稳定版本。")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.top, 12)
            Spacer()
        }
        .padding(32)
    }
}
private struct AccountPage: View { var body: some View { VStack(alignment: .leading, spacing: 0) { PageHeader(title: "账户", subtitle: "账户、订阅和点数将在后续版本开放"); HStack { Image(systemName: "person.crop.circle").font(.system(size: 40)); VStack(alignment: .leading) { Text("本地用户").font(.system(size: 15, weight: .medium)); Text("尚未登录云端账户").font(.system(size: 12)).foregroundStyle(.secondary) }; Spacer(); Button("登录") {}.buttonStyle(.bordered) }.padding(.bottom, 24); Divider(); InfoRow(title: "当前版本", value: "本地预览"); InfoRow(title: "订阅状态", value: "未连接"); InfoRow(title: "点数余额", value: "—"); Text("登录、订阅、充值和跨设备同步会在服务端准备完成后接入。").font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 20); Spacer() }.padding(32) } }
private struct SectionTitle: View { let title: String; init(_ title: String) { self.title = title }; var body: some View { Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).padding(.top, 24).padding(.bottom, 8) } }
private struct ActionButton: View { let title: String; let icon: String; let action: () -> Void; var body: some View { Button(action: action) { Label(title, systemImage: icon).font(.system(size: 12)) }.buttonStyle(.bordered).controlSize(.regular) } }
private struct PermissionRow: View { let title: String; let detail: String; let enabled: Bool; let action: () -> Void; var body: some View { HStack { VStack(alignment: .leading, spacing: 2) { Text(title).font(.system(size: 13)); Text(detail).font(.system(size: 11)).foregroundStyle(.secondary) }; Spacer(); Text(enabled ? "已允许" : "未允许").font(.system(size: 11)).foregroundStyle(enabled ? .green : .orange); Button("管理") { action() }.buttonStyle(.borderless) }.padding(.vertical, 10).overlay(alignment: .bottom) { Divider() } } }
private struct ToggleRow: View { let title: String; let detail: String; @Binding var isOn: Bool; var body: some View { HStack { VStack(alignment: .leading, spacing: 2) { Text(title).font(.system(size: 13)); Text(detail).font(.system(size: 11)).foregroundStyle(.secondary) }; Spacer(); Toggle("", isOn: $isOn).labelsHidden() }.padding(.vertical, 10).overlay(alignment: .bottom) { Divider() } } }
private struct ShortcutRow: View { let title: String; let detail: String; @Binding var value: String; var body: some View { HStack { VStack(alignment: .leading, spacing: 2) { Text(title).font(.system(size: 13)); Text(detail).font(.system(size: 11)).foregroundStyle(.secondary) }; Spacer(); TextField("快捷键", text: $value).textFieldStyle(.roundedBorder).frame(width: 180) }.padding(.vertical, 12).overlay(alignment: .bottom) { Divider() } } }
private struct InfoRow: View { let title: String; let value: String; var body: some View { HStack { Text(title).font(.system(size: 13)); Spacer(); Text(value).font(.system(size: 13)).foregroundStyle(.secondary) }.padding(.vertical, 12).overlay(alignment: .bottom) { Divider() } } }
