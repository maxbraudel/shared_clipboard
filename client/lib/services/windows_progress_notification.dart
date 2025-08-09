import 'dart:io';
import 'package:flutter/services.dart';

class WindowsProgressNotification {
  static const MethodChannel _channel = MethodChannel('windows_notifications');
  static bool _isInitialized = false;

  // Helper function for timestamped logging
  static void _log(String message, [dynamic data]) {
    final timestamp = DateTime.now().toIso8601String();
    if (data != null) {
      print('[$timestamp] WIN_NOTIFICATIONS: $message - $data');
    } else {
      print('[$timestamp] WIN_NOTIFICATIONS: $message');
    }
  }

  static Future<void> initializeWindows() async {
    if (!Platform.isWindows) {
      _log('⚠️ NOT WINDOWS PLATFORM, SKIPPING INITIALIZATION');
      return;
    }

    if (_isInitialized) {
      _log('✅ ALREADY INITIALIZED');
      return;
    }

    try {
      await _channel.invokeMethod('initialize');
      _isInitialized = true;
      _log('✅ WINDOWS NOTIFICATIONS INITIALIZED');
    } on PlatformException catch (e) {
      _log('❌ FAILED TO INITIALIZE WINDOWS NOTIFICATIONS', e.message);
    } catch (e) {
      _log('❌ UNEXPECTED ERROR DURING INITIALIZATION', e.toString());
    }
  }

  static Future<void> showProgressToast({
    required String title,
    required String subtitle,
    required int progress, // 0-100
    String? status,
    String? progressLabel,
  }) async {
    if (!Platform.isWindows || !_isInitialized) {
      _log('⚠️ WINDOWS NOTIFICATIONS NOT AVAILABLE');
      return;
    }

    try {
      await _channel.invokeMethod('showProgressToast', {
        'title': title,
        'subtitle': subtitle,
        'progress': progress.clamp(0, 100),
        'status': status ?? '',
        'progressLabel': progressLabel ?? 'Progress',
      });
      _log('📢 PROGRESS TOAST SHOWN', {
        'title': title,
        'progress': progress,
        'status': status
      });
    } on PlatformException catch (e) {
      _log('❌ FAILED TO SHOW PROGRESS TOAST', e.message);
    } catch (e) {
      _log('❌ UNEXPECTED ERROR SHOWING TOAST', e.toString());
    }
  }

  static Future<void> updateProgress({
    required int progress,
    String? status,
  }) async {
    if (!Platform.isWindows || !_isInitialized) {
      return;
    }

    try {
      await _channel.invokeMethod('updateProgress', {
        'progress': progress.clamp(0, 100),
        'status': status ?? '',
      });
      // Only log every 10% to avoid spam
      if (progress % 10 == 0) {
        _log('📊 PROGRESS UPDATED', {'progress': progress, 'status': status});
      }
    } on PlatformException catch (e) {
      _log('❌ FAILED TO UPDATE PROGRESS', e.message);
    } catch (e) {
      _log('❌ UNEXPECTED ERROR UPDATING PROGRESS', e.toString());
    }
  }

  static Future<void> hideToast() async {
    if (!Platform.isWindows || !_isInitialized) {
      return;
    }

    try {
      await _channel.invokeMethod('hideToast');
      _log('🔇 TOAST HIDDEN');
    } on PlatformException catch (e) {
      _log('❌ FAILED TO HIDE TOAST', e.message);
    } catch (e) {
      _log('❌ UNEXPECTED ERROR HIDING TOAST', e.toString());
    }
  }

  static Future<void> showCompletionToast({
    required String title,
    required String subtitle,
    String? message,
  }) async {
    if (!Platform.isWindows || !_isInitialized) {
      return;
    }

    try {
      await _channel.invokeMethod('showCompletionToast', {
        'title': title,
        'subtitle': subtitle,
        'message': message ?? 'Download completed successfully!',
      });
      _log('🎉 COMPLETION TOAST SHOWN', {'title': title, 'subtitle': subtitle});
    } on PlatformException catch (e) {
      _log('❌ FAILED TO SHOW COMPLETION TOAST', e.message);
    } catch (e) {
      _log('❌ UNEXPECTED ERROR SHOWING COMPLETION TOAST', e.toString());
    }
  }
}
