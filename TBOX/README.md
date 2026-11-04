# TBOX

TBOX 是一个 macOS 截图、录屏和本地录音转写工具。应用面向 macOS 14 及以上、Apple Silicon 构建。

## 构建

```bash
./compile.sh
./run_smoke_tests.sh
./build_app.sh
```

`build_app.sh` 使用固定的 `TBOX Development` 证书签名，并只替换工作区上一级唯一的 `TBOX.app`。脚本不会回退到 ad-hoc 签名，避免 macOS 隐私权限因签名身份变化而反复失效。

可用一份本地录音执行与客户端同路径的端到端验收（首次会下载固定模型）：

```bash
./.build/arm64-apple-macosx/release/TBOX --transcribe-file "/absolute/path/to/audio.caf"
```

该模式不启动界面、不请求系统权限、不上传录音；成功结果与客户端一样原子保存到录音相邻的转写缓存。

## 录音转写

录音转写默认使用本地 WhisperKit 1.1.0 和 Whisper Large v3 高精度模型（`large-v3-v20240930_626MB`）：

- 首次使用自动下载约 626 MB 模型；
- 下载后完全在本机通过 Core ML、Apple Neural Engine / GPU 运行；
- 使用 VAD 按真实语音边界切分，不再固定按时间硬切；
- 支持长录音增量读取、自动语言识别和词级时间戳；
- 可选同时采集系统声音（会议对方、网页播放的声音），与麦克风混为一路转写；需屏幕录制权限，失败自动降级为仅麦克风；
- 默认禁止上传；用户明确开启后，本地模型失败时才切换到 macOS Speech 兼容路径；
- 结果会明确标注“本地高精度识别”或“系统兼容识别”。

详细设计、隐私策略和验收要求见 [docs/TRANSCRIPTION.md](docs/TRANSCRIPTION.md)。

## 第三方组件

项目固定包含 Argmax OSS / WhisperKit v1.1.0 的必要源码。许可证和通知保存在：

- `Vendor/ArgmaxOSS/LICENSE`
- `Vendor/ArgmaxOSS/NOTICES`
- `Vendor/ArgmaxOSS/VERSION`
