import UIKit
import Flutter

let flutterEngine = FlutterEngine(name: "SharedEngine", project: nil, allowHeadlessExecution: true)

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    flutterEngine.run()
    GeneratedPluginRegistrant.register(with: flutterEngine)

    // Register Audio FFT plugin for real-time visualization
    AudioFFTPlugin.register(with: flutterEngine.registrar(forPlugin: "AudioFFTPlugin")!)

    // Register Share plugin for native file sharing (AirDrop, etc.)
    SharePlugin.register(with: flutterEngine.registrar(forPlugin: "SharePlugin")!)

    // Return true directly for CarPlay compatibility
    // super.application() can interfere with CarPlay initialization
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
