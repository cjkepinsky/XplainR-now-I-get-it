import Cocoa
import FlutterMacOS
import AVFoundation
import ScreenCaptureKit
import Speech

final class LanguageProbeBuffer {
  private let lock = NSLock()
  private var samples: [Int16] = []
  private var sampleRate: Int = 16000
  private let maxDurationSeconds = 5.0

  func append(samples newSamples: [Int16], sampleRate newSampleRate: Int) {
    guard !newSamples.isEmpty, newSampleRate > 0 else { return }

    lock.lock()
    defer { lock.unlock() }

    if sampleRate != newSampleRate {
      samples.removeAll(keepingCapacity: true)
      sampleRate = newSampleRate
    }

    samples.append(contentsOf: newSamples)
    let maxSamples = max(Int(Double(sampleRate) * maxDurationSeconds), 1)
    if samples.count > maxSamples {
      samples.removeFirst(samples.count - maxSamples)
    }
  }

  func wavData(minDurationSeconds: Double = 3.0) -> Data? {
    lock.lock()
    let currentSamples = samples
    let currentSampleRate = sampleRate
    lock.unlock()

    guard currentSamples.count >= Int(Double(currentSampleRate) * minDurationSeconds) else {
      return nil
    }

    return Self.makeWavData(samples: currentSamples, sampleRate: currentSampleRate)
  }

  func clear() {
    lock.lock()
    samples.removeAll(keepingCapacity: true)
    lock.unlock()
  }

  private static func makeWavData(samples: [Int16], sampleRate: Int) -> Data {
    var data = Data()
    let bytesPerSample = 2
    let channelCount = 1
    let subchunk2Size = UInt32(samples.count * bytesPerSample)
    let chunkSize = UInt32(36) + subchunk2Size
    let byteRate = UInt32(sampleRate * channelCount * bytesPerSample)
    let blockAlign = UInt16(channelCount * bytesPerSample)
    let bitsPerSample = UInt16(16)

    appendAscii("RIFF", to: &data)
    appendLittleEndian(chunkSize, to: &data)
    appendAscii("WAVE", to: &data)
    appendAscii("fmt ", to: &data)
    appendLittleEndian(UInt32(16), to: &data)
    appendLittleEndian(UInt16(1), to: &data)
    appendLittleEndian(UInt16(channelCount), to: &data)
    appendLittleEndian(UInt32(sampleRate), to: &data)
    appendLittleEndian(byteRate, to: &data)
    appendLittleEndian(blockAlign, to: &data)
    appendLittleEndian(bitsPerSample, to: &data)
    appendAscii("data", to: &data)
    appendLittleEndian(subchunk2Size, to: &data)

    for sample in samples {
      appendLittleEndian(UInt16(bitPattern: sample), to: &data)
    }

    return data
  }

  private static func appendAscii(_ value: String, to data: inout Data) {
    data.append(value.data(using: .ascii)!)
  }

  private static func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
    var littleEndian = value.littleEndian
    withUnsafeBytes(of: &littleEndian) { bytes in
      data.append(contentsOf: bytes)
    }
  }
}

final class MicrophoneLanguageProbe {
  private let engine = AVAudioEngine()
  private let probeBuffer = LanguageProbeBuffer()
  private var isStarted = false

  func start() async throws {
    if isStarted { return }
    try await requestAudioAuthorization()

    let inputNode = engine.inputNode
    let format = inputNode.outputFormat(forBus: 0)
    probeBuffer.clear()
    inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
      self?.append(buffer: buffer)
    }

