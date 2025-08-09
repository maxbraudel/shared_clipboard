import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class NotificationService {
  static final FlutterLocalNotificationsPlugin _notifications = FlutterLocalNotificationsPlugin();
  static bool _initialized = false;
  
  // Download progress tracking
  static final Map<String, _DownloadProgress> _downloadProgress = {};
  static Timer? _progressTimer;

  static Future<void> init() async {
    if (_initialized) return;

    try {
      // Android initialization
      const AndroidInitializationSettings initializationSettingsAndroid =
          AndroidInitializationSettings('@mipmap/ic_launcher');

      // iOS initialization
      const DarwinInitializationSettings initializationSettingsIOS =
          DarwinInitializationSettings(
        requestSoundPermission: true,
        requestBadgePermission: true,
        requestAlertPermission: true,
      );

      // macOS initialization
      const DarwinInitializationSettings initializationSettingsMacOS =
          DarwinInitializationSettings(
        requestSoundPermission: true,
        requestBadgePermission: true,
        requestAlertPermission: true,
        defaultPresentAlert: true,
        defaultPresentSound: true,
        defaultPresentBanner: true,
      );

      // Windows initialization
      const LinuxInitializationSettings initializationSettingsLinux =
          LinuxInitializationSettings(defaultActionName: 'Open notification');

      const InitializationSettings initializationSettings = InitializationSettings(
        android: initializationSettingsAndroid,
        iOS: initializationSettingsIOS,
        macOS: initializationSettingsMacOS,
        linux: initializationSettingsLinux,
      );

      await _notifications.initialize(
        initializationSettings,
        onDidReceiveNotificationResponse: _onNotificationTapped,
      );

      // Request permissions for iOS/macOS
      if (Platform.isIOS || Platform.isMacOS) {
        await _notifications
            .resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>()
            ?.requestPermissions(
              alert: true,
              badge: true,
              sound: true,
            );
      }

      _initialized = true;
      debugPrint('✅ NotificationService initialized successfully');
    } catch (e) {
      debugPrint('❌ Failed to initialize NotificationService: $e');
    }
  }

  static void _onNotificationTapped(NotificationResponse response) {
    debugPrint('📱 Notification tapped: ${response.payload}');
  }

  /// Show notification when clipboard is shared
  static Future<void> showClipboardShared({String? deviceName}) async {
    if (!_initialized) await init();

    const AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
      'clipboard_shared',
      'Clipboard Shared',
      channelDescription: 'Notifications when clipboard is shared',
      importance: Importance.high,
      priority: Priority.high,
      icon: '@mipmap/ic_launcher',
    );

    const DarwinNotificationDetails macosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: false,
      presentSound: true,
      presentBanner: true,
      interruptionLevel: InterruptionLevel.active,
    );

    const NotificationDetails details = NotificationDetails(
      android: androidDetails,
      iOS: macosDetails,
      macOS: macosDetails,
    );

    final String message = deviceName != null 
        ? 'Clipboard shared to $deviceName'
        : 'Clipboard shared successfully';

    await _notifications.show(
      1,
      '📋 Clipboard Shared',
      message,
      details,
      payload: 'clipboard_shared',
    );

    debugPrint('📤 Notification sent: Clipboard shared');
  }

  /// Show notification when clipboard is retrieved
  static Future<void> showClipboardRetrieved({String? fromDevice}) async {
    if (!_initialized) await init();

    const AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
      'clipboard_retrieved',
      'Clipboard Retrieved',
      channelDescription: 'Notifications when clipboard is retrieved',
      importance: Importance.defaultImportance,
      priority: Priority.defaultPriority,
      icon: '@mipmap/ic_launcher',
    );

    const DarwinNotificationDetails macosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: false,
      presentSound: true,
      presentBanner: true,
      interruptionLevel: InterruptionLevel.active,
    );

    const NotificationDetails details = NotificationDetails(
      android: androidDetails,
      iOS: macosDetails,
      macOS: macosDetails,
    );

    final String message = fromDevice != null 
        ? 'Clipboard retrieved from $fromDevice'
        : 'Clipboard retrieved successfully';

    await _notifications.show(
      2,
      '📥 Clipboard Retrieved',
      message,
      details,
      payload: 'clipboard_retrieved',
    );

    debugPrint('📥 Notification sent: Clipboard retrieved');
  }

  /// Start tracking download progress for a file
  static void startDownloadProgress(String fileId, String fileName) {
    debugPrint('📊 Starting download progress tracking for: $fileName');
    
    _downloadProgress[fileId] = _DownloadProgress(
      fileName: fileName,
      lastNotificationProgress: -1, // Start with -1 so first progress > 0 triggers notification
      lastNotificationTime: DateTime.now(),
    );

    // Start or restart the progress timer
    _progressTimer?.cancel();
    _progressTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      _checkProgressNotifications();
    });
  }

  /// Update download progress
  static void updateDownloadProgress(String fileId, double progress) {
    final downloadInfo = _downloadProgress[fileId];
    if (downloadInfo == null) return;

    downloadInfo.currentProgress = progress;
    debugPrint('📊 Download progress updated: ${downloadInfo.fileName} - ${progress.toStringAsFixed(1)}%');
  }

  /// Check if progress notifications should be sent
  static void _checkProgressNotifications() {
    final now = DateTime.now();
    
    for (final entry in _downloadProgress.entries) {
      final fileId = entry.key;
      final progress = entry.value;
      
      // Check if 10 seconds have passed since last notification
      if (now.difference(progress.lastNotificationTime).inSeconds >= 10) {
        final currentProgress = progress.currentProgress;
        final lastNotifiedProgress = progress.lastNotificationProgress;
        
        // Send notification if progress increased by at least 10% or if it's the first progress > 0
        if ((lastNotifiedProgress == -1 && currentProgress > 0) ||
            (currentProgress - lastNotifiedProgress >= 10)) {
          
          _showDownloadProgressNotification(fileId, progress.fileName, currentProgress);
          progress.lastNotificationProgress = currentProgress;
          progress.lastNotificationTime = now;
        }
      }
    }
  }

  /// Show download progress notification
  static Future<void> _showDownloadProgressNotification(String fileId, String fileName, double progress) async {
    if (!_initialized) await init();

    final AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
      'file_download_progress',
      'File Download Progress',
      channelDescription: 'Progress notifications for file downloads',
      importance: Importance.low,
      priority: Priority.low,
      onlyAlertOnce: true,
      showProgress: true,
      maxProgress: 100,
      progress: progress.toInt(),
      icon: '@mipmap/ic_launcher',
    );

    const DarwinNotificationDetails macosDetails = DarwinNotificationDetails(
      presentAlert: false,
      presentBadge: false,
      presentSound: false,
      presentBanner: true,
      interruptionLevel: InterruptionLevel.passive,
    );

    final NotificationDetails details = NotificationDetails(
      android: androidDetails,
      iOS: macosDetails,
      macOS: macosDetails,
    );

    await _notifications.show(
      fileId.hashCode, // Use fileId hash as unique notification ID
      '⬇️ Downloading ${fileName}',
      '${progress.toStringAsFixed(1)}% complete',
      details,
      payload: 'download_progress:$fileId',
    );

    debugPrint('📊 Progress notification sent: ${fileName} - ${progress.toStringAsFixed(1)}%');
  }

  /// Show notification when download is completed
  static Future<void> showDownloadCompleted(String fileId, String fileName) async {
    if (!_initialized) await init();

    // Stop tracking this download
    _downloadProgress.remove(fileId);
    
    // Cancel progress timer if no more downloads
    if (_downloadProgress.isEmpty) {
      _progressTimer?.cancel();
      _progressTimer = null;
    }

    // Cancel the progress notification for this file
    await _notifications.cancel(fileId.hashCode);

    const AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
      'file_download_completed',
      'File Download Completed',
      channelDescription: 'Notifications when file downloads complete',
      importance: Importance.defaultImportance,
      priority: Priority.defaultPriority,
      icon: '@mipmap/ic_launcher',
    );

    const DarwinNotificationDetails macosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: false,
      presentSound: true,
      presentBanner: true,
      interruptionLevel: InterruptionLevel.active,
    );

    const NotificationDetails details = NotificationDetails(
      android: androidDetails,
      iOS: macosDetails,
      macOS: macosDetails,
    );

    await _notifications.show(
      3,
      '✅ Download Complete',
      '$fileName downloaded successfully',
      details,
      payload: 'download_completed:$fileId',
    );

    debugPrint('✅ Download completion notification sent: $fileName');
  }

  /// Show notification when download fails
  static Future<void> showDownloadFailed(String fileId, String fileName, {String? error}) async {
    if (!_initialized) await init();

    // Stop tracking this download
    _downloadProgress.remove(fileId);
    
    // Cancel progress timer if no more downloads
    if (_downloadProgress.isEmpty) {
      _progressTimer?.cancel();
      _progressTimer = null;
    }

    // Cancel the progress notification for this file
    await _notifications.cancel(fileId.hashCode);

    const AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
      'file_download_failed',
      'File Download Failed',
      channelDescription: 'Notifications when file downloads fail',
      importance: Importance.high,
      priority: Priority.high,
      icon: '@mipmap/ic_launcher',
    );

    const DarwinNotificationDetails macosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: false,
      presentSound: true,
      presentBanner: true,
      interruptionLevel: InterruptionLevel.active,
    );

    const NotificationDetails details = NotificationDetails(
      android: androidDetails,
      iOS: macosDetails,
      macOS: macosDetails,
    );

    final String message = error != null 
        ? '$fileName download failed: $error'
        : '$fileName download failed';

    await _notifications.show(
      4,
      '❌ Download Failed',
      message,
      details,
      payload: 'download_failed:$fileId',
    );

    debugPrint('❌ Download failure notification sent: $fileName');
  }

  /// Clear all notifications
  static Future<void> clearAll() async {
    await _notifications.cancelAll();
    debugPrint('🧹 All notifications cleared');
  }

  /// Dispose resources
  static void dispose() {
    _progressTimer?.cancel();
    _progressTimer = null;
    _downloadProgress.clear();
    debugPrint('🗑️ NotificationService disposed');
  }
}

/// Internal class to track download progress
class _DownloadProgress {
  final String fileName;
  double currentProgress;
  double lastNotificationProgress;
  DateTime lastNotificationTime;

  _DownloadProgress({
    required this.fileName,
    this.currentProgress = 0.0,
    required this.lastNotificationProgress,
    required this.lastNotificationTime,
  });
}
