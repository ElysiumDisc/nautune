import Flutter
import AVFoundation
import Accelerate
import MediaToolbox
import ObjectiveC

/// 10-band equalizer for music playback.
///
/// just_audio plays music through an AVQueuePlayer that other plugins can't
/// reach, so this plugin swizzles `-[AVQueuePlayer insertItem:afterItem:]`
/// and attaches an MTAudioProcessingTap to every item queued on any
/// AVQueuePlayer. Only just_audio uses AVQueuePlayer in Nautune; the
/// visualizer's shadow player and audioplayers (easter eggs) use plain
/// AVPlayer and are never touched.
///
/// Channel "com.nautune.audio_effects":
///   setEqualizer({enabled: Bool, preampDb: Double, gains: [Double] x10})
public class AudioEffectsPlugin: NSObject, FlutterPlugin {

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = AudioEffectsPlugin()
        let channel = FlutterMethodChannel(
            name: "com.nautune.audio_effects",
            binaryMessenger: registrar.messenger()
        )
        registrar.addMethodCallDelegate(instance, channel: channel)
        AVQueuePlayer.nautuneInstallEqualizerHook()
        print("🎚️ AudioEffectsPlugin: registered")
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "setEqualizer":
            guard let args = call.arguments as? [String: Any] else {
                result(FlutterError(code: "bad_args", message: nil, details: nil))
                return
            }
            let enabled = args["enabled"] as? Bool ?? false
            let preamp = Float(args["preampDb"] as? Double ?? 0)
            let gains = (args["gains"] as? [Double] ?? []).map { Float($0) }
            EqualizerSettings.shared.update(enabled: enabled, preampDb: preamp, gains: gains)
            result(true)
        default:
            result(FlutterMethodNotImplemented)
        }
    }
}

// MARK: - Settings shared with the audio thread

final class EqualizerSettings {
    static let shared = EqualizerSettings()
    static let frequencies: [Double] = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    static let q: Double = 1.1

    private let lock = NSLock()
    private var _enabled = false
    private var _preampDb: Float = 0
    private var _gains = [Float](repeating: 0, count: 10)
    private var _version = 0

    func update(enabled: Bool, preampDb: Float, gains: [Float]) {
        lock.lock()
        _enabled = enabled
        _preampDb = max(-24, min(0, preampDb))
        var g = [Float](repeating: 0, count: 10)
        for i in 0..<min(10, gains.count) { g[i] = max(-12, min(12, gains[i])) }
        _gains = g
        _version += 1
        lock.unlock()
    }

    /// Current settings; `version` changes whenever they do.
    func snapshot() -> (enabled: Bool, preampDb: Float, gains: [Float], version: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (_enabled, _preampDb, _gains, _version)
    }

    /// Peaking-EQ biquad (RBJ cookbook), normalised: [b0, b1, b2, a1, a2].
    static func peakingCoefficients(frequency: Double, gainDb: Double, sampleRate: Double) -> [Double] {
        if gainDb == 0 || frequency >= sampleRate * 0.45 {
            return [1, 0, 0, 0, 0]
        }
        let a = pow(10, gainDb / 40)
        let w0 = 2 * Double.pi * frequency / sampleRate
        let alpha = sin(w0) / (2 * q)
        let cosw = cos(w0)
        let a0 = 1 + alpha / a
        return [
            (1 + alpha * a) / a0,
            (-2 * cosw) / a0,
            (1 - alpha * a) / a0,
            (-2 * cosw) / a0,
            (1 - alpha / a) / a0,
        ]
    }
}

// MARK: - Per-item tap state

final class EqualizerTapContext {
    var sampleRate: Double = 44100
    var channels: Int = 2
    var interleaved = false
    var setup: vDSP_biquadm_Setup?
    var version = -1
    var active = false
    var preampLinear: Float = 1

    // Channel pointer arrays for vDSP_biquadm, allocated in prepare so the
    // audio callback never allocates.
    private var inputs: UnsafeMutablePointer<UnsafePointer<Float>>?
    private var outputs: UnsafeMutablePointer<UnsafeMutablePointer<Float>>?