    engine.prepare()
    do {
      try engine.start()
      isStarted = true
    } catch {
      inputNode.removeTap(onBus: 0)
      throw error
    }
  }

  func stop() {
    guard isStarted else {
      probeBuffer.clear()
      return
    }
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    probeBuffer.clear()
    isStarted = false
  }

  func takeWavData() -> Data? {
    probeBuffer.wavData()
  }

  private func append(buffer: AVAudioPCMBuffer) {
    let frameLength = Int(buffer.frameLength)
    let channelCount = max(Int(buffer.format.channelCount), 1)
    let sampleRate = Int(buffer.format.sampleRate.rounded())
    guard frameLength > 0, sampleRate > 0 else { return }

    var probeSamples: [Int16] = []
    probeSamples.reserveCapacity(frameLength)

    if let floatChannels = buffer.floatChannelData {
      for frame in 0..<frameLength {
        var mixed = 0.0
        for channel in 0..<channelCount {
          mixed += Double(floatChannels[channel][frame])
        }
        mixed /= Double(channelCount)
        probeSamples.append(Self.floatToInt16(mixed))
      }
    } else if let int16Channels = buffer.int16ChannelData {
      for frame in 0..<frameLength {
        var mixed = 0
        for channel in 0..<channelCount {
          mixed += Int(int16Channels[channel][frame])
        }
        probeSamples.append(Int16(clamping: mixed / channelCount))
      }
    }

    probeBuffer.append(samples: probeSamples, sampleRate: sampleRate)
  }

  private static func floatToInt16(_ value: Double) -> Int16 {
    let clamped = max(-1.0, min(1.0, value))
    return Int16(clamping: Int(clamped * Double(Int16.max)))
  }

  private func requestAudioAuthorization() async throws {
    let status = AVCaptureDevice.authorizationStatus(for: .audio)
    if status == .authorized { return }

    if status == .notDetermined {
      let granted = await withCheckedContinuation { continuation in
        AVCaptureDevice.requestAccess(for: .audio) { granted in
          continuation.resume(returning: granted)
        }
      }
      if granted { return }
    }

    throw NSError(domain: "Xplainr", code: 7, userInfo: [
      NSLocalizedDescriptionKey: "Microphone permission is not granted."
    ])
  }
}

final class SystemAudioTranscriptionPlugin: NSObject, FlutterStreamHandler {
  private let transcriber = SystemAudioTranscriber()
  private let microphoneProbe = MicrophoneLanguageProbe()

