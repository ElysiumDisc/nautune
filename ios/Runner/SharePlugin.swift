import Flutter
import UIKit

/// Native iOS plugin for sharing audio files via UIActivityViewController.
/// Enables AirDrop, Messages, Mail, Files, and other system sharing options.
public class SharePlugin: NSObject, FlutterPlugin {

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "com.nautune.share/methods",
            binaryMessenger: registrar.messenger()
        )
        let instance = SharePlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
        print("SharePlugin: Registered")
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "shareFile":
            guard let args = call.arguments as? [String: Any],
                  let filePath = args["filePath"] as? String,
                  let trackName = args["trackName"] as? String,
                  let artistName = args["artistName"] as? String else {
                result(FlutterError(code: "INVALID_ARGS", message: "filePath, trackName, and artistName required", details: nil))
                return
            }
            shareFile(filePath: filePath, trackName: trackName, artistName: artistName, result: result)

        case "isAvailable":
            result(true)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func shareFile(filePath: String, trackName: String, artistName: String, result: @escaping FlutterResult) {
        let fileURL = URL(fileURLWithPath: filePath)

        // Verify file exists
        guard FileManager.default.fileExists(atPath: filePath) else {
            print("SharePlugin: File not found at \(filePath)")
            result(FlutterError(code: "FILE_NOT_FOUND", message: "Audio file not found", details: filePath))
            return
        }

        print("SharePlugin: Sharing file \(trackName) by \(artistName)")

        DispatchQueue.main.async {
            // Create activity items - just the file URL for clean sharing
            let activityItems: [Any] = [fileURL]

            let activityVC = UIActivityViewController(
                activityItems: activityItems,
                applicationActivities: nil
            )

            // Exclude irrelevant activity types
            activityVC.excludedActivityTypes = [
                .assignToContact,
                .addToReadingList
            ]

            // Get the root view controller
            guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                  let rootVC = windowScene.windows.first?.rootViewController else {
                result(FlutterError(code: "NO_VIEW_CONTROLLER", message: "Could not find root view controller", details: nil))
                return
            }

            // Find the topmost presented controller
            var topVC = rootVC
            while let presented = topVC.presentedViewController {
                topVC = presented
            }

            // For iPad: configure popover presentation
            if let popover = activityVC.popoverPresentationController {
                popover.sourceView = topVC.view
                popover.sourceRect = CGRect(
                    x: topVC.view.bounds.midX,
                    y: topVC.view.bounds.midY,
                    width: 0,
                    height: 0
                )
                popover.permittedArrowDirections = []
            }

            // Completion handler
            activityVC.completionWithItemsHandler = { activityType, completed, returnedItems, error in
                if let error = error {
                    print("SharePlugin: Error - \(error.localizedDescription)")
                    result(FlutterError(code: "SHARE_ERROR", message: error.localizedDescription, details: nil))
                } else if completed {
                    print("SharePlugin: Share completed via \(activityType?.rawValue ?? "unknown")")
                    result(true)
                } else {
                    print("SharePlugin: Share cancelled")
                    result(false)  // User cancelled
                }
            }

            topVC.present(activityVC, animated: true)
        }
    }
}
