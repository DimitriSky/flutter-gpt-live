import AVFoundation
import Cocoa
import FlutterMacOS
import WebRTC
import flutter_webrtc

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    self.contentMinSize = NSSize(width: 360, height: 600)
    self.title = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "GPT Live"
    self.appearance = NSAppearance(named: .aqua)
    self.titlebarAppearsTransparent = true
    self.titleVisibility = .hidden
    self.backgroundColor = NSColor(srgbRed: 0.953, green: 0.941, blue: 0.910, alpha: 1)
    restoreOrDefaultFrame()

    RegisterGeneratedPlugins(registry: flutterViewController)
    CallRecorder.shared.register(messenger: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
  }
}

extension MainFlutterWindow {
  static let frameName = "GPTLiveMainWindow"

  /// Reopens with the last size and position (AppKit saves them under the
  /// autosave name on every move/resize). The first launch gets a phone-like
  /// portrait window: height = 2 × width, fitted to the screen.
  func restoreOrDefaultFrame() {
    if !setFrameUsingName(Self.frameName) {
      let visible = (screen ?? NSScreen.main)?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
      let height = min(880, visible.height - 60)
      setContentSize(NSSize(width: (height / 2).rounded(), height: height.rounded()))
      center()
    }
    setFrameAutosaveName(Self.frameName)
  }
}

// MARK: - Call recording (#REC, macOS only)

/// One audio channel of a call (microphone or assistant). Receives PCM buffers
/// from a WebRTC audio track, converts them to 48 kHz mono Int16 and streams
/// them to a temporary raw file, padding silence by wall clock so both
/// channels stay aligned (muted mic, reconnects during a voice switch).
final class ChannelWriter: NSObject, RTCAudioRenderer {
  static let rate = 48_000.0
  let url: URL
  private let handle: FileHandle
  private let queue: DispatchQueue
  private let start: CFTimeInterval
  private var written: Int64 = 0
  private var converter: AVAudioConverter?
  private var converterInput: AVAudioFormat?
  private let target = AVAudioFormat(
    commonFormat: .pcmFormatInt16, sampleRate: ChannelWriter.rate, channels: 1, interleaved: true)!
  private(set) var track: RTCAudioTrack?
  private(set) var localCapture = false
  /// While true (mic muted in the app) this channel records silence.
  var muted = false

  init(url: URL, start: CFTimeInterval, label: String) throws {
    self.url = url
    self.start = start
    FileManager.default.createFile(atPath: url.path, contents: nil)
    handle = try FileHandle(forWritingTo: url)
    queue = DispatchQueue(label: "gpt-live.recorder.\(label)")
  }

  /// Remote (assistant) audio: renderer on the received WebRTC track.
  func attach(_ newTrack: RTCAudioTrack?) {
    track?.remove(self)
    track = newTrack
    newTrack?.add(self)
  }

  /// Local microphone: renderers on local tracks get no frames, so tap the
  /// processed capture (after echo cancellation) shared by all local tracks.
  func attachLocalCapture() {
    guard !localCapture else { return }
    AudioManager.sharedInstance().addLocalAudioRenderer(self)
    localCapture = true
  }

  func detach() {
    attach(nil)
    if localCapture {
      AudioManager.sharedInstance().removeLocalAudioRenderer(self)
      localCapture = false
    }
  }

  /// Called on a WebRTC audio thread; the buffer is only valid during the call.
  func render(pcmBuffer: AVAudioPCMBuffer) {
    guard var samples = convert(pcmBuffer), !samples.isEmpty else { return }
    if muted { samples = Data(count: samples.count) }
    let arrival = CACurrentMediaTime()
    queue.async { [self] in
      let expectedEnd = Int64((arrival - start) * ChannelWriter.rate)
      let count = Int64(samples.count / 2)
      let gap = expectedEnd - count - written
      if gap > Int64(ChannelWriter.rate / 10) { pad(gap) }  // > 100 ms of missing audio
      handle.write(samples)
      written += count
    }
  }

  private func convert(_ buffer: AVAudioPCMBuffer) -> Data? {
    let format = buffer.format
    if format != converterInput {
      converter = AVAudioConverter(from: format, to: target)
      converterInput = format
    }
    guard let converter else { return nil }
    let ratio = target.sampleRate / format.sampleRate
    let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
    guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
    var supplied = false
    var error: NSError?
    converter.convert(to: out, error: &error) { _, status in
      if supplied { status.pointee = .noDataNow; return nil }
      supplied = true
      status.pointee = .haveData
      return buffer
    }
    guard error == nil, out.frameLength > 0, let data = out.int16ChannelData else { return nil }
    return Data(bytes: data[0], count: Int(out.frameLength) * 2)
  }

  private func pad(_ frames: Int64) {
    let chunk = Data(count: 9600 * 2)
    var left = frames
    while left > 0 {
      let n = min(left, 9600)
      handle.write(chunk.prefix(Int(n) * 2))
      left -= n
    }
    written += frames
  }

  /// Detaches, pads up to `frames` and returns the number of frames written.
  func finish(padTo frames: Int64) -> Int64 {
    detach()
    return queue.sync {
      if frames > written { pad(frames - written) }
      try? handle.close()
      return written
    }
  }