  func register(binaryMessenger: FlutterBinaryMessenger) {
    let methods = FlutterMethodChannel(
      name: "xplainr/system_audio_control",
      binaryMessenger: binaryMessenger
    )
    let events = FlutterEventChannel(
      name: "xplainr/system_audio_events",
      binaryMessenger: binaryMessenger
    )

    events.setStreamHandler(self)
    methods.setMethodCallHandler { [weak self] call, result in
      guard let self else { return }

      switch call.method {
      case "start":
        let args = call.arguments as? [String: Any]
        let localeId = args?["localeId"] as? String ?? "en_US"
        Task {
          do {
            try await self.transcriber.start(localeId: localeId)
            result(true)
          } catch {
            result(FlutterError(
              code: "SYSTEM_AUDIO_START_FAILED",
              message: error.localizedDescription,
              details: nil
            ))
          }
        }
      case "stop":
        Task {
          await self.transcriber.stop()
          result(true)
        }
      case "startMicrophoneProbe":
        Task {
          do {
            try await self.microphoneProbe.start()
            result(true)
          } catch {
            result(FlutterError(
              code: "MICROPHONE_PROBE_START_FAILED",
              message: error.localizedDescription,
              details: nil
            ))
          }
        }
      case "stopMicrophoneProbe":
        self.microphoneProbe.stop()
        result(true)
      case "takeLanguageProbe":
        let args = call.arguments as? [String: Any]
        let source = args?["source"] as? String ?? "system"
        let data = source == "microphone"
          ? self.microphoneProbe.takeWavData()
          : self.transcriber.takeLanguageProbeData()
        if let data {
          result(FlutterStandardTypedData(bytes: data))
        } else {
          result(nil)
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    transcriber.eventSink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    transcriber.eventSink = nil
    return nil
  }
}

final class SystemAudioTranscriber: NSObject, SCStreamOutput, SCStreamDelegate {
  var eventSink: FlutterEventSink?

  private var stream: SCStream?
  private var request: SFSpeechAudioBufferRecognitionRequest?
  private var task: SFSpeechRecognitionTask?
  private var recognizer: SFSpeechRecognizer?
  private var lastLevelEmit = Date.distantPast
  private let sampleQueue = DispatchQueue(label: "xplainr.system-audio.samples")
  private let languageProbeBuffer = LanguageProbeBuffer()

  func start(localeId: String) async throws {
    await stop()
    languageProbeBuffer.clear()
    try await requestSpeechAuthorization()
    try await requestScreenCaptureAuthorization()

    let normalizedLocale = localeId.replacingOccurrences(of: "_", with: "-")
    guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: normalizedLocale)) else {
      throw NSError(domain: "Xplainr", code: 1, userInfo: [
        NSLocalizedDescriptionKey: "Speech recognizer is not available for \(normalizedLocale)."
      ])
    }
    guard recognizer.isAvailable else {
      throw NSError(domain: "Xplainr", code: 2, userInfo: [
        NSLocalizedDescriptionKey: "Speech recognizer is temporarily unavailable."
      ])
    }

    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = true
    request.taskHint = .dictation

    self.recognizer = recognizer
    self.request = request
    self.task = recognizer.recognitionTask(with: request) { [weak self] result, error in
      if let result {
        self?.emit([
          "type": "transcript",
          "text": result.bestTranscription.formattedString,
          "final": result.isFinal
        ])
      }

      if let error {
        self?.emit([
          "type": "error",
          "message": error.localizedDescription
        ])
      }
    }

    let content = try await SCShareableContent.current
    guard let display = content.displays.first else {
      throw NSError(domain: "Xplainr", code: 3, userInfo: [
        NSLocalizedDescriptionKey: "No display found for system audio capture."
      ])
    }

    let currentApplication = content.applications.first { application in
      application.bundleIdentifier == Bundle.main.bundleIdentifier
    }
    let excludedApplications = currentApplication.map { [$0] } ?? []
    let filter = SCContentFilter(
      display: display,
      excludingApplications: excludedApplications,
      exceptingWindows: []
    )
    let config = SCStreamConfiguration()
    config.width = 2
    config.height = 2
    config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
    config.queueDepth = 3
    config.capturesAudio = true
    config.excludesCurrentProcessAudio = true
    config.sampleRate = 16000
    config.channelCount = 1

    let stream = SCStream(filter: filter, configuration: config, delegate: self)
    try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
    try await stream.startCapture()

    self.stream = stream
    emit(["type": "status", "message": "System audio capture started."])
  }

  func stream(_ stream: SCStream, didStopWithError error: Error) {
    emit([
      "type": "error",
      "message": "System audio stream stopped: \(error.localizedDescription)"
    ])
  }

  func stop() async {
    request?.endAudio()
    task?.cancel()
    task = nil
    request = nil
    recognizer = nil

    if let stream {
      try? await stream.stopCapture()
      self.stream = nil
    }

    languageProbeBuffer.clear()
    emit(["type": "status", "message": "System audio capture stopped."])
  }

  func takeLanguageProbeData() -> Data? {
    languageProbeBuffer.wavData()
  }

  func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
    guard type == .audio, CMSampleBufferDataIsReady(sampleBuffer) else { return }
    request?.appendAudioSampleBuffer(sampleBuffer)
    emitLevel(from: sampleBuffer)
  }

