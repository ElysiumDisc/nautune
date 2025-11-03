import Flutter
import UIKit
import CarPlay

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
  
  override func application(
    _ application: UIApplication,
    configurationForConnecting connectingSceneSession: UISceneSession,
    options: UIScene.ConnectionOptions
  ) -> UISceneConfiguration {
    if #available(iOS 14.0, *),
       connectingSceneSession.role == .carTemplateApplication {
      let sceneConfig = UISceneConfiguration(
        name: "CarPlay",
        sessionRole: connectingSceneSession.role
      )
      sceneConfig.delegateClass = CarPlaySceneDelegate.self
      return sceneConfig
    }
    
    return super.application(application, configurationForConnecting: connectingSceneSession, options: options)
  }
}
