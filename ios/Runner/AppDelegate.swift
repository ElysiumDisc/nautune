import UIKit
import Flutter

let flutterEngine = FlutterEngine(name: "SharedEngine", project: nil, allowHeadlessExecution: true)

@main
@objc class AppDelegate: FlutterAppDelegate {
  private var fileAttributesChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    flutterEngine.run()
    GeneratedPluginRegistrant.register(with: flutterEngine)

    // Register Audio FFT plugin for real-time visualization
    AudioFFTPlugin.register(with: flutterEngine.registrar(forPlugin: "AudioFFTPlugin")!)

    // Register Audio Decoder plugin for chart generation
    AudioDecoderPlugin.register(with: flutterEngine.registrar(forPlugin: "AudioDecoderPlugin")!)

    // Register Share plugin for native file sharing (AirDrop, etc.)
    SharePlugin.register(with: flutterEngine.registrar(forPlugin: "SharePlugin")!)

    // Register App Icon plugin for alternate icon support
    AppIconPlugin.register(with: flutterEngine.registrar(forPlugin: "AppIconPlugin")!)

    // File attributes channel: lets Dart exclude the offline downloads
    // directory from iCloud/iTunes backup (App Review 2.23).
    registerFileAttributesChannel(messenger: flutterEngine.binaryMessenger)

    // Background-time for saving playback state is requested in
    // SceneDelegate.sceneDidEnterBackground (scene-based lifecycle).
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  /// Channel "nautune/file_attributes"
  ///   excludeFromBackup({path: String}) -> Bool
  /// Sets URLResourceValues.isExcludedFromBackup = true on the file or
  /// directory at `path` (a directory's contents are excluded with it).
  private func registerFileAttributesChannel(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "nautune/file_attributes", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "excludeFromBackup":
        guard let args = call.arguments as? [String: Any],
              let path = args["path"] as? String, !path.isEmpty else {
          result(FlutterError(code: "INVALID_ARGS", message: "path required", details: nil))
          return
        }
        var url = URL(fileURLWithPath: path)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        do {
          try url.setResourceValues(values)
          result(true)
        } catch {
          result(FlutterError(code: "SET_FAILED", message: error.localizedDescription, details: path))
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    fileAttributesChannel = channel
  }
}
