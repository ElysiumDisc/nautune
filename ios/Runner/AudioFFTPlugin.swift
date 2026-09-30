import Flutter
import AVFoundation
import Accelerate
import MediaToolbox
import os

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
    /// When `targetPosition` was reported: the main player has moved on
    /// since, so checkSync compares against the extrapolated position.
    private var targetSetAt: CFTimeInterval = 0

    // FFT setup
    private var fftSetup: FFTSetup?
    private let fftSize: Int = 2048
    private var log2n: vDSP_Length = 0

    // Singleton for callback access
    private static var sharedInstance: AudioFFTPlugin?

    // Pre-allocated buffers for FFT processing (avoids allocation every callback)
    private var samplesBuffer: [Float]
    private var filteredBuffer: [Float]
    private var processedBuffer: [Float]
    private var hanningWindow: [Float]
    private var realpBuffer: [Float]
    private var imagpBuffer: [Float]
    private var magnitudesBuffer: [Float]
    private var spectrumBuffer: [Float]

    /// Serialises processAudioBuffer: while a shadow player is being replaced
    /// the old and new taps can briefly render on different threads, and both
    /// would write the shared buffers. Try-locked, so the audio thread never
    /// blocks (a contended callback just skips a frame).
    private let processingLock: UnsafeMutablePointer<os_unfair_lock>

    // Throttling at native level (~30fps max)
    private var lastEmitTime: CFTimeInterval = 0
    private let minEmitInterval: CFTimeInterval = 0.033  // ~30fps

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
        // Pre-allocate all FFT buffers once (avoids 40KB+ allocation per callback)
        samplesBuffer = [Float](repeating: 0, count: fftSize)
        filteredBuffer = [Float](repeating: 0, count: fftSize)
        processedBuffer = [Float](repeating: 0, count: fftSize)
        hanningWindow = [Float](repeating: 0, count: fftSize)
        realpBuffer = [Float](repeating: 0, count: fftSize / 2)
        imagpBuffer = [Float](repeating: 0, count: fftSize / 2)
        magnitudesBuffer = [Float](repeating: 0, count: fftSize / 2)
        spectrumBuffer = [Float](repeating: 0, count: fftSize / 2)
        processingLock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        processingLock.initialize(to: os_unfair_lock())

        super.init()
        log2n = vDSP_Length(log2(Float(fftSize)))
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))

        // Pre-compute Hanning window (never changes)
        vDSP_hann_window(&hanningWindow, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
    }

    deinit {
        stopCapture()
        if let setup = fftSetup {
            vDSP_destroy_fftsetup(setup)
        }
        processingLock.deinitialize(count: 1)
        processingLock.deallocate()
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

        // Clean up old player (also clears currentUrl)
        cleanupPlayer()

        guard let url = AudioFFTPlugin.makeURL(urlString) else {
            print("🎵 AudioFFTPlugin: Invalid URL")
            return
        }
        // Only remember the URL once it could be built, so a retry isn't
        // swallowed by the same-URL check above.
        currentUrl = urlString

        print("🎵 AudioFFTPlugin: Setting up shadow player for \(url.lastPathComponent)")

        // Create player item
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        playerItem = item

        // Setup audio tap when tracks are loaded. The completion may arrive
        // after another setAudioUrl replaced the item; it must then do
        // nothing (attaching a second AVPlayer to the new item would throw).
        asset.loadValuesAsynchronously(forKeys: ["tracks"]) { [weak self, weak item] in
            DispatchQueue.main.async {
                guard let self = self, let item = item,
                      self.playerItem === item, self.shadowPlayer == nil else { return }
                var error: NSError?
                guard asset.statusOfValue(forKey: "tracks", error: &error) == .loaded else {
                    print("🎵 AudioFFTPlugin: Tracks failed to load")
                    return
                }
                self.setupAudioTap()
            }
        }
    }

    /// Builds a URL from either a `file://` string or a plain path (both are
    /// file URLs, built with `URL(fileURLWithPath:)` so paths containing
    /// spaces such as "Application Support" work on iOS 15/16), or any other
    /// URL string.
    private static func makeURL(_ string: String) -> URL? {
        var path: String?
        if string.hasPrefix("file://") {
            path = String(string.dropFirst("file://".count))
        } else if string.hasPrefix("/") {
            path = string
        }
        guard var filePath = path, !filePath.isEmpty else {
            return URL(string: string)
        }
        // Callers pass raw paths; only percent-decode when the raw path
        // doesn't exist but the decoded one does.
        if !FileManager.default.fileExists(atPath: filePath),
           let decoded = filePath.removingPercentEncoding,
           FileManager.default.fileExists(atPath: decoded) {
            filePath = decoded
        }
        return URL(fileURLWithPath: filePath)
    }

    private func setupAudioTap() {
        guard let item = playerItem, shadowPlayer == nil else { return }

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
        // Using 1.0 second interval instead of 0.5s for battery optimization
        // Sync accuracy is still acceptable for visualizer purposes
        if syncTimer == nil {
            syncTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
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
        // A new source must not be seeked to the previous one's position
        // (e.g. Frets on Fire after the player's visualizer).
        targetPosition = 0
    }

    private func syncPosition(_ position: Double) {
        targetPosition = position
        targetSetAt = CACurrentMediaTime()

        guard let player = shadowPlayer else { return }

        let currentTime = CMTimeGetSeconds(player.currentTime())
        let diff = abs(currentTime - position)

        // If more than 0.2 seconds out of sync, seek immediately
        if diff > 0.2 {
            let time = CMTime(seconds: position, preferredTimescale: 44100)  // Sample-accurate
            player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    private func checkSync() {
        guard let player = shadowPlayer else { return }

        // Ensure shadow player is playing if capture is active
        if isCapturing && player.rate == 0 {
            player.play()
        }

        // Verify sync with where the main player is now: the last reported
        // position plus the time since (Dart reports about once a second;
        // comparing with the stale value seeked back and forth every
        // second). A report older than a few seconds means the main player
        // isn't reporting (paused): don't chase it.
        let elapsed = CACurrentMediaTime() - targetSetAt
        if isCapturing && targetPosition > 0 && elapsed >= 0 && elapsed < 3 {
            let expected = targetPosition + elapsed
            let currentTime = CMTimeGetSeconds(player.currentTime())
            let diff = abs(currentTime - expected)
            if diff > 0.3 {
                let time = CMTime(seconds: expected, preferredTimescale: 44100)
                player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
            }
        }
    }

    // High-pass filter state (matches Linux)
    private var lastX: Float = 0
    private var lastY: Float = 0
    private var peakHistory: Float = 0.1

    // MARK: - FFT Processing (matched to Linux PulseAudio quality)

    fileprivate func processAudioBuffer(_ bufferList: UnsafeMutablePointer<AudioBufferList>, frames: CMItemCount) {
        guard let setup = fftSetup, isCapturing else { return }
        guard os_unfair_lock_trylock(processingLock) else { return }
        defer { os_unfair_lock_unlock(processingLock) }

        // Throttle at native level - skip if we emitted too recently (~30fps max)
        let now = CACurrentMediaTime()
        guard now - lastEmitTime >= minEmitInterval else { return }

        let buffer = bufferList.pointee.mBuffers
        guard let data = buffer.mData else { return }

        let floatData = data.assumingMemoryBound(to: Float.self)
        let frameCount = Int(frames)
        guard frameCount >= fftSize else { return }

        // Copy samples to pre-allocated buffer (no allocation)
        for i in 0..<fftSize {
            samplesBuffer[i] = floatData[i]
        }

        // === PREPROCESSING (matches Linux) ===

        // 1. DC offset removal
        var mean: Float = 0
        vDSP_meanv(samplesBuffer, 1, &mean, vDSP_Length(fftSize))

        // 2. High-pass filter + find peak (uses pre-allocated filteredBuffer)
        var localPeak: Float = 0.001

        for i in 0..<fftSize {
            let x = samplesBuffer[i] - mean
            let y = 0.98 * (lastY + x - lastX)
            lastX = x
            lastY = y
            filteredBuffer[i] = y
            localPeak = max(localPeak, abs(y))
        }

        // 3. Smooth peak for AGC
        peakHistory = peakHistory * 0.92 + localPeak * 0.08

        // 4. Noise gate + gain
        let noiseThreshold: Float = 0.008
        let maxGain: Float = 20.0

        var gain = 0.4 / max(0.001, peakHistory)
        gain = min(max(gain, 1.0), maxGain)

        if peakHistory < noiseThreshold {
            let gateFactor = pow(peakHistory / noiseThreshold, 2)
            gain *= gateFactor
        }

        // 5. Apply gain (uses pre-allocated processedBuffer)
        for i in 0..<fftSize {
            processedBuffer[i] = min(max(filteredBuffer[i] * gain, -1.0), 1.0)
        }

        // === FFT ===

        // Apply pre-computed Hanning window (no allocation)
        // In place through one mutable pointer: passing the array both as
        // input and `&inout` would copy it (copy-on-write) on the audio thread.
        let windowCount = vDSP_Length(fftSize)
        processedBuffer.withUnsafeMutableBufferPointer { processedPtr in
            guard let base = processedPtr.baseAddress else { return }
            vDSP_vmul(base, 1, self.hanningWindow, 1, base, 1, windowCount)
        }

        // Use pre-allocated buffers for FFT
        realpBuffer.withUnsafeMutableBufferPointer { realPtr in
            imagpBuffer.withUnsafeMutableBufferPointer { imagPtr in
                var splitComplex = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)

                processedBuffer.withUnsafeBufferPointer { samplesPtr in
                    samplesPtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) { complexPtr in
                        vDSP_ctoz(complexPtr, 2, &splitComplex, 1, vDSP_Length(fftSize / 2))
                    }
                }

                // Perform FFT
                vDSP_fft_zrip(setup, &splitComplex, 1, self.log2n, FFTDirection(FFT_FORWARD))

                // Calculate magnitudes (uses pre-allocated magnitudesBuffer)
                vDSP_zvmags(&splitComplex, 1, &self.magnitudesBuffer, 1, vDSP_Length(self.fftSize / 2))

                // Scale and sqrt for magnitude (uses pre-allocated spectrumBuffer)
                let spectrumSize = self.fftSize / 2
                for i in 0..<spectrumSize {
                    self.spectrumBuffer[i] = sqrt(self.magnitudesBuffer[i]) / Float(spectrumSize)
                }

                // === FREQUENCY BANDS (matched to Linux: 4%, 20%) ===
                let bassEnd = Int(Float(spectrumSize) * 0.04)   // 0-4% (~0-180Hz)
                let midEnd = Int(Float(spectrumSize) * 0.20)    // 4-20% (~180-2000Hz)

                // RMS averaging (matches Linux)
                let bass = self.rmsAverage(self.spectrumBuffer, start: 0, end: max(1, bassEnd)) * 22.0
                let mid = self.rmsAverage(self.spectrumBuffer, start: bassEnd, end: midEnd) * 30.0
                let treble = self.rmsAverage(self.spectrumBuffer, start: midEnd, end: spectrumSize) * 55.0

                // RMS amplitude
                var rms: Float = 0
                vDSP_rmsqv(self.processedBuffer, 1, &rms, vDSP_Length(self.fftSize))
                let amplitude = min(rms * 1.5, 1.0)

                // Mark emit time and send to Flutter
                self.lastEmitTime = now
                self.sendFFTData(
                    bass: min(bass, 1.0),
                    mid: min(mid, 1.0),
                    treble: min(treble, 1.0),
                    amplitude: amplitude
                )
            }
        }
    }

    // RMS averaging (matches Linux implementation)
    private func rmsAverage(_ data: [Float], start: Int, end: Int) -> Float {
        guard end > start && !data.isEmpty else { return 0 }
        let safeStart = max(0, min(start, data.count))
        let safeEnd = max(safeStart, min(end, data.count))
        guard safeEnd > safeStart else { return 0 }

        // RMS = sqrt(sum of squares / count)
        var sumSquares: Float = 0
        for i in safeStart..<safeEnd {
            sumSquares += data[i] * data[i]
        }
        return sqrt(sumSquares / Float(safeEnd - safeStart))
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
