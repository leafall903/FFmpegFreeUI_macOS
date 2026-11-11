import AppKit
import SwiftUI
import TranscodeCore

struct SettingsView: View {
    @Bindable var model: Workspace
    @State private var detected = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("软件设置").font(.title.bold())
            Text("FFmpeg 可执行文件").font(.headline)
            Text("留空时自动查找 Homebrew、MacPorts 和 PATH。").foregroundStyle(.secondary)
            field("ffmpeg", $model.ffmpeg)
            field("ffprobe", $model.ffprobe)
            field("ffplay", $model.ffplay)
            Button("检查工具路径") {
                detected = [("ffmpeg", model.ffmpeg), ("ffprobe", model.ffprobe), ("ffplay", model.ffplay)].map { name, path in
                    do { return try Toolchain.executable(name, configured: path).path }
                    catch { return error.localizedDescription }
                }.joined(separator: "\n")
            }
            if !detected.isEmpty { Text(detected).font(.system(.callout, design: .monospaced)).textSelection(.enabled) }
            Spacer()
        }
    }

    private func field(_ name: String, _ value: Binding<String>) -> some View {
        HStack {
            Text(name).frame(width: 64, alignment: .leading)
            TextField(name, text: value, prompt: Text("自动检测")).labelsHidden().textFieldStyle(.roundedBorder)
            Button("选取…") { if let url = Workspace.open().first { value.wrappedValue = url.path } }
        }
    }
}

