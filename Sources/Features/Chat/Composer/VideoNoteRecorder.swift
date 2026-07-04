import SwiftUI
import AVFoundation

/// §16.2: captures round video messages — square 400×400 mp4, H.264 ~1 Mbps
/// (high profile), AAC mono 64 kbps 48 kHz, 30 fps, front camera by default.
///
/// The main-actor recorder only publishes UI state (elapsed, camera side); ALL
/// capture/writer work is confined to the pipeline's serial queue — nothing
/// blocking ever runs on the main actor (§14.2's watchdog lesson). On hardware
/// without a camera (the simulator) the recorder runs as a stub: the timer and
/// the whole lock/cancel UI still work, `finish()` just produces no file.
@MainActor
final class VideoNoteRecorder: ObservableObject {
    @Published var isRunning = false
    @Published var elapsed: TimeInterval = 0
    @Published var usingFrontCamera = true
    /// No capture hardware (simulator) — the overlay shows a placeholder circle.
    @Published private(set) var isStub = false

    private let pipeline = VideoNoteCapturePipeline()
    var captureSession: AVCaptureSession { pipeline.session }

    private var timer: Timer?
    private var startDate: Date?

    /// Ask for permissions and spin the session + writer up off the main actor.
    func start() {
        guard !isRunning else { return }
        elapsed = 0
        usingFrontCamera = true

        guard VideoNoteCapturePipeline.hasCamera else {
            // Simulator / no camera: stub recording so the UI is fully exercisable.
            isStub = true
            beginTimer()
            isRunning = true
            return
        }

        beginTimer()
        isRunning = true
        AVCaptureDevice.requestAccess(for: .video) { [pipeline] videoGranted in
            AVCaptureDevice.requestAccess(for: .audio) { audioGranted in
                guard videoGranted else { return }
                pipeline.start(withAudio: audioGranted)
            }
        }
    }

    /// Stop and hand back the finished square mp4 (nil in stub mode / too short).
    func finish() async -> (url: URL, durationMs: Int)? {
        let duration = elapsed
        endTimer()
        isRunning = false
        if isStub { return nil }
        guard duration > 0.5 else {
            pipeline.cancel()
            return nil
        }
        return await pipeline.finish(fallbackDuration: duration)
    }

    /// Discard the recording (slide-to-cancel / Cancel button).
    func cancel() {
        endTimer()
        isRunning = false
        guard !isStub else { return }
        pipeline.cancel()
    }

    func flipCamera() {
        guard !isStub else { return }
        usingFrontCamera.toggle()
        pipeline.setCamera(front: usingFrontCamera)
    }

    private func beginTimer() {
        startDate = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let start = self.startDate else { return }
                self.elapsed = Date().timeIntervalSince(start)
            }
        }
    }

    private func endTimer() {
        timer?.invalidate()
        timer = nil
        startDate = nil
    }
}

