import AppKit
import SwiftUI
import TranscodeCore

struct ParametersView: View {
    enum Section: String, CaseIterable, Identifiable {
        case overview = "参数总览", presets = "预设管理", output = "输出文件设置", decode = "解码设置"
        case codec = "视频参数 | 编码器", image = "视频参数 | 画面帧", quality = "视频参数 | 质量"
        case color = "视频参数 | 色彩管理", effects = "视频滤镜及字幕", audio = "音频参数"
        case trim = "剪辑区间", custom = "自定义参数", streams = "流控制"

        var id: Self { self }
    }

    @Bindable var model: Workspace
    @State private var section = Section.overview
    private let templates = [
        "H.264 通用 MP4", "H.265 软件压制", "H.264 VideoToolbox", "H.265 VideoToolbox",
        "AV1 软件压制", "MKV 无损重封装", "提取音频 M4A"
    ]

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Section.allCases) { item in
                        Button { section = item } label: {
                            Text(item.rawValue)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 9).padding(.vertical, 7)
                                .contentShape(Rectangle())
                                .background(section == item ? Color.accentColor.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 6))
                        }.buttonStyle(.plain)
                    }
                }.padding(10)
            }.frame(width: 170).background(.thinMaterial)
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Text(section.rawValue).font(.title.bold())
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        fields
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                HStack {
                    Text("\(model.inputs.count) 个待处理文件").foregroundStyle(.secondary)
                    Spacer()
                    Button("准备文件") { model.page = .files }
                    Button("添加到编码队列") { model.enqueue() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.inputs.isEmpty)
                }
            }.padding(22)
        }
    }

    @ViewBuilder private var fields: some View {
        switch section {
        case .overview:
            LabeledContent("封装") { Text(model.preset.container.uppercased()) }
            LabeledContent("视频编码") { Text(model.preset.video) }
            LabeledContent("音频编码") { Text(model.preset.audio) }
            LabeledContent("输出目录") { Text(model.outputFolder?.path ?? "源文件所在目录").textSelection(.enabled) }
            Divider()
            Text("FFmpeg 命令预览").font(.headline)
            Text(commandPreview).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                .background(.black.opacity(0.24), in: RoundedRectangle(cornerRadius: 8))
        case .presets:
            Text("内置预设").font(.headline)
            ForEach(templates, id: \.self) { name in
                Button(name) { model.preset = .template(name); section = .overview }
            }
            Divider()
            HStack {
                Button("导入 macOS 预设…") { model.importPreset() }
                Button("导出当前预设…") { model.exportPreset() }
            }
        case .output:
            row("封装扩展名", $model.preset.container, "mp4 / mkv / mov / webm / m4a")
            row("文件名后缀", $model.preset.suffix, "_3FUI")
            Toggle("索引前置  +faststart", isOn: $model.preset.fastStart)
            HStack {
                Button("选择输出目录…") {
                    if let folder = Workspace.open(files: false, folders: true).first { model.outputFolder = folder }
                }
                Text(model.outputFolder?.path ?? "源文件所在目录").foregroundStyle(.secondary).textSelection(.enabled)
                if model.outputFolder != nil { Button("恢复默认") { model.outputFolder = nil } }
            }
        case .decode:
            Toggle("VideoToolbox 硬件解码  -hwaccel videotoolbox", isOn: $model.preset.hardwareDecode)
            row("输入参数", $model.preset.inputOptions, "例如 -threads 4")
        case .codec:
            options("视频编码器  -c:v", $model.preset.video, ["libx264", "libx265", "libsvtav1", "libaom-av1", "h264_videotoolbox", "hevc_videotoolbox", "prores_videotoolbox", "copy", "关闭"])
            row("编码器名称", $model.preset.video, "支持手动输入 FFmpeg 编码器")
            row("编码预设  -preset", $model.preset.speed, "例如 medium / slow / 6")
            if model.preset.video.hasSuffix("_videotoolbox") {
                Text("VideoToolbox 可在质量页设置视频比特率。").foregroundStyle(.secondary)
            }
        case .image:
            row("缩放  -vf scale", $model.preset.scale, "例如 1920:-2")
            row("裁剪  -vf crop", $model.preset.crop, "例如 1920:800:0:140")
            row("输出帧率  -r", $model.preset.frameRate, "例如 24000/1001")
        case .quality:
            row("质量参数名", $model.preset.qualityOption, "例如 crf 或 q")
            row("质量值", $model.preset.quality, "例如 23，留空时省略")
            row("视频比特率  -b:v", $model.preset.videoBitrate, "例如 5M")
        case .color:
            row("像素格式  -pix_fmt", $model.preset.pixelFormat, "例如 yuv420p / yuv420p10le")
            row("矩阵系数  -colorspace", $model.preset.colorSpace, "例如 bt709 / bt2020nc")
            row("色域  -color_primaries", $model.preset.colorPrimaries, "例如 bt709 / bt2020")
            row("传递函数  -color_trc", $model.preset.transfer, "例如 bt709 / smpte2084")
            row("色彩范围  -color_range", $model.preset.colorRange, "例如 tv / pc")
        case .effects:
            row("视频滤镜  -vf", $model.preset.filters, "例如 hflip,eq=contrast=1.1")
            Button("添加烧录字幕…") {
                if let file = Workspace.open().first {
                    let filter = Preset.subtitleFilter(for: file)
                    model.preset.filters += model.preset.filters.isEmpty ? filter : "," + filter
                }
            }
            Text("顺序为裁剪、缩放、自定义滤镜。复制视频流时，视频滤镜和烧录字幕会被跳过。")
                .foregroundStyle(.secondary)
        case .audio:
            options("音频编码器  -c:a", $model.preset.audio, ["aac", "libopus", "libmp3lame", "flac", "pcm_s16le", "copy", "关闭"])
            row("编码器名称", $model.preset.audio, "支持手动输入 FFmpeg 编码器")
            row("比特率  -b:a", $model.preset.audioBitrate, "例如 192k")
            row("声道数  -ac", $model.preset.channels, "例如 2")
            row("采样率  -ar", $model.preset.sampleRate, "例如 48000")
            row("音频滤镜  -af", $model.preset.audioFilters, "例如 volume=1.5")
        case .trim:
            row("开始时间  -ss", $model.preset.start, "例如 00:01:00.500")
            row("编码时长  -t", $model.preset.duration, "例如 30 或 00:00:30")
        case .custom:
            row("输入前参数", $model.preset.inputOptions, "例如 -threads 4")
            row("输出前参数", $model.preset.outputOptions, "例如 -metadata 'title=我的视频'")
            Text("使用引号保留空格。参数直接传给 FFmpeg。").foregroundStyle(.secondary)
        case .streams:
            row("流映射  -map", $model.preset.streams, "例如 0:v:0, 0:a?, 0:s?")
            options("字幕  -c:s", $model.preset.subtitles, ["默认", "复制", "转为 mov_text", "关闭"])
            Toggle("保留元数据", isOn: $model.preset.metadata)
            Toggle("保留章节", isOn: $model.preset.chapters)
        }
    }

    private var commandPreview: String {
        let input = model.inputs.first ?? URL(fileURLWithPath: "/输入文件.mov")
        do {
            let output = try (model.outputFolder ?? input.deletingLastPathComponent()).appendingPathComponent(model.preset.outputName(for: input))
            return CommandLineSyntax.display(["ffmpeg", "-n"] + (try model.preset.arguments(input: input)) + [output.path])
        } catch { return error.localizedDescription }
    }

    private func row(_ title: String, _ value: Binding<String>, _ prompt: String) -> some View {
        HStack {
            Text(title).frame(width: 172, alignment: .leading)
            TextField(title, text: value, prompt: Text(prompt)).labelsHidden().textFieldStyle(.roundedBorder)
        }
    }

    private func options(_ title: String, _ value: Binding<String>, _ choices: [String]) -> some View {
        HStack {
            Text(title).frame(width: 172, alignment: .leading)
            Picker(title, selection: value) {
                if !choices.contains(value.wrappedValue) { Text(value.wrappedValue).tag(value.wrappedValue) }
                ForEach(choices, id: \.self) { Text($0).tag($0) }
            }.labelsHidden().frame(maxWidth: 260)
        }
    }
}