  func elapsedFrames() -> Int64 { Int64((CACurrentMediaTime() - start) * ChannelWriter.rate) }
}

/// Records a call into a stereo WAV: left = microphone, right = assistant.
final class CallRecorder {
  static let shared = CallRecorder()
  private var mic: ChannelWriter?
  private var assistant: ChannelWriter?
  private var output: URL?

  func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "gpt_live/recorder", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { return }
      let args = call.arguments as? [String: Any] ?? [:]
      switch call.method {
      case "directory":
        result(self.directory()?.path)
      case "start":
        result(self.start(path: args["path"] as? String, local: args["localTrackId"] as? String,
                          remote: args["remoteTrackId"] as? String))
      case "attach":
        self.attach(local: args["localTrackId"] as? String, remote: args["remoteTrackId"] as? String)
        result(nil)
      case "mute":
        self.mic?.muted = args["muted"] as? Bool ?? false
        result(nil)
      case "stop":
        result(self.stop())
      case "reveal":
        if let path = args["path"] as? String {
          NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
        result(nil)
      case "open":
        if let path = args["path"] as? String { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func directory() -> URL? {
    guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
    let dir = docs.appendingPathComponent("GPT Live Recordings", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  private func track(_ id: String?) -> RTCAudioTrack? {
    guard let id, let plugin = FlutterWebRTCPlugin.sharedSingleton() else { return nil }
    return plugin.track(forId: id, peerConnectionId: nil) as? RTCAudioTrack
  }

  private func start(path: String?, local: String?, remote: String?) -> Any? {
    guard mic == nil, let path else { return FlutterError(code: "busy", message: "Запись уже идёт.", details: nil) }
    let base = URL(fileURLWithPath: path)
    let now = CACurrentMediaTime()
    do {
      mic = try ChannelWriter(url: base.appendingPathExtension("mic.raw"), start: now, label: "mic")
      assistant = try ChannelWriter(url: base.appendingPathExtension("ai.raw"), start: now, label: "ai")
    } catch {
      mic = nil; assistant = nil
      return FlutterError(code: "io", message: error.localizedDescription, details: nil)
    }
    output = base
    attach(local: local, remote: remote)
    return ["micAttached": mic?.localCapture == true, "assistantAttached": assistant?.track != nil]
  }

  private func attach(local: String?, remote: String?) {
    mic?.attachLocalCapture()
    assistant?.attach(track(remote))
  }

  private func stop() -> Any? {
    guard let mic, let assistant, let output else { return nil }
    self.mic = nil; self.assistant = nil; self.output = nil
    let end = max(mic.elapsedFrames(), assistant.elapsedFrames())
    let frames = max(mic.finish(padTo: end), assistant.finish(padTo: end))
    defer {
      try? FileManager.default.removeItem(at: mic.url)
      try? FileManager.default.removeItem(at: assistant.url)
    }
    do {
      try writeStereoWav(to: output, left: mic.url, right: assistant.url, frames: frames)
    } catch {
      return FlutterError(code: "io", message: error.localizedDescription, details: nil)
    }
    return ["path": output.path, "seconds": Double(frames) / ChannelWriter.rate]
  }

  private func writeStereoWav(to url: URL, left: URL, right: URL, frames: Int64) throws {
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let out = try FileHandle(forWritingTo: url)
    defer { try? out.close() }
    let dataBytes = UInt32(clamping: frames * 4)
    var header = Data()
    func u32(_ v: UInt32) { var x = v.littleEndian; header.append(Data(bytes: &x, count: 4)) }
    func u16(_ v: UInt16) { var x = v.littleEndian; header.append(Data(bytes: &x, count: 2)) }
    header.append("RIFF".data(using: .ascii)!); u32(36 &+ dataBytes)
    header.append("WAVE".data(using: .ascii)!)
    header.append("fmt ".data(using: .ascii)!); u32(16); u16(1); u16(2)
    u32(UInt32(ChannelWriter.rate)); u32(UInt32(ChannelWriter.rate) * 4); u16(4); u16(16)
    header.append("data".data(using: .ascii)!); u32(dataBytes)
    out.write(header)
    let l = try FileHandle(forReadingFrom: left), r = try FileHandle(forReadingFrom: right)
    defer { try? l.close(); try? r.close() }
    let chunkFrames = 48_000
    var remaining = frames
    while remaining > 0 {
      let n = Int(min(remaining, Int64(chunkFrames)))
      var lb = l.readData(ofLength: n * 2), rb = r.readData(ofLength: n * 2)
      if lb.count < n * 2 { lb.append(Data(count: n * 2 - lb.count)) }
      if rb.count < n * 2 { rb.append(Data(count: n * 2 - rb.count)) }
      var interleaved = Data(count: n * 4)
      interleaved.withUnsafeMutableBytes { dst in
        lb.withUnsafeBytes { ls in
          rb.withUnsafeBytes { rs in
            let d = dst.bindMemory(to: Int16.self), a = ls.bindMemory(to: Int16.self), b = rs.bindMemory(to: Int16.self)
            for i in 0..<n { d[2 * i] = a[i]; d[2 * i + 1] = b[i] }
          }
        }
      }
      out.write(interleaved)
      remaining -= Int64(n)
    }
  }
}
