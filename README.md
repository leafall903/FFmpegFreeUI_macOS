# FFmpegFreeUI_macOS

FFmpegFreeUI（3FUI）的原生 macOS 移植版。主分支 `main` 是 SwiftUI 工程，使用系统文件面板和 Finder 集成。编码由本机 FFmpeg 执行。

## 安装与运行

系统要求为 macOS 14 或更高版本。通用 App 包含 Apple 芯片和 Intel 两种架构。

1. 安装 FFmpeg，例如 `brew install ffmpeg`。程序会自动搜索 Homebrew、MacPorts 和 PATH，也可以在「软件设置」中分别指定 ffmpeg、ffprobe 和 ffplay。
2. 安装 Xcode 16 或兼容的 Swift 6 工具链。
3. 在项目目录运行 `./script/build_and_run.sh`。构建产物在 `dist/FFmpegFreeUI_macOS.app`。仅打包可运行 `./script/build-app.sh`。

构建脚本使用本地临时签名。项目不附带 FFmpeg，编码器、滤镜及 ffplay 的可用性取决于安装的 FFmpeg 构建。

## 使用

1. 在「准备文件」中添加或拖入文件、文件夹，按需选择输出目录。
2. 在「参数面板」中应用内置预设或编辑参数，然后添加到队列。支持 H.264、H.265、AV1、VideoToolbox、无损重封装和音频提取。
3. 打开「编码队列」，点击「开始」。可暂停、恢复或停止当前任务，并查看参数、日志和输出位置。

参数面板提供裁剪、缩放、帧率、色彩标记、字幕烧录、音频滤镜、剪辑、流映射和自定义 FFmpeg 参数。输出先写入目标目录中的临时文件，成功后再发布到最终路径。遇到文件名冲突时，队列不会覆盖现有文件。

「集成工具」支持顺序合并、MKV 混流，以及 SSIM、PSNR、VMAF、XPSNR 质量评测。合并要求各段的流布局和编码参数相同。质量评测要求两个视频分辨率一致、帧对齐。

## 移植范围

当前版本覆盖 3FUI 的核心编码工作流。预设采用 macOS 版 JSON 格式，Windows 版预设、插件、Agent、远程任务接口、Windows 硬件监控和支持者功能尚未移植。

## 开发

```sh
swift test
./script/build_and_run.sh --verify
```

测试包含参数解析、重封装、预设选项、文件名转义、队列持久化和输出碰撞保护。已安装 ffmpeg 和 ffprobe 时会执行真实媒体处理测试。

项目源自 [Lake1059/FFmpegFreeUI](https://github.com/Lake1059/FFmpegFreeUI)，移植时参考了 [leafall903/FFmpegFreeUI](https://github.com/leafall903/FFmpegFreeUI/tree/154cfa5) 的 v6 界面与工作流。原项目版权归 1059 Studio 所有，许可见 [LICENSE.txt](LICENSE.txt)。
