import 'dart:io';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class NotificationService {
  final FlutterLocalNotificationsPlugin _flutterLocalNotificationsPlugin =
      FlutterLocalNotificationsPlugin();

  static const int _downloadNotificationId = 888;

  bool _initialized = false;

  Future<void> initialize() async {
    if (_initialized) return;

    // iOS setup
    final DarwinInitializationSettings initializationSettingsDarwin =
        DarwinInitializationSettings(
      requestSoundPermission: false,
      requestBadgePermission: false,
      requestAlertPermission: false,
    );

    final InitializationSettings initializationSettings = InitializationSettings(
      iOS: initializationSettingsDarwin,
    );

    await _flutterLocalNotificationsPlugin.initialize(
      settings: initializationSettings,
      onDidReceiveNotificationResponse: (details) {
        // Handle notification tap
      },
    );

    _initialized = true;
  }
  
  Future<void> requestPermissions() async {
    if (Platform.isIOS) {
       await _flutterLocalNotificationsPlugin
           .resolvePlatformSpecificImplementation<
               IOSFlutterLocalNotificationsPlugin>()
           ?.requestPermissions(
             alert: true,
             badge: true,
             sound: true,
           );
    }
  }

  /// Show or update progress notification.
  ///
  /// No-op on iOS: iOS has no progress notifications, and re-posting a
  /// notification per progress tick would present a new banner (and sound)
  /// each time once notification permission is granted.
  Future<void> showProgress({
    required String title,
    required String body,
    int? progress, // 0-100, null for indeterminate
    int maxProgress = 100,
  }) async {
    if (!_initialized || Platform.isIOS) return;

    const NotificationDetails platformChannelSpecifics = NotificationDetails();

    await _flutterLocalNotificationsPlugin.show(
      id: _downloadNotificationId,
      title: title,
      body: body,
      notificationDetails: platformChannelSpecifics,
    );
  }

  /// Show download complete notification
  Future<void> showComplete({required String title, required String body}) async {
    if (!_initialized) return;

    const NotificationDetails platformChannelSpecifics = NotificationDetails();

    await _flutterLocalNotificationsPlugin.show(
      id: _downloadNotificationId,
      title: title,
      body: body,
      notificationDetails: platformChannelSpecifics,
    );
  }

  /// Cancel the download notification
  Future<void> cancel() async {
    if (!_initialized) return;
    await _flutterLocalNotificationsPlugin.cancel(id: _downloadNotificationId);
  }
}
