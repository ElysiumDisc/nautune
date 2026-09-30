import UIKit
import Flutter
import CarPlay
import MediaPlayer

let flutterEngine = FlutterEngine(name: "SharedEngine", project: nil, allowHeadlessExecution: true)

@main
@objc class AppDelegate: FlutterAppDelegate {
  private var fileAttributesChannel: FlutterMethodChannel?
  private var nowPlayingModesChannel: FlutterMethodChannel?
  private var carPlayNavigationChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    flutterEngine.run()
    GeneratedPluginRegistrant.register(with: flutterEngine)

    // Register Audio FFT plugin for real-time visualization
    AudioFFTPlugin.register(with: flutterEngine.registrar(forPlugin: "AudioFFTPlugin")!)

    // Register the equalizer (taps just_audio's AVQueuePlayer items)
    AudioEffectsPlugin.register(with: flutterEngine.registrar(forPlugin: "AudioEffectsPlugin")!)

    // Register Audio Decoder plugin for chart generation
    AudioDecoderPlugin.register(with: flutterEngine.registrar(forPlugin: "AudioDecoderPlugin")!)

    // Register Share plugin for native file sharing (AirDrop, etc.)
    SharePlugin.register(with: flutterEngine.registrar(forPlugin: "SharePlugin")!)

    // Register App Icon plugin for alternate icon support
    AppIconPlugin.register(with: flutterEngine.registrar(forPlugin: "AppIconPlugin")!)

    // File attributes channel: lets Dart exclude the offline downloads
    // directory from iCloud/iTunes backup (App Review 2.23).
    registerFileAttributesChannel(messenger: flutterEngine.binaryMessenger)

    // Shuffle/repeat state for CarPlay's Now Playing buttons (audio_service
    // doesn't set it), and CarPlay's real navigation stack for Dart.
    registerNowPlayingModesChannel(messenger: flutterEngine.binaryMessenger)
    registerCarPlayNavigationChannel(messenger: flutterEngine.binaryMessenger)

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

  /// Channel "nautune/now_playing_modes"
  ///   setModes({shuffle: Bool, repeat: "none" | "one" | "all"}) -> Bool
  /// audio_service enables the shuffle/repeat remote commands but never sets
  /// their current type, so CarPlay's Now Playing buttons always showed "off"
  /// and cycled from the wrong state. Method-channel handlers run on the main
  /// thread, which MPRemoteCommandCenter expects.
  private func registerNowPlayingModesChannel(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "nautune/now_playing_modes", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "setModes":
        guard let args = call.arguments as? [String: Any],
              let shuffle = args["shuffle"] as? Bool,
              let repeatMode = args["repeat"] as? String else {
          result(FlutterError(code: "INVALID_ARGS", message: "shuffle and repeat required", details: nil))
          return
        }
        let center = MPRemoteCommandCenter.shared()
        center.changeShuffleModeCommand.currentShuffleType = shuffle ? .items : .off
        switch repeatMode {
        case "one":
          center.changeRepeatModeCommand.currentRepeatType = .one
        case "all":
          center.changeRepeatModeCommand.currentRepeatType = .all
        default:
          center.changeRepeatModeCommand.currentRepeatType = .off
        }
        result(true)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    nowPlayingModesChannel = channel
  }

  /// Channel "nautune/carplay_navigation"
  ///   state() -> {depth: Int, nowPlayingOnTop: Bool} or nil (no CarPlay)
  /// The real CarPlay template stack. flutter_carplay's Dart history doesn't
  /// include the Now Playing template (neither the one it pushes nor the one
  /// CarPlay's own Now Playing button shows), so Dart asks here before
  /// pushing a page.
  private func registerCarPlayNavigationChannel(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "nautune/carplay_navigation", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "state":
        let carPlayScene = UIApplication.shared.connectedScenes
          .compactMap { $0 as? CPTemplateApplicationScene }
          .first
        guard let controller = carPlayScene?.interfaceController else {
          result(nil)
          return
        }
        let state: [String: Any] = [
          "depth": controller.templates.count,
          "nowPlayingOnTop": controller.topTemplate is CPNowPlayingTemplate,
        ]
        result(state)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    carPlayNavigationChannel = channel
  }
}