/// The capture/writer pipeline. Every stored property below is confined to
/// `queue` (the session mutations, the writer, and the sample-buffer delegate all
/// run there) — no locks needed, no main-thread work.
private final class VideoNoteCapturePipeline: NSObject,
    AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {

    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.klic.videonote.capture")

    private var videoOutput: AVCaptureVideoDataOutput?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var sessionStarted = false
    private var firstSampleTime: CMTime = .invalid
    private var lastSampleTime: CMTime = .invalid
    private var outputURL: URL?
    private var finished = false

    static let side = 400
    static let videoBitrate = 1_000_000
    static let audioBitrate = 64_000

    static var hasCamera: Bool {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) != nil
            || AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) != nil
    }

    func start(withAudio: Bool) {
        queue.async { self.configureAndStart(withAudio: withAudio) }
    }

    func setCamera(front: Bool) {
        queue.async { self.swapCamera(front: front) }
    }

    func cancel() {
        queue.async {
            self.finished = true
            if self.session.isRunning { self.session.stopRunning() }
            let url = self.outputURL
            if self.writer?.status == .writing { self.writer?.cancelWriting() }
            self.cleanupWriter()
            if let url { try? FileManager.default.removeItem(at: url) }
        }
    }

    func finish(fallbackDuration: TimeInterval) async -> (url: URL, durationMs: Int)? {
        await withCheckedContinuation { continuation in
            queue.async {
                self.finished = true
                if self.session.isRunning { self.session.stopRunning() }
                guard let writer = self.writer, let url = self.outputURL,
                      self.sessionStarted, writer.status == .writing else {
                    self.cleanupWriter()
                    return continuation.resume(returning: nil)
                }
                self.videoInput?.markAsFinished()
                self.audioInput?.markAsFinished()
                if self.lastSampleTime.isValid { writer.endSession(atSourceTime: self.lastSampleTime) }
                let durationMs = self.recordedDurationMs(fallback: fallbackDuration)
                writer.finishWriting {
                    let ok = writer.status == .completed
                    self.queue.async { self.cleanupWriter() }
                    continuation.resume(returning: ok ? (url, durationMs) : nil)
                }
            }
        }
    }

    // MARK: Queue-confined internals

    private func configureAndStart(withAudio: Bool) {
        finished = false
        session.beginConfiguration()
        session.sessionPreset = .high
        for input in session.inputs { session.removeInput(input) }
        for output in session.outputs { session.removeOutput(output) }

        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
                ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let cameraInput = try? AVCaptureDeviceInput(device: camera),
              session.canAddInput(cameraInput) else {
            session.commitConfiguration()
            return
        }
        session.addInput(cameraInput)

        // 30 fps keeps the encode budget predictable at 1 Mbps.
        if let range = camera.activeFormat.videoSupportedFrameRateRanges.first, range.maxFrameRate >= 30 {
            try? camera.lockForConfiguration()
            camera.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
            camera.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
            camera.unlockForConfiguration()
        }

        var hasAudio = false
        if withAudio,
           let mic = AVCaptureDevice.default(for: .audio),
           let micInput = try? AVCaptureDeviceInput(device: mic),
           session.canAddInput(micInput) {
            session.addInput(micInput)
            hasAudio = true
        }

        let video = AVCaptureVideoDataOutput()
        video.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        video.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(video) else {
            session.commitConfiguration()
            return
        }
        session.addOutput(video)
        videoOutput = video
        orientVideoConnection(front: camera.position == .front)

        if hasAudio {
            let audio = AVCaptureAudioDataOutput()
            audio.setSampleBufferDelegate(self, queue: queue)
            if session.canAddOutput(audio) {
                session.addOutput(audio)
            } else {
                hasAudio = false
            }
        }

        session.commitConfiguration()
        setUpWriter(hasAudio: hasAudio)
        session.startRunning()
    }

    private func setUpWriter(hasAudio: Bool) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("videonote-\(UUID().uuidString).mp4")
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return }

        // Square H.264 output; appended buffers are aspect-FILLED (center-cropped)
        // into the 400×400 canvas by the writer's scaling mode.
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Self.side,
            AVVideoHeightKey: Self.side,
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspectFill,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Self.videoBitrate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: 30,
            ],
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else { return }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if hasAudio {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 1,
                AVSampleRateKey: 48_000,
                AVEncoderBitRateKey: Self.audioBitrate,
            ]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            }
        }

        guard writer.startWriting() else { return }
        self.writer = writer
        self.videoInput = videoInput
        self.audioInput = audioInput
        self.outputURL = url
        self.sessionStarted = false
        self.firstSampleTime = .invalid
        self.lastSampleTime = .invalid
    }

    private func swapCamera(front: Bool) {
        session.beginConfiguration()
        for input in session.inputs {
            if let deviceInput = input as? AVCaptureDeviceInput, deviceInput.device.hasMediaType(.video) {
                session.removeInput(deviceInput)
            }
        }
        let position: AVCaptureDevice.Position = front ? .front : .back
        if let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
           let input = try? AVCaptureDeviceInput(device: camera),
           session.canAddInput(input) {
            session.addInput(input)
        }
        session.commitConfiguration()
        orientVideoConnection(front: front)
    }

    /// Portrait-orient (and mirror, for the selfie camera) the video connection so
    /// the written frames match what the circular preview shows.
    private func orientVideoConnection(front: Bool) {
        guard let connection = videoOutput?.connection(with: .video) else { return }
        if connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = front
        }
    }

    private func cleanupWriter() {
        writer = nil
        videoInput = nil
        audioInput = nil
        outputURL = nil
        sessionStarted = false
        firstSampleTime = .invalid
        lastSampleTime = .invalid
    }

    private func recordedDurationMs(fallback: TimeInterval) -> Int {
        guard firstSampleTime.isValid, lastSampleTime.isValid else { return Int(fallback * 1000) }
        let seconds = CMTimeGetSeconds(CMTimeSubtract(lastSampleTime, firstSampleTime))
        return seconds > 0 ? Int(seconds * 1000) : Int(fallback * 1000)
    }

    // MARK: Sample delegate (called on `queue`)

    func captureOutput(
        _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection
    ) {
        guard !finished, let writer, writer.status == .writing else { return }
        let isVideo = output is AVCaptureVideoDataOutput
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        if !sessionStarted {
            // Start the writer session on the first VIDEO frame so the movie never
            // opens with black (an audio-first start would offset the video track).
            guard isVideo else { return }
            writer.startSession(atSourceTime: time)
            sessionStarted = true
            firstSampleTime = time
        }

        if isVideo {
            if videoInput?.isReadyForMoreMediaData == true {
                videoInput?.append(sampleBuffer)
                lastSampleTime = time
            }
        } else if audioInput?.isReadyForMoreMediaData == true {
            audioInput?.append(sampleBuffer)
        }
    }
}
