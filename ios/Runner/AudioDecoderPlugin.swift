import Flutter
import AVFoundation
import Accelerate

/// Native iOS audio decoder plugin.
/// Decodes audio files to raw PCM samples for chart generation.
public class AudioDecoderPlugin: NSObject, FlutterPlugin {

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "com.elysiumdisc.nautune/audio_decoder",
            binaryMessenger: registrar.messenger()
        )
        let instance = AudioDecoderPlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
        print("🎵 AudioDecoderPlugin: Registered")
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "decodeAudio":
            guard let args = call.arguments as? [String: Any],
                  let path = args["path"] as? String,
                  let targetSampleRate = args["sampleRate"] as? Int else {
                result(FlutterError(code: "INVALID_ARGS", message: "Missing path or sampleRate", details: nil))
                return
            }
            // Optional cap on the real decoded length (metadata can be missing).
            let maxDurationSeconds = args["maxDurationSeconds"] as? Int
            decodeAudio(path: path, targetSampleRate: targetSampleRate,
                        maxDurationSeconds: maxDurationSeconds, result: result)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    /// Decode an audio file to mono Float32 PCM samples
    private func decodeAudio(path: String, targetSampleRate: Int, maxDurationSeconds: Int?,
                             result: @escaping FlutterResult) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let url = URL(fileURLWithPath: path)
                let audioFile = try AVAudioFile(forReading: url)

                let format = audioFile.processingFormat

                // Refuse over-long files before allocating the output buffer
                if let maxSeconds = maxDurationSeconds, format.sampleRate > 0,
                   Double(audioFile.length) / format.sampleRate > Double(maxSeconds) {
                    DispatchQueue.main.async {
                        result(FlutterError(code: "TOO_LONG", message: "Track exceeds \(maxSeconds) seconds", details: nil))
                    }
                    return
                }
                guard audioFile.length > 0, audioFile.length <= AVAudioFramePosition(UInt32.max) else {
                    DispatchQueue.main.async {
                        result(FlutterError(code: "BUFFER_ERROR", message: "Unsupported audio length", details: nil))
                    }
                    return
                }
                let channelCount = Int(format.channelCount)
                let totalFrames = Int(audioFile.length)
                let sourceSampleRate = format.sampleRate
                guard sourceSampleRate > 0, targetSampleRate > 0 else {
                    DispatchQueue.main.async {
                        result(FlutterError(code: "BUFFER_ERROR", message: "Invalid sample rate", details: nil))
                    }
                    return
                }
                // Output sample i sits at source frame i / ratio (linear resampling).
                let ratio = Double(targetSampleRate) / sourceSampleRate
                let outputCapacity = Int(Double(totalFrames) * ratio)

                // Read in fixed-size chunks: only one small PCM buffer plus the
                // mono output exist at once, never the whole multi-channel file.
                let chunkFrames: AVAudioFrameCount = 65536
                guard channelCount > 0, outputCapacity > 0,
                      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
                    DispatchQueue.main.async {
                        result(FlutterError(code: "BUFFER_ERROR", message: "Failed to create audio buffer", details: nil))
                    }
                    return
                }

                print("🎵 AudioDecoder: Decoding \(totalFrames) frames, \(channelCount) channels, \(sourceSampleRate) Hz")

                // Mono float32 output, written in place (sent as-is below).
                var data = Data(count: outputCapacity * MemoryLayout<Float>.size)
                var written = 0
                var missingChannelData = false

                try data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) throws -> Void in
                    let output = raw.bindMemory(to: Float.self)
                    var chunkStart = 0        // absolute frame index of the chunk's first frame
                    var previousMono: Float = 0 // mono value of the frame before the chunk

                    while written < outputCapacity && audioFile.framePosition < audioFile.length {
                        try audioFile.read(into: buffer, frameCount: chunkFrames)
                        let frames = Int(buffer.frameLength)
                        if frames == 0 { break }
                        guard let channels = buffer.floatChannelData else {
                            missingChannelData = true
                            return
                        }
                        let chunkEnd = chunkStart + frames
                        let isLastChunk = audioFile.framePosition >= audioFile.length

                        // Mono value of an absolute frame in this chunk (or the one just before it).
                        func mono(_ frame: Int) -> Float {
                            if frame < chunkStart { return previousMono }
                            let j = frame - chunkStart
                            if channelCount == 1 { return channels[0][j] }
                            var sum: Float = 0
                            for ch in 0..<channelCount {
                                sum += channels[ch][j]
                            }
                            return sum / Float(channelCount)
                        }

                        while written < outputCapacity {
                            let sourcePosition = Double(written) / ratio
                            let s0 = Int(sourcePosition)
                            if s0 >= chunkEnd { break }
                            let s1 = s0 + 1
                            // The next frame is in the next chunk: read it first.
                            if s1 >= chunkEnd && !isLastChunk { break }
                            let frac = Float(sourcePosition - Double(s0))
                            let a = mono(s0)
                            let b = s1 < chunkEnd ? mono(s1) : a
                            output[written] = a * (1 - frac) + b * frac
                            written += 1
                        }

                        previousMono = mono(chunkEnd - 1)
                        chunkStart = chunkEnd
                    }
                }

                if missingChannelData {
                    DispatchQueue.main.async {
                        result(FlutterError(code: "DATA_ERROR", message: "No float channel data", details: nil))
                    }
                    return
                }
                if written < outputCapacity {
                    data.count = written * MemoryLayout<Float>.size
                }

                print("🎵 AudioDecoder: Decoded \(written) samples at \(targetSampleRate) Hz")

                // Send as a typed float32 buffer (arrives in Dart as Float32List,
                // 4 bytes per sample, no per-element boxing)
                let samples = data
                DispatchQueue.main.async {
                    result(["samples": FlutterStandardTypedData(float32: samples)])
                }

            } catch {
                DispatchQueue.main.async {
                    result(FlutterError(code: "DECODE_ERROR", message: error.localizedDescription, details: nil))
                }
            }
        }
    }
}
