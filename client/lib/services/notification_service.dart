import 'dart:io';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:windows_notification/windows_notification.dart';
import 'package:windows_notification/notification_message.dart';

class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  // Flutter Local Notifications (macOS)
  FlutterLocalNotificationsPlugin? _flutterLocalNotificationsPlugin;
  
  // Windows Notification
  WindowsNotification? _windowsNotification;
  
  bool _isInitialized = false;

  // Helper function for timestamped logging
  void _log(String message, [dynamic data]) {
    final timestamp = DateTime.now().toIso8601String();
    if (data != null) {
      print('[$timestamp] NOTIFICATION: $message - $data');
    } else {
      print('[$timestamp] NOTIFICATION: $message');
    }
  }

  Future<void> init() async {
    if (_isInitialized) return;
    
    try {
      _log('🔔 INITIALIZING NOTIFICATION SERVICE');
      
      if (Platform.isMacOS) {
        await _initMacOS();
      } else if (Platform.isWindows) {
        await _initWindows();
      }
      
      _isInitialized = true;
      _log('✅ NOTIFICATION SERVICE INITIALIZED');
    } catch (e) {
      _log('❌ FAILED TO INITIALIZE NOTIFICATION SERVICE', e.toString());
    }
  }

  Future<void> _initMacOS() async {
    _log('🍎 INITIALIZING MACOS NOTIFICATIONS');
    _flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();
    
    const DarwinInitializationSettings initializationSettingsDarwin =
        DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: false,
      requestSoundPermission: true,
    );

    const InitializationSettings initializationSettings =
        InitializationSettings(macOS: initializationSettingsDarwin);

    await _flutterLocalNotificationsPlugin!.initialize(initializationSettings);
    
    // Request permissions
    await _flutterLocalNotificationsPlugin!
        .resolvePlatformSpecificImplementation<
            MacOSFlutterLocalNotificationsPlugin>()
        ?.requestPermissions(
          alert: true,
          badge: false,
          sound: true,
        );
  }

  Future<void> _initWindows() async {
    _log('🪟 INITIALIZING WINDOWS NOTIFICATIONS');
    _windowsNotification = WindowsNotification(
      applicationId: "SharedClipboard.App",
    );
  }

  // Show clipboard share success notification
  Future<void> showClipboardShareSuccess(String deviceName) async {
    if (!_isInitialized) await init();
    
    const title = "Clipboard Shared";
    final message = "Clipboard content successfully shared to $deviceName";
    
    _log('📤 SHOWING CLIPBOARD SHARE SUCCESS', deviceName);
    await _showNotification(title, message);
  }

  // Show clipboard share failure notification
  Future<void> showClipboardShareFailure(String reason) async {
    if (!_isInitialized) await init();
    
    const title = "Clipboard Share Failed";
    final message = "Failed to share clipboard: $reason";
    
    _log('❌ SHOWING CLIPBOARD SHARE FAILURE', reason);
    await _showNotification(title, message);
  }

  // Show clipboard receive success notification
  Future<void> showClipboardReceiveSuccess(String deviceName, {bool isFile = false}) async {
    if (!_isInitialized) await init();
    
    const title = "Clipboard Received";
    final contentType = isFile ? "file(s)" : "content";
    final message = "Clipboard $contentType successfully received from $deviceName";
    
    _log('📥 SHOWING CLIPBOARD RECEIVE SUCCESS', '$deviceName - $contentType');
    await _showNotification(title, message);
  }

  // Show clipboard receive failure notification
  Future<void> showClipboardReceiveFailure(String reason) async {
    if (!_isInitialized) await init();
    
    const title = "Clipboard Receive Failed";
    final message = "Failed to receive clipboard: $reason";
    
    _log('❌ SHOWING CLIPBOARD RECEIVE FAILURE', reason);
    await _showNotification(title, message);
  }

  // Show file download progress notification
  Future<void> showFileDownloadProgress(int percentage, String fileName) async {
    if (!_isInitialized) await init();
    
    // Only show at round values (10%, 20%, 30%... 90%)
    if (percentage % 10 != 0 || percentage == 0 || percentage >= 100) return;
    
    final title = "Downloading File";
    final message = "$fileName - $percentage% complete";
    
    _log('📊 SHOWING FILE DOWNLOAD PROGRESS', '$fileName - $percentage%');
    await _showNotification(title, message);
  }

  // Show file download complete notification
  Future<void> showFileDownloadComplete(String fileName, String deviceName) async {
    if (!_isInitialized) await init();
    
    const title = "Download Complete";
    final message = "$fileName successfully downloaded from $deviceName";
    
    _log('✅ SHOWING FILE DOWNLOAD COMPLETE', '$fileName from $deviceName');
    await _showNotification(title, message);
  }

  // Show file upload progress notification
  Future<void> showFileUploadProgress(int percentage, String fileName) async {
    if (!_isInitialized) await init();
    
    // Only show at round values (10%, 20%, 30%... 90%)
    if (percentage % 10 != 0 || percentage == 0 || percentage >= 100) return;
    
    final title = "Uploading File";
    final message = "$fileName - $percentage% complete";
    
    _log('📤 SHOWING FILE UPLOAD PROGRESS', '$fileName - $percentage%');
    await _showNotification(title, message);
  }

  // Show file upload complete notification
  Future<void> showFileUploadComplete(String fileName, String deviceName) async {
    if (!_isInitialized) await init();
    
    const title = "Upload Complete";
    final message = "$fileName successfully uploaded to $deviceName";
    
    _log('✅ SHOWING FILE UPLOAD COMPLETE', '$fileName to $deviceName');
    await _showNotification(title, message);
  }

  // Generic notification method
  Future<void> _showNotification(String title, String message) async {
    try {
      if (Platform.isMacOS && _flutterLocalNotificationsPlugin != null) {
        await _showMacOSNotification(title, message);
      } else if (Platform.isWindows && _windowsNotification != null) {
        await _showWindowsNotification(title, message);
      } else {
        _log('⚠️ NO NOTIFICATION PLATFORM AVAILABLE');
      }
    } catch (e) {
      _log('❌ FAILED TO SHOW NOTIFICATION', e.toString());
    }
  }

  Future<void> _showMacOSNotification(String title, String message) async {
    const DarwinNotificationDetails darwinNotificationDetails =
        DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: false,
      presentSound: true,
    );

    const NotificationDetails notificationDetails =
        NotificationDetails(macOS: darwinNotificationDetails);

    await _flutterLocalNotificationsPlugin!.show(
      DateTime.now().millisecondsSinceEpoch ~/ 1000, // Use timestamp as ID
      title,
      message,
      notificationDetails,
    );
  }

  Future<void> _showWindowsNotification(String title, String message) async {
    // Create notification message using plugin template
    final notificationMessage = NotificationMessage.fromPluginTemplate(
      DateTime.now().millisecondsSinceEpoch.toString(), // unique ID
      title,
      message,
    );
    
    await _windowsNotification!.showNotificationPluginTemplate(notificationMessage);
  }

  // Dispose method for cleanup
  void dispose() {
    _log('🧹 DISPOSING NOTIFICATION SERVICE');
    _isInitialized = false;
  }
}
