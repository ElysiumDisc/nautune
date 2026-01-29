import Flutter
import UIKit

public class AppIconPlugin: NSObject, FlutterPlugin {

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "com.nautune.app_icon/methods",
            binaryMessenger: registrar.messenger()
        )
        let instance = AppIconPlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "setIcon":
            guard let args = call.arguments as? [String: Any],
                  let iconName = args["iconName"] as? String else {
                result(FlutterError(code: "INVALID_ARGS", message: "iconName required", details: nil))
                return
            }
            setAlternateIcon(iconName: iconName, result: result)

        case "getCurrentIcon":
            if let currentIcon = UIApplication.shared.alternateIconName {
                result(currentIcon)
            } else {
                result("default")
            }

        case "supportsAlternateIcons":
            result(UIApplication.shared.supportsAlternateIcons)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func setAlternateIcon(iconName: String, result: @escaping FlutterResult) {
        guard UIApplication.shared.supportsAlternateIcons else {
            result(FlutterError(code: "NOT_SUPPORTED", message: "Alternate icons not supported", details: nil))
            return
        }

        // nil = primary/default icon, otherwise use the alternate icon name
        let newIconName: String? = (iconName == "default") ? nil : iconName

        UIApplication.shared.setAlternateIconName(newIconName) { error in
            if let error = error {
                result(FlutterError(code: "SET_FAILED", message: error.localizedDescription, details: nil))
            } else {
                result(true)
            }
        }
    }
}