  private func emitLevel(from sampleBuffer: CMSampleBuffer) {
    let now = Date()
    guard now.timeIntervalSince(lastLevelEmit) >= 0.12 else { return }
    lastLevelEmit = now

    guard
      let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
      let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
    else {
      return
    }

    let asbd = streamDescription.pointee
    var blockBuffer: CMBlockBuffer?
    var audioBufferList = AudioBufferList(
      mNumberBuffers: 1,
      mBuffers: AudioBuffer(mNumberChannels: 0, mDataByteSize: 0, mData: nil)
    )

    let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
      sampleBuffer,
      bufferListSizeNeededOut: nil,
      bufferListOut: &audioBufferList,
      bufferListSize: MemoryLayout<AudioBufferList>.size,
      blockBufferAllocator: kCFAllocatorDefault,
      blockBufferMemoryAllocator: kCFAllocatorDefault,
      flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
      blockBufferOut: &blockBuffer
    )

    guard status == noErr else { return }

    let buffers = UnsafeMutableAudioBufferListPointer(&audioBufferList)
    let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
    let bytesPerSample = max(Int(asbd.mBitsPerChannel / 8), 1)
    let sampleRate = Int(asbd.mSampleRate.rounded())
    var sumSquares = 0.0
    var sampleCount = 0
    var probeSamples: [Int16] = []

    for buffer in buffers {
      guard let data = buffer.mData else { continue }
      let count = Int(buffer.mDataByteSize) / bytesPerSample
      probeSamples.reserveCapacity(probeSamples.count + count)
      if isFloat && bytesPerSample == MemoryLayout<Float32>.size {
        let samples = data.bindMemory(to: Float32.self, capacity: count)
        for index in 0..<count {
          let sample = Double(samples[index])
          sumSquares += sample * sample
          probeSamples.append(Self.floatToInt16(sample))
        }
      } else if bytesPerSample == MemoryLayout<Int16>.size {
        let samples = data.bindMemory(to: Int16.self, capacity: count)
        for index in 0..<count {
          let sample = Double(samples[index]) / Double(Int16.max)
          sumSquares += sample * sample
          probeSamples.append(samples[index])
        }
      }
      sampleCount += count
    }

    guard sampleCount > 0 else { return }
    languageProbeBuffer.append(samples: probeSamples, sampleRate: sampleRate)

    let rms = sqrt(sumSquares / Double(sampleCount))
    let db = 20.0 * log10(max(rms, 0.000001))
    let percent = max(0.0, min(100.0, ((db + 60.0) / 60.0) * 100.0))

    emit([
      "type": "level",
      "level": percent
    ])
  }

  private static func floatToInt16(_ value: Double) -> Int16 {
    let clamped = max(-1.0, min(1.0, value))
    return Int16(clamping: Int(clamped * Double(Int16.max)))
  }

  private func requestSpeechAuthorization() async throws {
    let status = SFSpeechRecognizer.authorizationStatus()
    if status == .authorized { return }

    if status == .notDetermined {
      let granted = await withCheckedContinuation { continuation in
        SFSpeechRecognizer.requestAuthorization { newStatus in
          continuation.resume(returning: newStatus == .authorized)
        }
      }
      if granted { return }
    }

    throw NSError(domain: "Xplainr", code: 4, userInfo: [
      NSLocalizedDescriptionKey: "Speech Recognition permission is not granted."
    ])
  }

  private func requestScreenCaptureAuthorization() async throws {
    if CGPreflightScreenCaptureAccess() {
      return
    }

    emit([
      "type": "status",
      "message": "macOS wymaga uprawnienia Screen & System Audio Recording dla XplainR."
    ])

    let granted = CGRequestScreenCaptureAccess()
    if granted {
      throw NSError(domain: "Xplainr", code: 5, userInfo: [
        NSLocalizedDescriptionKey:
          "Screen & System Audio Recording permission was granted. Restart XplainR and start system audio again."
      ])
    }

    throw NSError(domain: "Xplainr", code: 6, userInfo: [
      NSLocalizedDescriptionKey:
        "Screen & System Audio Recording permission is not granted for XplainR."
    ])
  }

  private func emit(_ payload: [String: Any]) {
    DispatchQueue.main.async { [weak self] in
      self?.eventSink?(payload)
    }
  }
}

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }
}
