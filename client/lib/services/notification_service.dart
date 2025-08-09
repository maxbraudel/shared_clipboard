import 'dart:io';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class NotificationService {
  static final FlutterLocalNotificationsPlugin _flutterLocalNotificationsPlugin =
      FlutterLocalNotificationsPlugin();
  
  static bool _isInitialized = false;
  static final Map<String, int> _activeDownloads = {};
  static int _notificationIdCounter = 1000;

  // Helper function for timestamped logging
  static void _log(String message, [dynamic data]) {
    final timestamp = DateTime.now().toIso8601String();
    if (data != null) {
      print('[$timestamp] NOTIFICATION: $message - $data');
    } else {
      print('[$timestamp] NOTIFICATION: $message');
    }
  }

  /// Initialize the notification service (Windows only)
  static Future<void> init() async {
    if (_isInitialized || !Platform.isWindows) {
      return;
    }

    try {
      const WindowsInitializationSettings initializationSettingsWindows =
          WindowsInitializationSettings(
        appName: 'Shared Clipboard',
        appUserModelId: 'com.sharedclipboard.app',
      );

      const InitializationSettings initializationSettings =
          InitializationSettings(
        windows: initializationSettingsWindows,
      );

      await _flutterLocalNotificationsPlugin.initialize(
        initializationSettings,
        onDidReceiveNotificationResponse: _onNotificationResponse,
      );

      _isInitialized = true;
      _log('✅ NOTIFICATION SERVICE INITIALIZED');
    } catch (e) {
      _log('❌ FAILED TO INITIALIZE NOTIFICATION SERVICE', e.toString());
    }
  }

  /// Handle notification responses (clicks, etc.)
  static void _onNotificationResponse(NotificationResponse response) {
    _log('📱 NOTIFICATION RESPONSE', {
      'id': response.id,
      'actionId': response.actionId,
      'payload': response.payload,
    });
  }

  /// Start a download notification with progress bar
  static Future<void> startDownloadNotification({
    required String fileName,
    required String sessionId,
    int totalBytes = 0,
  }) async {
    if (!_isInitialized || !Platform.isWindows) {
      return;
    }

    try {
      final notificationId = _notificationIdCounter++;
      _activeDownloads[sessionId] = notificationId;

      final sizeText = totalBytes > 0 
          ? ' (${_formatBytes(totalBytes)})'
          : '';

      await _flutterLocalNotificationsPlugin.show(
        notificationId,
        'Downloading File',
        '$fileName$sizeText - Starting...',
        NotificationDetails(
          windows: WindowsNotificationDetails(
            progress: 0,
            progressBarLabel: 'Preparing download...',
          ),
        ),
        payload: 'download_$sessionId',
      );

      _log('📥 DOWNLOAD NOTIFICATION STARTED', {
        'fileName': fileName,
        'sessionId': sessionId,
        'notificationId': notificationId,
        'totalBytes': totalBytes,
      });
    } catch (e) {
      _log('❌ FAILED TO START DOWNLOAD NOTIFICATION', e.toString());
    }
  }

  /// Update download progress
  static Future<void> updateDownloadProgress({
    required String sessionId,
    required String fileName,
    required int receivedBytes,
    required int totalBytes,
  }) async {
    if (!_isInitialized || !Platform.isWindows) {
      return;
    }

    final notificationId = _activeDownloads[sessionId];
    if (notificationId == null) {
      return;
    }

    try {
      final progress = totalBytes > 0 ? (receivedBytes / totalBytes * 100).round() : 0;
      final progressText = totalBytes > 0 
          ? '${_formatBytes(receivedBytes)} / ${_formatBytes(totalBytes)}'
          : '${_formatBytes(receivedBytes)} received';

      await _flutterLocalNotificationsPlugin.show(
        notificationId,
        'Downloading File',
        '$fileName - $progress% complete',
        NotificationDetails(
          windows: WindowsNotificationDetails(
            progress: progress,
            progressBarLabel: progressText,
          ),
        ),
        payload: 'download_$sessionId',
      );

      // Only log every 10% to avoid spam
      if (progress % 10 == 0 || progress >= 100) {
        _log('📊 DOWNLOAD PROGRESS UPDATED', {
          'fileName': fileName,
          'sessionId': sessionId,
          'progress': progress,
          'receivedBytes': receivedBytes,
          'totalBytes': totalBytes,
        });
      }
    } catch (e) {
      _log('❌ FAILED TO UPDATE DOWNLOAD PROGRESS', e.toString());
    }
  }

  /// Complete download notification
  static Future<void> completeDownloadNotification({
    required String sessionId,
    required String fileName,
    required int totalBytes,
  }) async {
    if (!_isInitialized || !Platform.isWindows) {
      return;
    }

    final notificationId = _activeDownloads.remove(sessionId);
    if (notificationId == null) {
      return;
    }

    try {
      final sizeText = totalBytes > 0 ? ' (${_formatBytes(totalBytes)})' : '';

      await _flutterLocalNotificationsPlugin.show(
        notificationId,
        'Download Complete',
        '$fileName$sizeText - Successfully downloaded',
        const NotificationDetails(
          windows: WindowsNotificationDetails(
            progress: 100,
            progressBarLabel: 'Download complete',
          ),
        ),
        payload: 'download_complete_$sessionId',
      );

      _log('✅ DOWNLOAD NOTIFICATION COMPLETED', {
        'fileName': fileName,
        'sessionId': sessionId,
        'totalBytes': totalBytes,
      });

      // Auto-dismiss after 5 seconds
      Future.delayed(const Duration(seconds: 5), () {
        _flutterLocalNotificationsPlugin.cancel(notificationId);
      });
    } catch (e) {
      _log('❌ FAILED TO COMPLETE DOWNLOAD NOTIFICATION', e.toString());
    }
  }

  /// Cancel download notification
  static Future<void> cancelDownloadNotification({
    required String sessionId,
    required String fileName,
  }) async {
    if (!_isInitialized || !Platform.isWindows) {
      return;
    }

    final notificationId = _activeDownloads.remove(sessionId);
    if (notificationId == null) {
      return;
    }

    try {
      await _flutterLocalNotificationsPlugin.cancel(notificationId);
      
      _log('🛑 DOWNLOAD NOTIFICATION CANCELLED', {
        'fileName': fileName,
        'sessionId': sessionId,
      });
    } catch (e) {
      _log('❌ FAILED TO CANCEL DOWNLOAD NOTIFICATION', e.toString());
    }
  }

  /// Format bytes to human readable format
  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  /// Clear all active download notifications
  static Future<void> clearAllDownloadNotifications() async {
    if (!_isInitialized || !Platform.isWindows) {
      return;
    }

    try {
      for (final notificationId in _activeDownloads.values) {
        await _flutterLocalNotificationsPlugin.cancel(notificationId);
      }
      _activeDownloads.clear();
      
      _log('🧹 ALL DOWNLOAD NOTIFICATIONS CLEARED');
    } catch (e) {
      _log('❌ FAILED TO CLEAR DOWNLOAD NOTIFICATIONS', e.toString());
    }
  }
}
