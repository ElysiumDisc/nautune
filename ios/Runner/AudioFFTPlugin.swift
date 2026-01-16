import Flutter
import AVFoundation
import Accelerate
import MediaToolbox

/// Native iOS FFT plugin using MTAudioProcessingTap.
/// Creates a shadow AVPlayer with audio tap to capture real FFT data.
public class AudioFFTPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {

    private var eventSink: FlutterEventSink?
    private var shadowPlayer: AVPlayer?
    private var playerItem: AVPlayerItem?
    private var isCapturing = false
    private var currentUrl: String?

    // Sync with main player
    private var syncTimer: Timer?
    private var targetPosition: Double = 0

    // FFT setup
    private var fftSetup: FFTSetup?
    private let fftSize: Int = 2048
    private var log2n: vDSP_Length = 0

    // Singleton for callback access
    private static var sharedInstance: AudioFFTPlugin?

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = AudioFFTPlugin()
        sharedInstance = instance

        // Method channel for commands
        let methodChannel = FlutterMethodChannel(
            name: "com.nautune.audio_fft/methods",
            binaryMessenger: registrar.messenger()
        )
        registrar.addMethodCallDelegate(instance, channel: methodChannel)

        // Event channel for streaming FFT data
        let eventChannel = FlutterEventChannel(
            name: "com.nautune.audio_fft/events",
            binaryMessenger: registrar.messenger()
        )
        eventChannel.setStreamHandler(instance)

