import Cocoa
import FlutterMacOS
import ScreenCaptureKit
import Speech

final class SystemAudioTranscriptionPlugin: NSObject, FlutterStreamHandler {
  private let transcriber = SystemAudioTranscriber()

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

  func start(localeId: String) async throws {
    await stop()
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

    emit(["type": "status", "message": "System audio capture stopped."])
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
    var sumSquares = 0.0
    var sampleCount = 0

    for buffer in buffers {
      guard let data = buffer.mData else { continue }
      let count = Int(buffer.mDataByteSize) / bytesPerSample
      if isFloat && bytesPerSample == MemoryLayout<Float32>.size {
        let samples = data.bindMemory(to: Float32.self, capacity: count)
        for index in 0..<count {
          let sample = Double(samples[index])
          sumSquares += sample * sample
        }
      } else if bytesPerSample == MemoryLayout<Int16>.size {
        let samples = data.bindMemory(to: Int16.self, capacity: count)
        for index in 0..<count {
          let sample = Double(samples[index]) / Double(Int16.max)
          sumSquares += sample * sample
        }
      }
      sampleCount += count
    }

    guard sampleCount > 0 else { return }

    let rms = sqrt(sumSquares / Double(sampleCount))
    let db = 20.0 * log10(max(rms, 0.000001))
    let percent = max(0.0, min(100.0, ((db + 60.0) / 60.0) * 100.0))

    emit([
      "type": "level",
      "level": percent
    ])
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