struct MediaToolView: View {
    let model: Workspace
    let play: Bool
    @State private var file: URL?
    @State private var report = ""
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(play ? "ffplay 调试播放器" : "ffprobe 媒体信息").font(.title.bold())
            HStack {
                Button("选择媒体文件…") { if let url = Workspace.open().first { open(url) } }.disabled(busy)
                if let file {
                    Text(file.lastPathComponent).lineLimit(1).foregroundStyle(.secondary)
                    Button(play ? "重新播放" : "重新读取") { open(file) }.disabled(busy)
                }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
            }
            if report.isEmpty {
                ContentUnavailableView("拖入一个媒体文件", systemImage: play ? "play.rectangle" : "info.circle")
            } else {
                ScrollView {
                    Text(report).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                }
                .background(.black.opacity(0.23), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(22)
        .dropDestination(for: URL.self) { files, _ in
            guard let file = files.first, !busy else { return false }
            open(file)
            return true
        }
    }

    private func open(_ url: URL) {
        file = url
        busy = true
        report = ""
        Task {
            defer { busy = false }
            do {
                if play {
                    let executable = try Toolchain.executable("ffplay", configured: model.ffplay)
                    let process = Process()
                    process.executableURL = executable
                    process.arguments = ["-autoexit", "-i", url.path]
                    process.standardInput = FileHandle.nullDevice
                    process.standardOutput = FileHandle.nullDevice
                    process.standardError = FileHandle.nullDevice
                    try process.run()
                    report = "已启动 ffplay。播放器会在独立窗口打开。"
                    let status = await Task.detached {
                        process.waitUntilExit()
                        return process.terminationStatus
                    }.value
                    report = status == 0 ? "播放已结束。" : "ffplay 退出代码 \(status)。"
                } else {
                    let executable = try Toolchain.executable("ffprobe", configured: model.ffprobe)
                    report = try await Toolchain.capture(executable, ["-v", "error", "-show_format", "-show_streams", "-show_chapters", "-of", "json", url.path])
                }
            } catch { report = error.localizedDescription }
        }
    }
}

struct ToolsView: View {
    let model: Workspace
    @State private var mode = "合并"
    @State private var files: [URL] = []
    @State private var selection: URL?
    @State private var reference: URL?
    @State private var candidate: URL?
    @State private var metric = "ssim"
    @State private var duration = ""
    @State private var result = ""
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("集成工具").font(.title.bold())
            Picker("工具", selection: $mode) {
                ForEach(["合并", "混流", "质量评测"], id: \.self) { Text($0) }
            }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 350)
            Divider()
            if mode == "质量评测" {
                quality
            } else {
                assembly
            }
            Spacer(minLength: 0)
        }.padding(22)
    }

    private var assembly: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(mode == "合并" ? "按列表顺序首尾相接。源文件的流布局和编码参数须一致。" : "保留各输入的流并装入同一个 MKV 文件。")
                .foregroundStyle(.secondary)
            HStack {
                Button("添加文件…") { add(Workspace.open(multiple: true)) }
                Button("移除") {
                    files.removeAll { $0 == selection }
                    selection = nil
                }.disabled(selection == nil)
                Button("上移") { move(-1) }.disabled(!canMove(-1))
                Button("下移") { move(1) }.disabled(!canMove(1))
                Spacer()
                Button("添加到编码队列") {
                    do {
                        try model.queue.enqueueTool(files, mode: mode, folder: model.outputFolder)
                        model.page = .queue
                    } catch { model.queue.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent).disabled(files.count < 2)
            }
            List(files, id: \.self, selection: $selection) { file in
                Text(file.lastPathComponent).help(file.path)
            }.dropDestination(for: URL.self) { urls, _ in add(urls); return !urls.isEmpty }
        }
    }

    private var quality: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("选择参考视频…") { reference = Workspace.open().first ?? reference }
                Text(reference?.lastPathComponent ?? "未选取").foregroundStyle(.secondary)
            }
            HStack {
                Button("选择待评视频…") { candidate = Workspace.open().first ?? candidate }
                Text(candidate?.lastPathComponent ?? "未选取").foregroundStyle(.secondary)
            }
            HStack {
                Picker("指标", selection: $metric) {
                    Text("SSIM").tag("ssim")
                    Text("PSNR").tag("psnr")
                    Text("VMAF").tag("libvmaf")
                    Text("XPSNR").tag("xpsnr")
                }.fixedSize()
                TextField("时长（可留空）", text: $duration).frame(width: 160)
                Button("开始评测") { evaluate() }.buttonStyle(.borderedProminent)
                    .disabled(reference == nil || candidate == nil || busy)
                if busy { ProgressView().controlSize(.small) }
            }
            .disabled(busy)
            Text("两段视频需逐帧对齐并具有相同分辨率。指标取决于 FFmpeg 的编译选项。").foregroundStyle(.secondary)
            ScrollView {
                Text(result).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(10)
            }.background(.black.opacity(0.23), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func add(_ urls: [URL]) {
        for url in urls where !files.contains(url) { files.append(url) }
    }

    private func canMove(_ step: Int) -> Bool {
        guard let selection, let index = files.firstIndex(of: selection) else { return false }
        return files.indices.contains(index + step)
    }

    private func move(_ step: Int) {
        guard canMove(step), let selection, let index = files.firstIndex(of: selection) else { return }
        files.swapAt(index, index + step)
    }

    private func evaluate() {
        guard let reference, let candidate else { return }
        busy = true
        result = ""
        let filter = metric
        let limit = duration
        Task {
            defer { busy = false }
            do {
                let executable = try Toolchain.executable("ffmpeg", configured: model.ffmpeg)
                let cap = limit.isEmpty ? [] : ["-t", limit]
                let graph = "[0:v]settb=AVTB,setpts=PTS-STARTPTS[test];[1:v]settb=AVTB,setpts=PTS-STARTPTS[ref];[test][ref]\(filter)=shortest=1"
                let args = ["-hide_banner", "-nostdin", "-nostats"] + cap + ["-i", candidate.path] + cap + ["-i", reference.path, "-an", "-filter_complex", graph, "-f", "null", "-"]
                let output = try await Toolchain.capture(executable, args)
                result = output.split(separator: "\n").suffix(16).joined(separator: "\n")
            } catch { result = error.localizedDescription }
        }
    }
}
