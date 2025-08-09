import 'dart:io';
import 'package:windows_taskbar/windows_taskbar.dart';

class _DownloadInfo {
  final String fileName;
  final int totalBytes;
  int receivedBytes;
  DateTime startTime;
  
  _DownloadInfo({
    required this.fileName,
    required this.totalBytes,
    this.receivedBytes = 0,
  }) : startTime = DateTime.now();
}

class NotificationService {
  static bool _isInitialized = false;
  static final Map<String, _DownloadInfo> _activeDownloads = {};
  static String? _currentDownloadSession;

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
      _isInitialized = true;
      _log('✅ NOTIFICATION SERVICE INITIALIZED (Windows Taskbar Mode)');
    } catch (e) {
      _log('❌ FAILED TO INITIALIZE NOTIFICATION SERVICE', e.toString());
    }
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
      final downloadInfo = _DownloadInfo(
        fileName: fileName,
        totalBytes: totalBytes,
      );
      _activeDownloads[sessionId] = downloadInfo;
      _currentDownloadSession = sessionId;

      final sizeText = totalBytes > 0 
          ? ' (${_formatBytes(totalBytes)})'
          : '';

      // Set taskbar progress to indeterminate initially
      await WindowsTaskbar.setProgressMode(TaskbarProgressMode.indeterminate);
      
      _log('📥 DOWNLOAD STARTED', {
        'fileName': fileName,
        'sessionId': sessionId,
        'totalBytes': totalBytes,
      });
      
      print('\n🔽 Starting download: $fileName$sizeText');
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

    final downloadInfo = _activeDownloads[sessionId];
    if (downloadInfo == null) {
      return;
    }

    try {
      downloadInfo.receivedBytes = receivedBytes;
      
      final progress = totalBytes > 0 ? (receivedBytes / totalBytes * 100).round() : 0;
      final progressText = totalBytes > 0 
          ? '${_formatBytes(receivedBytes)} / ${_formatBytes(totalBytes)}'
          : '${_formatBytes(receivedBytes)} received';

      // Update taskbar progress if this is the current download
      if (_currentDownloadSession == sessionId && totalBytes > 0) {
        await WindowsTaskbar.setProgressMode(TaskbarProgressMode.normal);
        await WindowsTaskbar.setProgress(receivedBytes, totalBytes);
      }

      // Only log and print every 10% to avoid spam
      if (progress % 10 == 0 || progress >= 100) {
        _log('📊 DOWNLOAD PROGRESS UPDATED', {
          'fileName': fileName,
          'sessionId': sessionId,
          'progress': progress,
          'receivedBytes': receivedBytes,
          'totalBytes': totalBytes,
        });
        
        print('📊 $fileName: $progress% ($progressText)');
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

    final downloadInfo = _activeDownloads.remove(sessionId);
    if (downloadInfo == null) {
      return;
    }

    try {
      final sizeText = totalBytes > 0 ? ' (${_formatBytes(totalBytes)})' : '';
      final duration = DateTime.now().difference(downloadInfo.startTime);
      final durationText = _formatDuration(duration);

      // Clear taskbar progress if this was the current download
      if (_currentDownloadSession == sessionId) {
        await WindowsTaskbar.setProgressMode(TaskbarProgressMode.noProgress);
        _currentDownloadSession = null;
      }

      _log('✅ DOWNLOAD COMPLETED', {
        'fileName': fileName,
        'sessionId': sessionId,
        'totalBytes': totalBytes,
        'duration': durationText,
      });
      
      print('✅ Download complete: $fileName$sizeText (took $durationText)');
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

    final downloadInfo = _activeDownloads.remove(sessionId);
    if (downloadInfo == null) {
      return;
    }

    try {
      // Clear taskbar progress if this was the current download
      if (_currentDownloadSession == sessionId) {
        await WindowsTaskbar.setProgressMode(TaskbarProgressMode.noProgress);
        _currentDownloadSession = null;
      }
      
      _log('🛑 DOWNLOAD CANCELLED', {
        'fileName': fileName,
        'sessionId': sessionId,
      });
      
      print('🛑 Download cancelled: $fileName');
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

  /// Format duration to human readable format
  static String _formatDuration(Duration duration) {
    if (duration.inSeconds < 60) {
      return '${duration.inSeconds}s';
    } else if (duration.inMinutes < 60) {
      return '${duration.inMinutes}m ${duration.inSeconds % 60}s';
    } else {
      return '${duration.inHours}h ${duration.inMinutes % 60}m';
    }
  }

  /// Clear all active download notifications
  static Future<void> clearAllDownloadNotifications() async {
    if (!_isInitialized || !Platform.isWindows) {
      return;
    }

    try {
      _activeDownloads.clear();
      await WindowsTaskbar.setProgressMode(TaskbarProgressMode.noProgress);
      _currentDownloadSession = null;
      
      _log('🧹 ALL DOWNLOAD NOTIFICATIONS CLEARED');
    } catch (e) {
      _log('❌ FAILED TO CLEAR DOWNLOAD NOTIFICATIONS', e.toString());
    }
  }
}
