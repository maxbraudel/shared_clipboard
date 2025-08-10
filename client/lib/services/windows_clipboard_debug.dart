// ignore_for_file: constant_identifier_names
import 'dart:ffi';
import 'dart:io';
import 'package:shared_clipboard/core/logger.dart';

// Windows API constants for clipboard formats
const int CF_TEXT = 1;
const int CF_UNICODETEXT = 13;
const int CF_HDROP = 15;

class WindowsClipboardDebug {
  static final AppLogger _logger = logTag('WIN_CLIP_DEBUG');
  static void investigateClipboard() {
    if (!Platform.isWindows) {
      _logger.w('This debug tool only works on Windows');
      return;
    }

    try {
      _logger.i('Investigating Windows clipboard formats');
      
      // Load user32.dll for clipboard functions
      final user32 = DynamicLibrary.open('user32.dll');
      
      // Define function signatures
      final openClipboard = user32.lookupFunction<Int32 Function(IntPtr), int Function(int)>('OpenClipboard');
      final closeClipboard = user32.lookupFunction<Int32 Function(), int Function()>('CloseClipboard');
      final isClipboardFormatAvailable = user32.lookupFunction<Int32 Function(Int32), int Function(int)>('IsClipboardFormatAvailable');
      
      // Open clipboard
      if (openClipboard(0) == 0) {
        _logger.e('Failed to open clipboard');
        return;
      }
      
      _logger.i('Checking key clipboard formats');
      
      // Check if text is available
      if (isClipboardFormatAvailable(CF_TEXT) != 0) {
        _logger.i('CF_TEXT (ASCII text) - AVAILABLE');
      } else {
        _logger.i('CF_TEXT (ASCII text) - NOT AVAILABLE');
      }
      
      if (isClipboardFormatAvailable(CF_UNICODETEXT) != 0) {
        _logger.i('CF_UNICODETEXT (Unicode text) - AVAILABLE');
      } else {
        _logger.i('CF_UNICODETEXT (Unicode text) - NOT AVAILABLE');
      }
      
      if (isClipboardFormatAvailable(CF_HDROP) != 0) {
        _logger.i('CF_HDROP (File Drop) - AVAILABLE');
        _logger.i('Files are in clipboard');
      } else {
        _logger.i('CF_HDROP (File Drop) - NOT AVAILABLE');
      }
      
      closeClipboard();
      
    } catch (e, st) {
      _logger.e('Error investigating clipboard', e, st);
    }
  }
}