    func prepare(format: AudioStreamBasicDescription) {
        sampleRate = format.mSampleRate > 0 ? format.mSampleRate : 44100
        channels = max(1, Int(format.mChannelsPerFrame))
        interleaved = (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0
        destroySetup()
        freePointers()
        inputs = .allocate(capacity: channels)
        outputs = .allocate(capacity: channels)
        version = -1
    }

    private func freePointers() {
        inputs?.deallocate()
        outputs?.deallocate()
        inputs = nil
        outputs = nil
    }

    /// Rebuild filter coefficients when the settings changed.
    func refresh() {
        let s = EqualizerSettings.shared.snapshot()
        guard s.version != version else { return }
        version = s.version
        active = s.enabled && (s.preampDb != 0 || s.gains.contains { $0 != 0 })
        preampLinear = powf(10, s.preampDb / 20)
        guard active else { return }

        let sections = EqualizerSettings.frequencies.count
        var coefficients = [Double]()
        coefficients.reserveCapacity(sections * channels * 5)
        for (i, f) in EqualizerSettings.frequencies.enumerated() {
            let c = EqualizerSettings.peakingCoefficients(
                frequency: f, gainDb: Double(s.gains[i]), sampleRate: sampleRate)
            for _ in 0..<channels { coefficients.append(contentsOf: c) }
        }
        if let existing = setup {
            vDSP_biquadm_SetCoefficientsDouble(
                existing, coefficients, 0, 0,
                vDSP_Length(sections), vDSP_Length(channels))
        } else {
            setup = vDSP_biquadm_CreateSetup(
                coefficients, vDSP_Length(sections), vDSP_Length(channels))
        }
    }

    func process(_ bufferList: UnsafeMutablePointer<AudioBufferList>, frames: Int) {
        refresh()
        guard active, frames > 0, let setup = setup,
              let inputs = inputs, let outputs = outputs else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)

        var stride = 1
        if interleaved {
            guard let data = buffers.first?.mData?.assumingMemoryBound(to: Float.self) else { return }
            stride = channels
            for c in 0..<channels { outputs[c] = data + c }
        } else {
            guard buffers.count == channels else { return }
            for c in 0..<channels {
                guard let data = buffers[c].mData?.assumingMemoryBound(to: Float.self) else { return }
                outputs[c] = data
            }
        }
        for c in 0..<channels { inputs[c] = UnsafePointer(outputs[c]) }

        // Preamp (always <= 0 dB) keeps boosted bands from clipping.
        if preampLinear != 1 {
            var gain = preampLinear
            for c in 0..<channels {
                vDSP_vsmul(outputs[c], stride, &gain, outputs[c], stride, vDSP_Length(frames))
            }
        }

        // In place: input and output are the same channel buffers.
        vDSP_biquadm(setup, inputs, vDSP_Stride(stride),
                     outputs, vDSP_Stride(stride), vDSP_Length(frames))
    }

    func destroySetup() {
        if let s = setup { vDSP_biquadm_DestroySetup(s) }
        setup = nil
    }

    deinit {
        destroySetup()
        freePointers()
    }
}

// MARK: - Attaching taps to queued items

enum EqualizerTap {
    static func attach(to item: AVPlayerItem) {
        if objc_getAssociatedObject(item, &attachedKey) != nil { return }
        objc_setAssociatedObject(item, &attachedKey, true, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        let asset = item.asset
        asset.loadValuesAsynchronously(forKeys: ["tracks"]) {
            var error: NSError?
            guard asset.statusOfValue(forKey: "tracks", error: &error) == .loaded,
                  let track = asset.tracks(withMediaType: .audio).first else { return }
            DispatchQueue.main.async { install(on: item, track: track) }
        }
    }

    private static var attachedKey: UInt8 = 0

    private static func install(on item: AVPlayerItem, track: AVAssetTrack) {
        let context = EqualizerTapContext()
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: UnsafeMutableRawPointer(Unmanaged.passRetained(context).toOpaque()),
            init: { _, clientInfo, tapStorageOut in
                tapStorageOut.pointee = clientInfo
            },
            finalize: { tap in
                // Balance passRetained above.
                Unmanaged<EqualizerTapContext>
                    .fromOpaque(MTAudioProcessingTapGetStorage(tap))
                    .release()
            },
            prepare: { tap, _, format in
                Unmanaged<EqualizerTapContext>
                    .fromOpaque(MTAudioProcessingTapGetStorage(tap))
                    .takeUnretainedValue()
                    .prepare(format: format.pointee)
            },
            unprepare: { tap in
                Unmanaged<EqualizerTapContext>
                    .fromOpaque(MTAudioProcessingTapGetStorage(tap))
                    .takeUnretainedValue()
                    .destroySetup()
            },
            process: { tap, numberFrames, _, bufferListInOut, numberFramesOut, flagsOut in
                let status = MTAudioProcessingTapGetSourceAudio(
                    tap, numberFrames, bufferListInOut, flagsOut, nil, numberFramesOut)
                guard status == noErr else { return }
                Unmanaged<EqualizerTapContext>
                    .fromOpaque(MTAudioProcessingTapGetStorage(tap))
                    .takeUnretainedValue()
                    .process(bufferListInOut, frames: Int(numberFramesOut.pointee))
            }
        )
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(
            kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PreEffects, &tap)
        guard status == noErr, let audioTap = tap else {
            // The tap never took ownership of the context.
            Unmanaged.passUnretained(context).release()
            print("🎚️ AudioEffectsPlugin: tap creation failed (\(status))")
            return
        }
        let parameters = AVMutableAudioMixInputParameters(track: track)
        parameters.audioTapProcessor = audioTap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        item.audioMix = mix
    }
}

extension AVQueuePlayer {
    private static var hookInstalled = false

    /// Route every item queued on an AVQueuePlayer through the equalizer.
    static func nautuneInstallEqualizerHook() {
        guard !hookInstalled else { return }
        hookInstalled = true
        let original = #selector(AVQueuePlayer.insert(_:after:))
        let replacement = #selector(AVQueuePlayer.nautune_insert(_:after:))
        guard let originalMethod = class_getInstanceMethod(AVQueuePlayer.self, original),
              let replacementMethod = class_getInstanceMethod(AVQueuePlayer.self, replacement)
        else { return }
        method_exchangeImplementations(originalMethod, replacementMethod)
    }

    @objc dynamic func nautune_insert(_ item: AVPlayerItem, after afterItem: AVPlayerItem?) {
        EqualizerTap.attach(to: item)
        // Implementations are exchanged: this calls the original insert.
        nautune_insert(item, after: afterItem)
    }
}
