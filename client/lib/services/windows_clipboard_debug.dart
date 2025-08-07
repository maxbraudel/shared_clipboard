import 'dart:ffi';
import 'dart:io';

// Windows API constants for clipboard formats
const int CF_TEXT = 1;
const int CF_UNICODETEXT = 13;
const int CF_HDROP = 15;

class WindowsClipboardDebug {
  static void investigateClipboard() {
    if (!Platform.isWindows) {
      print('❌ This debug tool only works on Windows');
      return;
    }

    try {
      print('🔍 INVESTIGATING WINDOWS CLIPBOARD FORMATS');
      
      // Load user32.dll for clipboard functions
      final user32 = DynamicLibrary.open('user32.dll');
      
      // Define function signatures
      final openClipboard = user32.lookupFunction<Int32 Function(IntPtr), int Function(int)>('OpenClipboard');
      final closeClipboard = user32.lookupFunction<Int32 Function(), int Function()>('CloseClipboard');
      final isClipboardFormatAvailable = user32.lookupFunction<Int32 Function(Int32), int Function(int)>('IsClipboardFormatAvailable');
      
      // Open clipboard
      if (openClipboard(0) == 0) {
        print('❌ Failed to open clipboard');
        return;
      }
      
      print('📋 CHECKING KEY CLIPBOARD FORMATS:');
      
      // Check if text is available
      if (isClipboardFormatAvailable(CF_TEXT) != 0) {
        print('✅ CF_TEXT (ASCII text) - AVAILABLE');
      } else {
        print('❌ CF_TEXT (ASCII text) - NOT AVAILABLE');
      }
      
      if (isClipboardFormatAvailable(CF_UNICODETEXT) != 0) {
        print('✅ CF_UNICODETEXT (Unicode text) - AVAILABLE');
      } else {
        print('❌ CF_UNICODETEXT (Unicode text) - NOT AVAILABLE');
      }
      
      if (isClipboardFormatAvailable(CF_HDROP) != 0) {
        print('✅ CF_HDROP (File Drop) - AVAILABLE');
        print('🎯 FILES ARE IN CLIPBOARD!');
      } else {
        print('❌ CF_HDROP (File Drop) - NOT AVAILABLE');
      }
      
      closeClipboard();
      
    } catch (e) {
      print('❌ Error investigating clipboard: $e');
    }
  }
}
