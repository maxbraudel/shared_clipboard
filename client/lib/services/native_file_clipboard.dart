import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_clipboard/core/logger.dart';

class NativeFileClipboard {
  static const MethodChannel _channel = MethodChannel('native_file_clipboard');
  static final AppLogger _logger = logTag('NATIVE_CLIP');
  
  // Helper function for timestamped logging
  static void _log(String message, [dynamic data]) {
    if (data != null) {
      _logger.i(message, data);
    } else {
      _logger.i(message);
    }
  }

  /// Debug utility: dumps detailed clipboard info from macOS into the terminal logs
  static Future<void> debugDumpClipboard() async {
    if (!Platform.isMacOS) return;
    _log('🐞 DEBUG DUMP — BEGIN');
    try {
      // 1) Raw clipboard info (type codes)
      final info = await Process.run('osascript', ['-e', 'clipboard info']);
      _log('clipboard info', info.stdout);
    } catch (e) {
      _log('clipboard info error', e.toString());
    }
    try {
      // 2) Attempt to coerce clipboard to list and show class + possible POSIX path per item
      const classesScript = r'''
        try
          set itemsList to the clipboard as list
          set out to ""
          repeat with it in itemsList
            set cls to (class of it) as text
            set p to ""
            try
              set p to POSIX path of it
            end try
            set out to out & cls & ": " & p & "\n"
          end repeat
          return out
        on error
          return "(cannot coerce clipboard to list)"
        end try
      ''';
      final classes = await Process.run('osascript', ['-e', classesScript]);
      _log('clipboard as list — classes/paths', classes.stdout);
    } catch (e) {
      _log('clipboard as list error', e.toString());
    }
    try {
      // 3) Plain text view via pbpaste (may be empty if not textual)
      final txt = await Process.run('pbpaste', ['-Prefer', 'txt']);
      final preview = (txt.stdout is String) ? (txt.stdout as String) : '';
      _log('pbpaste -Prefer txt (first 500 chars)', preview.length > 500 ? preview.substring(0, 500) : preview);
    } catch (e) {
      _log('pbpaste error', e.toString());
    }
    _log('🐞 DEBUG DUMP — END');
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
        _log('🎉 FILES ARE NOW PASTEABLE LIKE FROM FINDER!');
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
        // TODO: Implement Windows native clipboard
        _log('⚠️ WINDOWS NATIVE CLIPBOARD NOT YET IMPLEMENTED');
        return false;
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
      
      final result = await _channel.invokeMethod('putFilesToClipboard', {
        'filePaths': filePaths,
      });
      
      return result == true;
    } catch (e) {
      _log('❌ ERROR WITH MACOS PASTEBOARD', e.toString());
      return false;
    }
  }
  
  /// Clear the file clipboard
  static Future<void> clearFileClipboard() async {
    try {
      _log('🗑️ CLEARING FILE CLIPBOARD');
      
      await _channel.invokeMethod('clearClipboard');
      
    } catch (e) {
      _log('❌ ERROR CLEARING FILE CLIPBOARD', e.toString());
    }
  }

  /// Returns file paths currently in the system clipboard on macOS
  static Future<List<String>> getFilesFromClipboard() async {
    try {
      if (!Platform.isMacOS) return [];
      // Always dump clipboard details for diagnostics
      await debugDumpClipboard();
      // 0) First, explicitly coerce clipboard to file URL (furl) and read POSIX path
      const furlScript = r'''
        try
          set u to the clipboard as «class furl»
          try
            return POSIX path of u
          on error
            try
              tell application "System Events" to return POSIX path of (u as alias)
            on error
              return ""
            end try
          end try
        on error
          return ""
        end try
      ''';
      final furlRes = await Process.run('osascript', ['-e', furlScript]);
      if (furlRes.exitCode == 0 && furlRes.stdout is String) {
        final p = (furlRes.stdout as String).trim();
        if (p.isNotEmpty) {
          _log('🍎 AppleScript (furl) detected file', p);
          return [p];
        }
      }
      // NEW APPROACH: Prefer AppleScript path that doesn't depend on native plugin registration
      // 1) Attempt to coerce clipboard to a list of aliases and extract multiple file paths
      const multiScript = r'''
        try
          set paths to {}
          set itemsList to the clipboard as list
          repeat with it in itemsList
            try
              set end of paths to POSIX path of it
            end try
          end repeat
          set AppleScript's text item delimiters to "\n"
          return paths as text
        on error
          return ""
        end try
      ''';
      final multiRes = await Process.run('osascript', ['-e', multiScript]);
      if (multiRes.exitCode == 0 && multiRes.stdout is String) {
        final out = (multiRes.stdout as String).trim();
        if (out.isNotEmpty) {
          final files = out.split('\n').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
          if (files.isNotEmpty) {
            _log('🍎 AppleScript (multi) detected files', files);
            return files;
          }
        }
      }

      // 2) If multi-file coercion failed, check clipboard info for file URLs and extract single alias path
      final detect = await Process.run('osascript', ['-e', 'clipboard info']);
      if (detect.exitCode == 0 && detect.stdout is String && (detect.stdout as String).contains('«class furl»')) {
        const singleScript = r'''
          try
            set p to POSIX path of (the clipboard as alias)
            return p
          on error
            return ""
          end try
        ''';
        final res = await Process.run('osascript', ['-e', singleScript]);
        if (res.exitCode == 0) {
          final path = (res.stdout as String).trim();
          if (path.isNotEmpty) {
            _log('🍎 AppleScript (single) detected file', path);
            return [path];
          }
        }
      }

      // 3) As a secondary path, try the native channel if available (may be empty if not registered)
      try {
        final dynamic result = await _channel.invokeMethod('getFilesFromClipboard');
        if (result is List && result.isNotEmpty) {
          return result.map((e) => e.toString()).toList();
        }
      } catch (_) {
        // Ignore; plugin may not be registered
      }

      return [];
    } catch (e) {
      _log('❌ ERROR GETTING FILES FROM CLIPBOARD', e.toString());
      return [];
    }
  }
}