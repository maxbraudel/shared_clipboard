import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';

// Windows API constants
const int CF_HDROP = 15;

class WindowsFileClipboard {
  static List<String>? getFilePaths() {
    if (!Platform.isWindows) return null;

    try {
      // Load required DLLs
      final user32 = DynamicLibrary.open('user32.dll');
      final kernel32 = DynamicLibrary.open('kernel32.dll');
      final shell32 = DynamicLibrary.open('shell32.dll');

      // Define function signatures
      final openClipboard = user32.lookupFunction<Int32 Function(IntPtr), int Function(int)>('OpenClipboard');
      final closeClipboard = user32.lookupFunction<Int32 Function(), int Function()>('CloseClipboard');
      final getClipboardData = user32.lookupFunction<IntPtr Function(Int32), int Function(int)>('GetClipboardData');
      final globalLock = kernel32.lookupFunction<Pointer Function(IntPtr), Pointer Function(int)>('GlobalLock');
      final globalUnlock = kernel32.lookupFunction<Int32 Function(IntPtr), int Function(int)>('GlobalUnlock');
      final dragQueryFileW = shell32.lookupFunction<
          Int32 Function(IntPtr, Int32, Pointer<Uint16>, Int32),
          int Function(int, int, Pointer<Uint16>, int)>('DragQueryFileW');

      // Open clipboard
      if (openClipboard(0) == 0) {
        print('❌ Failed to open clipboard for file reading');
        return null;
      }

      // Get HDROP handle
      final hDrop = getClipboardData(CF_HDROP);
      if (hDrop == 0) {
        print('❌ No HDROP data in clipboard');
        closeClipboard();
        return null;
      }

      // Lock the global memory
      final dropFiles = globalLock(hDrop);
      if (dropFiles == nullptr) {
        print('❌ Failed to lock HDROP memory');
        closeClipboard();
        return null;
      }

      // Get number of files
      final fileCount = dragQueryFileW(hDrop, 0xFFFFFFFF, nullptr, 0);
      print('📁 Found $fileCount files in clipboard');

      List<String> filePaths = [];

      // Get each file path
      for (int i = 0; i < fileCount; i++) {
        // Get required buffer size
        final bufferSize = dragQueryFileW(hDrop, i, nullptr, 0);
        if (bufferSize == 0) continue;

        // Allocate buffer and get file path
        final pathBuffer = calloc<Uint16>(bufferSize + 1);
        final actualSize = dragQueryFileW(hDrop, i, pathBuffer, bufferSize + 1);
        
        if (actualSize > 0) {
          // Convert UTF-16 to Dart string
          final filePath = _utf16ToString(pathBuffer, actualSize);
          filePaths.add(filePath);
          print('📄 File $i: $filePath');
        }
        
        calloc.free(pathBuffer);
      }

      // Cleanup
      globalUnlock(hDrop);
      closeClipboard();

      return filePaths;

    } catch (e) {
      print('❌ Error reading Windows file clipboard: $e');
      return null;
    }
  }

  // Helper function to convert UTF-16 pointer to Dart string
  static String _utf16ToString(Pointer<Uint16> ptr, int length) {
    final codeUnits = <int>[];
    for (int i = 0; i < length; i++) {
      final codeUnit = ptr[i];
      if (codeUnit == 0) break; // Null terminator
      codeUnits.add(codeUnit);
    }
    return String.fromCharCodes(codeUnits);
  }
}
