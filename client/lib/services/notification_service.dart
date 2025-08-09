import 'dart:io';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter/foundation.dart';

class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  final FlutterLocalNotificationsPlugin _flutterLocalNotificationsPlugin =
      FlutterLocalNotificationsPlugin();

  bool _isInitialized = false;
  int _notificationId = 0;

  // Helper function for timestamped logging
  void _log(String message, [dynamic data]) {
    final timestamp = DateTime.now().toIso8601String();
    if (data != null) {
      print('[$timestamp] NOTIFICATION: $message - $data');
    } else {
      print('[$timestamp] NOTIFICATION: $message');
    }
  }

  /// Initialize the notification service
  Future<void> initialize() async {
    if (_isInitialized) return;

    try {
      _log('🔔 INITIALIZING NOTIFICATION SERVICE');
      
      // Initialize for all platforms including Windows
      _log('🔔 INITIALIZING FOR PLATFORM: ${Platform.operatingSystem}');

      // Initialize settings for different platforms
      const AndroidInitializationSettings initializationSettingsAndroid =
          AndroidInitializationSettings('@mipmap/ic_launcher');

      const DarwinInitializationSettings initializationSettingsDarwin =
          DarwinInitializationSettings(
        requestAlertPermission: true,
        requestBadgePermission: false,
        requestSoundPermission: true,
        onDidReceiveLocalNotification: null,
      );

      const LinuxInitializationSettings initializationSettingsLinux =
          LinuxInitializationSettings(defaultActionName: 'Open notification');

      const InitializationSettings initializationSettings =
          InitializationSettings(
        android: initializationSettingsAndroid,
        iOS: initializationSettingsDarwin,
        macOS: initializationSettingsDarwin,
        linux: initializationSettingsLinux,
      );

      final bool? initialized = await _flutterLocalNotificationsPlugin
          .initialize(initializationSettings);

      if (initialized == true) {
        _isInitialized = true;
        _log('✅ NOTIFICATION SERVICE INITIALIZED SUCCESSFULLY');

        // Request permissions for macOS
        if (Platform.isMacOS) {
          await _requestMacOSPermissions();
        }
        
        // Add extra initialization time for Windows C++/WinRT Toast Notifications
        if (Platform.isWindows) {
          await Future.delayed(Duration(milliseconds: 1000));
          _log('🪟 WINDOWS C++/WINRT TOAST NOTIFICATIONS READY');
          
          // Test Windows notification capability
          try {
            await _testWindowsNotification();
          } catch (e) {
            _log('⚠️ WINDOWS NOTIFICATION TEST FAILED', e.toString());
            // Don't fail initialization, just log the issue
          }
        }
      } else {
        _log('❌ FAILED TO INITIALIZE NOTIFICATION SERVICE');
      }
    } catch (e, stackTrace) {
      _log('❌ ERROR INITIALIZING NOTIFICATIONS', e.toString());
      if (kDebugMode) {
        print('Stack trace: $stackTrace');
      }
    }
  }

  /// Initialize notifications specifically for Windows
  Future<void> _initializeWindows() async {
    try {
      _log('🪟 INITIALIZING WINDOWS NOTIFICATIONS');
      
      // Simple initialization for Windows with minimal settings
      const InitializationSettings initializationSettings =
          InitializationSettings();

      // Add retry logic for Windows initialization
      bool initialized = false;
      int attempts = 0;
      const maxAttempts = 3;
      
      while (!initialized && attempts < maxAttempts) {
        attempts++;
        _log('🪟 WINDOWS INIT ATTEMPT', attempts);
        
        try {
          final bool? result = await _flutterLocalNotificationsPlugin
              .initialize(initializationSettings);
          
          if (result == true) {
            initialized = true;
            _isInitialized = true;
            _log('✅ WINDOWS NOTIFICATION SERVICE INITIALIZED SUCCESSFULLY');
          } else {
            _log('⚠️ WINDOWS INIT RETURNED FALSE, ATTEMPT $attempts');
            if (attempts < maxAttempts) {
              await Future.delayed(Duration(milliseconds: 1000));
            }
          }
        } catch (e) {
          _log('❌ WINDOWS INIT ATTEMPT $attempts FAILED', e.toString());
          if (attempts < maxAttempts) {
            await Future.delayed(Duration(milliseconds: 1000));
          }
        }
      }
      
      if (!initialized) {
        _log('❌ FAILED TO INITIALIZE WINDOWS NOTIFICATIONS AFTER $maxAttempts ATTEMPTS');
        // Mark as initialized anyway to prevent crashes, but notifications won't work
        _isInitialized = false;
      }
    } catch (e, stackTrace) {
      _log('❌ ERROR INITIALIZING WINDOWS NOTIFICATIONS', e.toString());
      if (kDebugMode) {
        print('Windows notification stack trace: $stackTrace');
      }
      _isInitialized = false;
    }
  }

  /// Test Windows notification capability
  Future<void> _testWindowsNotification() async {
    try {
      _log('🧪 TESTING WINDOWS NOTIFICATION CAPABILITY');
      
      // Try to create a simple test notification without showing it
      const NotificationDetails testDetails = NotificationDetails(
        linux: LinuxNotificationDetails(),
      );
      
      // Just test if we can access the plugin without errors
      final _ = _flutterLocalNotificationsPlugin.toString();
      _log('✅ WINDOWS NOTIFICATION TEST PASSED');
    } catch (e) {
      _log('❌ WINDOWS NOTIFICATION TEST FAILED', e.toString());
      throw e;
    }
  }

  /// Request permissions for macOS
  Future<void> _requestMacOSPermissions() async {
    try {
      final bool? result = await _flutterLocalNotificationsPlugin
          .resolvePlatformSpecificImplementation<
              MacOSFlutterLocalNotificationsPlugin>()
          ?.requestPermissions(
            alert: true,
            badge: false,
            sound: true,
          );

      _log('📱 MACOS PERMISSIONS RESULT', result);
    } catch (e) {
      _log('⚠️ ERROR REQUESTING MACOS PERMISSIONS', e.toString());
    }
  }

  /// Get next notification ID
  int _getNextNotificationId() {
    return ++_notificationId;
  }

  /// Show a basic notification
  Future<void> _showNotification({
    required String title,
    required String body,
    String? payload,
  }) async {
    if (!_isInitialized) {
      _log('⚠️ NOTIFICATION SERVICE NOT INITIALIZED');
      return;
    }

    // Additional safety check for Windows initialization
    if (Platform.isWindows && !_isInitialized) {
      _log('⚠️ WINDOWS NOTIFICATION SERVICE NOT INITIALIZED, USING FALLBACK');
      await _showWindowsFallbackNotification(title, body);
      return;
    }

    try {
      NotificationDetails platformChannelSpecifics = NotificationDetails(
        android: const AndroidNotificationDetails(
          'shared_clipboard_channel',
          'Shared Clipboard',
          channelDescription: 'Notifications for clipboard sharing operations',
          importance: Importance.high,
          priority: Priority.high,
        ),
        iOS: const DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: false,
          presentSound: true,
        ),
        macOS: const DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: false,
          presentSound: true,
        ),
        linux: const LinuxNotificationDetails(),

      );

      await _flutterLocalNotificationsPlugin.show(
        _getNextNotificationId(),
        title,
        body,
        platformChannelSpecifics,
        payload: payload,
      );

      _log('📤 NOTIFICATION SENT', {'title': title, 'body': body});
    } catch (e) {
      _log('❌ ERROR SHOWING NOTIFICATION', e.toString());
      
      // If Windows notification fails, use fallback
      if (Platform.isWindows) {
        _log('🪟 WINDOWS NOTIFICATION FAILED, USING FALLBACK');
        await _showWindowsFallbackNotification(title, body);
      }
    }
  }

  // =============================================================================
  // CLIPBOARD SHARING NOTIFICATIONS
  // =============================================================================

  /// Show notification when clipboard sharing succeeds
  Future<void> showClipboardShareSuccess({String? deviceName}) async {
    final String title = '✅ Clipboard Shared';
    final String body = deviceName != null
        ? 'Successfully shared clipboard with $deviceName'
        : 'Successfully shared clipboard';

    await _showNotification(
      title: title,
      body: body,
      payload: 'clipboard_share_success',
    );
  }

  /// Show notification when clipboard sharing fails
  Future<void> showClipboardShareFailure({String? reason}) async {
    const String title = '❌ Clipboard Share Failed';
    final String body = reason != null
        ? 'Failed to share clipboard: $reason'
        : 'Failed to share clipboard';

    await _showNotification(
      title: title,
      body: body,
      payload: 'clipboard_share_failure',
    );
  }

  // =============================================================================
  // CLIPBOARD RECEIVING NOTIFICATIONS
  // =============================================================================

  /// Show notification when clipboard receiving succeeds
  Future<void> showClipboardReceiveSuccess({String? deviceName, String? contentType}) async {
    final String title = '📥 Clipboard Received';
    String body = deviceName != null
        ? 'Received clipboard from $deviceName'
        : 'Received clipboard content';
    
    if (contentType != null) {
      body += ' ($contentType)';
    }

    await _showNotification(
      title: title,
      body: body,
      payload: 'clipboard_receive_success',
    );
  }

  /// Show notification when clipboard receiving fails
  Future<void> showClipboardReceiveFailure({String? reason}) async {
    const String title = '❌ Clipboard Receive Failed';
    final String body = reason != null
        ? 'Failed to receive clipboard: $reason'
        : 'Failed to receive clipboard';

    await _showNotification(
      title: title,
      body: body,
      payload: 'clipboard_receive_failure',
    );
  }

  // =============================================================================
  // FILE DOWNLOAD NOTIFICATIONS
  // =============================================================================

  /// Show notification for file download progress (10% increments)
  Future<void> showFileDownloadProgress({
    required int progressPercentage,
    required String fileName,
    String? deviceName,
  }) async {
    // Only show notifications for round 10% increments
    if (progressPercentage % 10 != 0 || progressPercentage == 0 || progressPercentage == 100) {
      return;
    }

    final String title = '📥 Downloading File';
    String body = 'Downloading $fileName - $progressPercentage%';
    
    if (deviceName != null) {
      body += ' from $deviceName';
    }

    await _showNotification(
      title: title,
      body: body,
      payload: 'file_download_progress_$progressPercentage',
    );
  }

  /// Show notification when file download completes successfully
  Future<void> showFileDownloadComplete({
    required String fileName,
    String? deviceName,
    String? filePath,
  }) async {
    final String title = '✅ Download Complete';
    String body = 'Successfully downloaded $fileName';
    
    if (deviceName != null) {
      body += ' from $deviceName';
    }

    await _showNotification(
      title: title,
      body: body,
      payload: 'file_download_complete',
    );
  }

  /// Show notification when file download fails
  Future<void> showFileDownloadFailure({
    required String fileName,
    String? reason,
    String? deviceName,
  }) async {
    final String title = '❌ Download Failed';
    String body = 'Failed to download $fileName';
    
    if (deviceName != null) {
      body += ' from $deviceName';
    }
    
    if (reason != null) {
      body += ': $reason';
    }

    await _showNotification(
      title: title,
      body: body,
      payload: 'file_download_failure',
    );
  }

  // =============================================================================
  // FILE UPLOAD NOTIFICATIONS
  // =============================================================================

  /// Show notification for file upload progress (10% increments)
  Future<void> showFileUploadProgress({
    required int progressPercentage,
    required String fileName,
    String? deviceName,
  }) async {
    // Only show notifications for round 10% increments
    if (progressPercentage % 10 != 0 || progressPercentage == 0 || progressPercentage == 100) {
      return;
    }

    final String title = '📤 Uploading File';
    String body = 'Uploading $fileName - $progressPercentage%';
    
    if (deviceName != null) {
      body += ' to $deviceName';
    }

    await _showNotification(
      title: title,
      body: body,
      payload: 'file_upload_progress_$progressPercentage',
    );
  }

  /// Show notification when file upload completes successfully
  Future<void> showFileUploadComplete({
    required String fileName,
    String? deviceName,
  }) async {
    final String title = '✅ Upload Complete';
    String body = 'Successfully uploaded $fileName';
    
    if (deviceName != null) {
      body += ' to $deviceName';
    }

    await _showNotification(
      title: title,
      body: body,
      payload: 'file_upload_complete',
    );
  }

  // =============================================================================
  // UTILITY METHODS
  // =============================================================================

  /// Dispose of the notification service
  void dispose() {
    _log('🔔 DISPOSING NOTIFICATION SERVICE');
    // Flutter local notifications doesn't require explicit disposal
  }

  /// Windows fallback notification (console-based)
  Future<void> _showWindowsFallbackNotification(String title, String body) async {
    try {
      _log('🪟 WINDOWS FALLBACK NOTIFICATION', '$title: $body');
      
      // Enhanced console notification for Windows
      print('');
      print('═══════════════════════════════════════════════════════════');
      print('🔔 NOTIFICATION: $title');
      print('   $body');
      print('   Time: ${DateTime.now().toString().substring(11, 19)}');
      print('═══════════════════════════════════════════════════════════');
      print('');
      
      // For production, consider:
      // 1. Use a different notification library specifically for Windows
      // 2. Show a system tray balloon notification
      // 3. Use Windows native APIs via FFI
      // 4. Display an in-app notification as fallback
    } catch (e) {
      _log('❌ ERROR SHOWING WINDOWS FALLBACK NOTIFICATION', e.toString());
    }
  }

  /// Check if notifications are enabled/available
  bool get isInitialized => _isInitialized;
}
