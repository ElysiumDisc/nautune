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

                // Refuse over-long files before allocating the PCM buffer
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
                let frameCount = AVAudioFrameCount(audioFile.length)

                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
                    DispatchQueue.main.async {
                        result(FlutterError(code: "BUFFER_ERROR", message: "Failed to create audio buffer", details: nil))
                    }
                    return
                }

                try audioFile.read(into: buffer)

                guard let floatChannelData = buffer.floatChannelData else {
                    DispatchQueue.main.async {
                        result(FlutterError(code: "DATA_ERROR", message: "No float channel data", details: nil))
                    }
                    return
                }

                let channelCount = Int(format.channelCount)
                let sampleCount = Int(buffer.frameLength)

                print("🎵 AudioDecoder: Read \(sampleCount) frames, \(channelCount) channels, \(format.sampleRate) Hz")

                // Mix to mono
                var monoSamples = [Float](repeating: 0, count: sampleCount)

                if channelCount == 1 {
                    // Already mono
                    for i in 0..<sampleCount {
                        monoSamples[i] = floatChannelData[0][i]
                    }
                } else {
                    // Mix channels to mono
                    for i in 0..<sampleCount {
                        var sum: Float = 0
                        for ch in 0..<channelCount {
                            sum += floatChannelData[ch][i]
                        }
                        monoSamples[i] = sum / Float(channelCount)
                    }
                }

                // Resample if needed
                let sourceSampleRate = Int(format.sampleRate)
                let outputSamples: [Float]

                if sourceSampleRate != targetSampleRate {
                    outputSamples = self.resample(monoSamples, from: sourceSampleRate, to: targetSampleRate)
                    print("🎵 AudioDecoder: Resampled from \(sourceSampleRate) to \(targetSampleRate) Hz (\(outputSamples.count) samples)")
                } else {
                    outputSamples = monoSamples
                }

                // Send as a typed float32 buffer (arrives in Dart as Float32List,
                // 4 bytes per sample, no per-element boxing)
                let data = outputSamples.withUnsafeBufferPointer { Data(buffer: $0) }

                DispatchQueue.main.async {
                    result(["samples": FlutterStandardTypedData(float32: data)])
                }

            } catch {
                DispatchQueue.main.async {
                    result(FlutterError(code: "DECODE_ERROR", message: error.localizedDescription, details: nil))
                }
            }
        }
    }

    /// Simple linear resampling
    private func resample(_ samples: [Float], from sourceSampleRate: Int, to targetSampleRate: Int) -> [Float] {
        let ratio = Double(targetSampleRate) / Double(sourceSampleRate)
        let outputCount = Int(Double(samples.count) * ratio)
        var output = [Float](repeating: 0, count: outputCount)

        for i in 0..<outputCount {
            let srcIndex = Double(i) / ratio
            let srcIndexInt = Int(srcIndex)
            let frac = Float(srcIndex - Double(srcIndexInt))

            if srcIndexInt + 1 < samples.count {
                // Linear interpolation
                output[i] = samples[srcIndexInt] * (1 - frac) + samples[srcIndexInt + 1] * frac
            } else if srcIndexInt < samples.count {
                output[i] = samples[srcIndexInt]
            }
        }

        return output
    }
}
