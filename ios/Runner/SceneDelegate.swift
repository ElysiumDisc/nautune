//
//  SceneDelegate.swift
//  Runner
//
//  Created for Nautune CarPlay integration.
//

import Flutter
import UIKit

@available(iOS 13.0, *)
class SceneDelegate: UIResponder, UIWindowSceneDelegate {
  var window: UIWindow?
  private var backgroundTaskIdentifier: UIBackgroundTaskIdentifier = .invalid

  func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    guard let windowScene = scene as? UIWindowScene else { return }

    window = UIWindow(windowScene: windowScene)

    let controller = FlutterViewController(engine: flutterEngine, nibName: nil, bundle: nil)
    controller.loadDefaultSplashScreenView()
    window?.rootViewController = controller
    window?.makeKeyAndVisible()
  }

  // With a scene manifest UIKit never calls applicationDidEnterBackground,
  // so the background-time request for saving playback state lives here.
  func sceneDidEnterBackground(_ scene: UIScene) {
    endBackgroundTask()
    let taskId = UIApplication.shared.beginBackgroundTask(
      withName: "SavePlaybackState"
    ) { [weak self] in
      self?.endBackgroundTask()
    }
    backgroundTaskIdentifier = taskId

    // Allow 3 seconds for Flutter to save state. Only end the task this call
    // started: after a quick background -> foreground -> background, an older
    // timer must not end the newer task early.
    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
      guard let self = self, self.backgroundTaskIdentifier == taskId else { return }
      self.endBackgroundTask()
    }
  }

  private func endBackgroundTask() {
    guard backgroundTaskIdentifier != .invalid else { return }
    UIApplication.shared.endBackgroundTask(backgroundTaskIdentifier)
    backgroundTaskIdentifier = .invalid
  }
}
