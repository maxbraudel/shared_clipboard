import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

class NativeFileClipboard {
  static const MethodChannel _channel = MethodChannel('native_file_clipboard');
  
  // Helper function for timestamped logging
  static void _log(String message, [dynamic data]) {
    final timestamp = DateTime.now().toIso8601String();
    if (data != null) {
      print('[$timestamp] NATIVE_FILE_CLIPBOARD: $message - $data');
    } else {
      print('[$timestamp] NATIVE_FILE_CLIPBOARD: $message');
    }
  }

  /// Puts files into the system clipboard so they can be pasted like regular file operations
  static Future<bool> putFilesToClipboard(List<dynamic> files) async {
    try {
      _log('📁 PUTTING FILES TO CLIPBOARD', '${files.length} files');
      
      // Create temporary directory for files
      final tempDir = await getTemporaryDirectory();
      final clipboardDir = Directory('${tempDir.path}/shared_clipboard_files');
      if (await clipboardDir.exists()) {
        await clipboardDir.delete(recursive: true);
      }
      await clipboardDir.create(recursive: true);
      
      List<String> filePaths = [];
      
      // Write all files to temporary directory
      for (var fileData in files) {
        final filePath = '${clipboardDir.path}/${fileData.name}';
        final file = File(filePath);
        await file.writeAsBytes(fileData.content);
        filePaths.add(filePath);
        _log('✅ FILE WRITTEN FOR CLIPBOARD', '${fileData.name} at $filePath');
      }
      
      // Use platform-specific method to put files in clipboard
      final success = await _putFilesToSystemClipboard(filePaths);
      
      if (success) {
        _log('✅ FILES SUCCESSFULLY PUT TO SYSTEM CLIPBOARD', '${filePaths.length} files');
        return true;
      } else {
        _log('❌ FAILED TO PUT FILES TO SYSTEM CLIPBOARD');
        return false;
      }
      
    } catch (e) {
      _log('❌ ERROR PUTTING FILES TO CLIPBOARD', e.toString());
      return false;
    }
  }
  
  /// Platform-specific implementation to put files in system clipboard
  static Future<bool> _putFilesToSystemClipboard(List<String> filePaths) async {
    try {
      if (Platform.isMacOS) {
        return await _putFilesToMacOSClipboard(filePaths);
      } else if (Platform.isWindows) {
        return await _putFilesToWindowsClipboard(filePaths);
      } else {
        _log('⚠️ PLATFORM NOT SUPPORTED FOR NATIVE FILE CLIPBOARD');
        return false;
      }
    } catch (e) {
      _log('❌ ERROR IN PLATFORM-SPECIFIC CLIPBOARD', e.toString());
      return false;
    }
  }
  
  /// Put files to macOS clipboard using NSPasteboard
  static Future<bool> _putFilesToMacOSClipboard(List<String> filePaths) async {
    try {
      _log('🍎 USING MACOS PASTEBOARD');
      
      final result = await _channel.invokeMethod('putFilesToMacOSClipboard', {
        'filePaths': filePaths,
      });
      
      return result == true;
    } catch (e) {
      _log('❌ ERROR WITH MACOS PASTEBOARD', e.toString());
      return false;
    }
  }
  
  /// Put files to Windows clipboard using CF_HDROP format
  static Future<bool> _putFilesToWindowsClipboard(List<String> filePaths) async {
    try {
      _log('🪟 USING WINDOWS CLIPBOARD');
      
      final result = await _channel.invokeMethod('putFilesToWindowsClipboard', {
        'filePaths': filePaths,
      });
      
      return result == true;
    } catch (e) {
      _log('❌ ERROR WITH WINDOWS CLIPBOARD', e.toString());
      return false;
    }
  }
  
  /// Clear the file clipboard
  static Future<void> clearFileClipboard() async {
    try {
      _log('🗑️ CLEARING FILE CLIPBOARD');
      
      if (Platform.isMacOS) {
        await _channel.invokeMethod('clearMacOSClipboard');
      } else if (Platform.isWindows) {
        await _channel.invokeMethod('clearWindowsClipboard');
      }
      
    } catch (e) {
      _log('❌ ERROR CLEARING FILE CLIPBOARD', e.toString());
    }
  }
}