        print("🎵 AudioFFTPlugin: Registered with MTAudioProcessingTap")
    }

    override init() {
        super.init()
        log2n = vDSP_Length(log2(Float(fftSize)))
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
    }

    deinit {
        stopCapture()
        if let setup = fftSetup {
            vDSP_destroy_fftsetup(setup)
        }
    }

    // MARK: - FlutterPlugin

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "setAudioUrl":
            if let args = call.arguments as? [String: Any],
               let url = args["url"] as? String {
                setAudioUrl(url)
                result(true)
            } else {
                result(FlutterError(code: "INVALID_ARGS", message: "URL required", details: nil))
            }
        case "startCapture":
            startCapture()
            result(true)
        case "stopCapture":
            stopCapture()
            result(true)
        case "syncPosition":
            if let args = call.arguments as? [String: Any],
               let position = args["position"] as? Double {
                syncPosition(position)
                result(true)
            } else {
                result(true)
            }
        case "isAvailable":
            result(true)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - FlutterStreamHandler

    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.eventSink = events
        print("🎵 AudioFFTPlugin: Event sink connected")
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        self.eventSink = nil
        print("🎵 AudioFFTPlugin: Event sink disconnected")
        return nil
    }

    // MARK: - Audio Setup

    private func setAudioUrl(_ urlString: String) {
        guard urlString != currentUrl else { return }
        currentUrl = urlString

        // Clean up old player
        cleanupPlayer()

        guard let url = URL(string: urlString) else {
            print("🎵 AudioFFTPlugin: Invalid URL")
            return
        }

        print("🎵 AudioFFTPlugin: Setting up shadow player for \(url.lastPathComponent)")

        // Create player item
        let asset = AVURLAsset(url: url)
        playerItem = AVPlayerItem(asset: asset)

        // Setup audio tap when tracks are loaded
        asset.loadValuesAsynchronously(forKeys: ["tracks"]) { [weak self] in
            DispatchQueue.main.async {
                self?.setupAudioTap()
            }
        }
    }

    private func setupAudioTap() {
        guard let item = playerItem else { return }

        // Get audio track
        guard let audioTrack = item.asset.tracks(withMediaType: .audio).first else {
            print("🎵 AudioFFTPlugin: No audio track found")
            return
        }

        // Create tap callbacks
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: UnsafeMutableRawPointer(mutating: Unmanaged.passUnretained(self).toOpaque()),
            init: { (tap, clientInfo, tapStorageOut) in
                tapStorageOut.pointee = clientInfo
            },
            finalize: { (tap) in
                // Cleanup if needed
            },
            prepare: { (tap, maxFrames, processingFormat) in
                print("🎵 AudioFFTPlugin: Tap prepared")
            },
            unprepare: { (tap) in
                // Cleanup if needed
            },
            process: { (tap, numberFrames, flags, bufferListInOut, numberFramesOut, flagsOut) in
                // Get source audio
                let status = MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListInOut, flagsOut, nil, numberFramesOut)
                guard status == noErr else { return }

                // Get plugin instance and process
                let storage = MTAudioProcessingTapGetStorage(tap)
                let plugin = Unmanaged<AudioFFTPlugin>.fromOpaque(storage).takeUnretainedValue()
                plugin.processAudioBuffer(bufferListInOut, frames: numberFramesOut.pointee)
            }
        )

        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(
            kCFAllocatorDefault,
            &callbacks,
            kMTAudioProcessingTapCreationFlag_PreEffects,
            &tap
        )

        guard status == noErr, let audioTap = tap else {
            print("🎵 AudioFFTPlugin: Failed to create tap, status: \(status)")
            return
        }

        // Create audio mix with tap
        let inputParams = AVMutableAudioMixInputParameters(track: audioTrack)
        inputParams.audioTapProcessor = audioTap

        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = [inputParams]
        item.audioMix = audioMix

        // Create shadow player (muted)
        shadowPlayer = AVPlayer(playerItem: item)
        shadowPlayer?.volume = 0  // Silent - we only want FFT data
        shadowPlayer?.isMuted = true

        print("🎵 AudioFFTPlugin: Shadow player ready with audio tap")

        // If capture was already requested, start now
        if isCapturing {
            shadowPlayer?.play()
            startSyncTimer()
            print("🎵 AudioFFTPlugin: Auto-started capture after setup")
        }
    }

    // MARK: - Capture Control

    private func startCapture() {
        // Mark that capture is requested
        isCapturing = true

        // Only start if shadow player is ready
        guard let player = shadowPlayer else {
            print("🎵 AudioFFTPlugin: Capture requested (waiting for audio URL)")
            return
        }

        // Start shadow player if not already playing
        if player.rate == 0 {
            player.play()
        }

        startSyncTimer()
        print("🎵 AudioFFTPlugin: Capture started")
    }

    private func startSyncTimer() {
        // Start position sync timer if not already running
        if syncTimer == nil {
            syncTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                self?.checkSync()
            }
        }
    }

    private func stopCapture() {
        isCapturing = false

        syncTimer?.invalidate()
        syncTimer = nil

        shadowPlayer?.pause()

        sendFFTData(bass: 0, mid: 0, treble: 0, amplitude: 0)
        print("🎵 AudioFFTPlugin: Capture stopped")
    }

    private func cleanupPlayer() {
        stopCapture()
        shadowPlayer = nil
        playerItem = nil
        currentUrl = nil
    }

    private func syncPosition(_ position: Double) {
        targetPosition = position

        guard let player = shadowPlayer else { return }

        let currentTime = CMTimeGetSeconds(player.currentTime())
        let diff = abs(currentTime - position)

        // If more than 0.5 seconds out of sync, seek
        if diff > 0.5 {
            let time = CMTime(seconds: position, preferredTimescale: 1000)
            player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    private func checkSync() {
        // Ensure shadow player is playing if capture is active
        if isCapturing && shadowPlayer?.rate == 0 {
            shadowPlayer?.play()
        }
    }

    // MARK: - FFT Processing

    fileprivate func processAudioBuffer(_ bufferList: UnsafeMutablePointer<AudioBufferList>, frames: CMItemCount) {
        guard let setup = fftSetup, isCapturing else { return }

        let buffer = bufferList.pointee.mBuffers
        guard let data = buffer.mData else { return }

        let floatData = data.assumingMemoryBound(to: Float.self)
        let frameCount = Int(frames)
        guard frameCount >= fftSize else { return }

        // Get samples
        var samples = [Float](repeating: 0, count: fftSize)
        for i in 0..<fftSize {
            samples[i] = floatData[i]
        }

        // Apply Hanning window
        var window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        vDSP_vmul(samples, 1, window, 1, &samples, 1, vDSP_Length(fftSize))

        // Prepare for FFT
        var realp = [Float](repeating: 0, count: fftSize / 2)
        var imagp = [Float](repeating: 0, count: fftSize / 2)

        realp.withUnsafeMutableBufferPointer { realPtr in
            imagp.withUnsafeMutableBufferPointer { imagPtr in
                var splitComplex = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)

                samples.withUnsafeBufferPointer { samplesPtr in
                    samplesPtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) { complexPtr in
                        vDSP_ctoz(complexPtr, 2, &splitComplex, 1, vDSP_Length(fftSize / 2))
                    }
                }

                // Perform FFT
                vDSP_fft_zrip(setup, &splitComplex, 1, self.log2n, FFTDirection(FFT_FORWARD))

                // Calculate magnitudes
                var magnitudes = [Float](repeating: 0, count: fftSize / 2)
                vDSP_zvmags(&splitComplex, 1, &magnitudes, 1, vDSP_Length(fftSize / 2))

                // Scale
                var scaledMagnitudes = [Float](repeating: 0, count: fftSize / 2)
                var scale = Float(1.0 / Float(fftSize))
                vDSP_vsmul(magnitudes, 1, &scale, &scaledMagnitudes, 1, vDSP_Length(fftSize / 2))

                // Extract frequency bands (assuming 44.1kHz sample rate)
                // Bass: 20-180Hz, Mid: 180-2000Hz, Treble: 2000-20000Hz
                let spectrumSize = fftSize / 2
                let bassEnd = Int(Float(spectrumSize) * 0.008)     // ~180Hz
                let midEnd = Int(Float(spectrumSize) * 0.09)       // ~2000Hz

                let bass = self.averageBand(scaledMagnitudes, start: 1, end: max(2, bassEnd)) * 30.0
                let mid = self.averageBand(scaledMagnitudes, start: bassEnd, end: midEnd) * 40.0
                let treble = self.averageBand(scaledMagnitudes, start: midEnd, end: spectrumSize) * 80.0

                // RMS amplitude
                var rms: Float = 0
                vDSP_rmsqv(samples, 1, &rms, vDSP_Length(self.fftSize))
                let amplitude = min(rms * 3.0, 1.0)

                // Send to Flutter
                self.sendFFTData(
                    bass: min(bass, 1.0),
                    mid: min(mid, 1.0),
                    treble: min(treble, 1.0),
                    amplitude: amplitude
                )
            }
        }
    }

    private func averageBand(_ data: [Float], start: Int, end: Int) -> Float {
        guard end > start && !data.isEmpty else { return 0 }
        let safeStart = max(0, min(start, data.count))
        let safeEnd = max(safeStart, min(end, data.count))
        guard safeEnd > safeStart else { return 0 }

        var sum: Float = 0
        for i in safeStart..<safeEnd {
            sum += sqrt(data[i])
        }
        return sum / Float(safeEnd - safeStart)
    }

    private func sendFFTData(bass: Float, mid: Float, treble: Float, amplitude: Float) {
        DispatchQueue.main.async { [weak self] in
            self?.eventSink?([
                "bass": Double(bass),
                "mid": Double(mid),
                "treble": Double(treble),
                "amplitude": Double(amplitude)
            ])
        }
    }
}
