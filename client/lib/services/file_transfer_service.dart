import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:mime/mime.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_clipboard/services/windows_clipboard_debug.dart';
import 'package:shared_clipboard/services/windows_file_clipboard.dart';
import 'package:shared_clipboard/services/native_file_clipboard.dart';

class FileTransferService {
  static const int MAX_FILE_SIZE = 50 * 1024 * 1024; // 50MB limit for safety
  
  // Helper function for timestamped logging
  void _log(String message, [dynamic data]) {
    final timestamp = DateTime.now().toIso8601String();
    if (data != null) {
      print('[$timestamp] FILE_TRANSFER: $message - $data');
    } else {
      print('[$timestamp] FILE_TRANSFER: $message');
    }
  }

  // Check if clipboard contains files (basic detection)
  Future<bool> hasFiles() async {
    try {
      // First check for text that might be file paths
      final clipboardData = await Clipboard.getData(Clipboard.kTextPlain);
      if (clipboardData?.text != null) {
        final text = clipboardData!.text!;
        if (_looksLikeFilePaths(text)) {
          _log('📁 DETECTED POTENTIAL FILE PATHS IN CLIPBOARD');
          return true;
        }
      }
      
      // On Windows, files copied from Explorer don't appear as text
      // We need to check platform-specific clipboard formats
      if (Platform.isWindows) {
        _log('🪟 CHECKING WINDOWS FILE CLIPBOARD');
        // For now, we'll try a different approach - check if clipboard is empty of text
        // but might contain files (this is a limitation of the basic Clipboard API)
        return false; // We'll handle this in getClipboardContent
      }
      
      return false;
    } catch (e) {
      _log('❌ ERROR CHECKING FOR FILES', e.toString());
      return false;
    }
  }

  // Check if text contains file paths
  bool _looksLikeFilePaths(String text) {
    final lines = text.split('\n').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    
    _log('🔍 ANALYZING TEXT FOR FILE PATHS', {
      'lineCount': lines.length,
      'lines': lines.take(3).toList() // Show first 3 lines for debugging
    });
    
    // Check if all lines look like file paths
    if (lines.isEmpty) return false;
    if (lines.length > 10) return false; // Limit to 10 files
    
    int validFileCount = 0;
    int pathLikeCount = 0;
    
    for (String line in lines) {
      // Windows: C:\path\to\file or D:\folder\file.txt
      // macOS: /Users/username/file.txt or /Applications/app.app
      // Also handle quotes around paths: "C:\Program Files\file.txt"
      String cleanPath = line.replaceAll('"', '').trim();
      
      // Check if it looks like a path
      bool looksLikePath = false;
      if (Platform.isWindows) {
        // Windows paths: C:\, D:\, \\server\share, etc.
        looksLikePath = RegExp(r'^([a-zA-Z]:\\|\\\\).*').hasMatch(cleanPath);
      } else {
        // Unix-like paths: /path/to/file
        looksLikePath = RegExp(r'^/.*').hasMatch(cleanPath);
      }
      
      if (looksLikePath) {
        pathLikeCount++;
        
        // Check if file exists
        final file = File(cleanPath);
        if (file.existsSync()) {
          validFileCount++;
          _log('✅ VALID FILE FOUND', cleanPath);
        } else {
          _log('❌ FILE DOES NOT EXIST', cleanPath);
        }
      }
    }
    
    _log('📊 FILE PATH ANALYSIS RESULTS', {
      'totalLines': lines.length,
      'pathLikeCount': pathLikeCount,
      'validFileCount': validFileCount,
      'threshold': (lines.length * 0.7).ceil()
    });
    
    // Consider it file paths if at least one valid file found and most lines look like paths
    bool isFilePaths = validFileCount > 0 && pathLikeCount >= (lines.length * 0.7).ceil();
    _log('🎯 FILE PATH DETECTION RESULT', isFilePaths);
    
    return isFilePaths;
  }

  // Get clipboard content (text or files)
  Future<ClipboardContent> getClipboardContent() async {
    try {
      // First, let's investigate what's actually in the Windows clipboard
      if (Platform.isWindows) {
        WindowsClipboardDebug.investigateClipboard();
      }
      
      final clipboardData = await Clipboard.getData(Clipboard.kTextPlain);
      
      _log('📋 RAW CLIPBOARD DATA', {
        'hasData': clipboardData != null,
        'text': clipboardData?.text,
        'textLength': clipboardData?.text?.length ?? 0,
        'isEmpty': clipboardData?.text?.isEmpty ?? true
      });
      
      if (clipboardData?.text == null || clipboardData!.text!.isEmpty) {
        _log('📋 EMPTY TEXT CLIPBOARD');
        
        // On Windows, check if files are available in CF_HDROP format
        if (Platform.isWindows) {
          _log('🪟 WINDOWS: CHECKING FOR FILES IN CF_HDROP FORMAT');
          final filePaths = WindowsFileClipboard.getFilePaths();
          
          if (filePaths != null && filePaths.isNotEmpty) {
            _log('✅ FOUND FILES IN WINDOWS CLIPBOARD', filePaths);
            // Convert file paths to ClipboardContent with files
            return await _processFilePaths(filePaths.join('\n'));
          } else {
            _log('❌ NO FILES FOUND IN WINDOWS CLIPBOARD');
          }
        }
        
        return ClipboardContent.text('');
      }
      
      final text = clipboardData.text!;
      _log('📋 CLIPBOARD TEXT CONTENT', text.length > 100 ? '${text.substring(0, 100)}...' : text);
      
      // Check if it's file paths (works on Windows and macOS when paths are in text)
      if (_looksLikeFilePaths(text)) {
        _log('📁 PROCESSING FILE PATHS FROM CLIPBOARD');
        return await _processFilePaths(text);
      }
      
      // Regular text
      _log('📝 CLIPBOARD CONTAINS TEXT');
      return ClipboardContent.text(text);
    } catch (e) {
      _log('❌ ERROR READING CLIPBOARD', e.toString());
      return ClipboardContent.text('');
    }
  }

  // Process file paths from clipboard text
  Future<ClipboardContent> _processFilePaths(String text) async {
    try {
      final lines = text.split('\n').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
      List<FileData> files = [];
      
      for (String line in lines) {
        if (files.length >= 10) break; // Limit to 10 files
        
        // Clean the path (remove quotes if present)
        String filePath = line.replaceAll('"', '').trim();
        
        final file = File(filePath);
        if (!await file.exists()) {
          _log('⚠️ FILE DOES NOT EXIST', filePath);
          continue;
        }
        
        final stat = await file.stat();
        if (stat.size > MAX_FILE_SIZE) {
          _log('⚠️ FILE TOO LARGE, SKIPPING', '$filePath (${stat.size} bytes)');
          continue;
        }
        
        _log('📄 PROCESSING FILE', '$filePath (${stat.size} bytes)');
        
        final bytes = await file.readAsBytes();
        final mimeType = lookupMimeType(file.path) ?? 'application/octet-stream';
        final checksum = sha256.convert(bytes).toString();
        
        // Get just the filename for cross-platform compatibility
        final fileName = file.path.split(Platform.pathSeparator).last;
        
        files.add(FileData(
          name: fileName,
          path: file.path,
          size: stat.size,
          mimeType: mimeType,
          checksum: checksum,
          content: bytes,
        ));
        
        _log('✅ FILE PROCESSED', '$fileName (${mimeType})');
      }
      
      if (files.isEmpty) {
        return ClipboardContent.text('No valid files found');
      }
      
      return ClipboardContent.files(files);
    } catch (e) {
      _log('❌ ERROR PROCESSING FILE PATHS', e.toString());
      return ClipboardContent.text('Error processing files: $e');
    }
  }

  // Set clipboard content (text or files)
  Future<void> setClipboardContent(ClipboardContent content) async {
    try {
      if (content.isFiles) {
        _log('📁 SETTING FILES TO CLIPBOARD', '${content.files.length} files');
        await _setFiles(content.files);
      } else {
        _log('📝 SETTING TEXT TO CLIPBOARD');
        await Clipboard.setData(ClipboardData(text: content.text));
      }
    } catch (e) {
      _log('❌ ERROR SETTING CLIPBOARD', e.toString());
    }
  }

  // Set files to clipboard (put files directly in system clipboard for proper paste behavior)
  Future<void> _setFiles(List<FileData> files) async {
    try {
      _log('📁 SETTING FILES TO SYSTEM CLIPBOARD', '${files.length} files');
      
      // Try native clipboard first (this puts actual files in clipboard!)
      final success = await NativeFileClipboard.putFilesToClipboard(files);
      
      if (success) {
        _log('🎉 FILES SET TO NATIVE CLIPBOARD SUCCESSFULLY!');
        _showFileReceivedMessage(files.length, 'native clipboard - ready to paste!');
        return;
      } else {
        _log('⚠️ NATIVE CLIPBOARD FAILED, FALLING BACK TO FILE PATHS');
      }
      
      // Fallback: Create temporary directory for received files and set paths
      final tempDir = await getTemporaryDirectory();
      final receivedDir = Directory('${tempDir.path}/shared_clipboard_received');
      if (!await receivedDir.exists()) {
        await receivedDir.create(recursive: true);
      }
      
      List<String> filePaths = [];
      
      for (FileData fileData in files) {
        // Create file in temp directory
        final filePath = '${receivedDir.path}/${fileData.name}';
        final file = File(filePath);
        
        // Write file content
        await file.writeAsBytes(fileData.content);
        
        // Verify checksum
        final writtenBytes = await file.readAsBytes();
        final writtenChecksum = sha256.convert(writtenBytes).toString();
        
        if (writtenChecksum != fileData.checksum) {
          _log('❌ CHECKSUM MISMATCH', fileData.name);
          await file.delete();
          continue;
        }
        
        filePaths.add(filePath);
        _log('✅ FILE WRITTEN', '${fileData.name} (${fileData.size} bytes)');
      }
      
      if (filePaths.isNotEmpty) {
        // Fallback: Set file paths to clipboard as text
        final pathsText = filePaths.join('\n');
        await Clipboard.setData(ClipboardData(text: pathsText));
        _log('📋 FALLBACK: FILE PATHS SET TO CLIPBOARD AS TEXT', '${filePaths.length} files');
        
        _showFileReceivedMessage(files.length, receivedDir.path);
      }
    } catch (e) {
      _log('❌ ERROR SETTING FILES TO CLIPBOARD', e.toString());
    }
  }

  void _showFileReceivedMessage(int fileCount, String dirPath) {
    print('\n🎉 FILES RECEIVED SUCCESSFULLY! 🎉');
    print('📁 $fileCount file(s) saved to: $dirPath');
    print('📋 CURRENT LIMITATION: File paths copied to clipboard as text');
    print('💡 When you paste (Cmd+V), you\'ll see the file paths instead of files');
    print('� To access files: Navigate to the paths shown when you paste');
    print('🔮 GOAL: Enable direct file pasting (like copy/paste from Finder)');
    print('');
  }

  // Serialize clipboard content for transfer
  String serializeClipboardContent(ClipboardContent content) {
    try {
      if (content.isFiles) {
        _log('📦 SERIALIZING FILES', '${content.files.length} files');
        
        // Split large files into chunks if needed
        Map<String, dynamic> data = {
          'type': 'files',
          'files': content.files.map((f) => f.toJson()).toList(),
        };
        
        final serialized = jsonEncode(data);
        _log('📦 SERIALIZATION COMPLETE', '${serialized.length} bytes');
        return serialized;
      } else {
        _log('📦 SERIALIZING TEXT');
        return jsonEncode({
          'type': 'text',
          'content': content.text,
        });
      }
    } catch (e) {
      _log('❌ ERROR SERIALIZING CONTENT', e.toString());
      return jsonEncode({'type': 'text', 'content': 'Error serializing content'});
    }
  }

  // Deserialize clipboard content from transfer
  ClipboardContent deserializeClipboardContent(String data) {
    try {
      final json = jsonDecode(data) as Map<String, dynamic>;
      
      if (json['type'] == 'files') {
        _log('📦 DESERIALIZING FILES');
        final filesJson = json['files'] as List;
        final files = filesJson.map((f) => FileData.fromJson(f)).toList();
        return ClipboardContent.files(files);
      } else {
        _log('📦 DESERIALIZING TEXT');
        return ClipboardContent.text(json['content'] ?? '');
      }
    } catch (e) {
      _log('❌ ERROR DESERIALIZING CONTENT', e.toString());
      return ClipboardContent.text('Error deserializing content');
    }
  }

  // Manual file selection for sharing
  Future<ClipboardContent> selectFilesToShare() async {
    try {
      _log('📁 OPENING FILE PICKER');
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        type: FileType.any,
        withData: false, // We'll read the files ourselves for better control
      );
      
      if (result == null || result.files.isEmpty) {
        _log('⚠️ NO FILES SELECTED');
        return ClipboardContent.text('No files selected');
      }
      
      List<FileData> files = [];
      
      for (var platformFile in result.files) {
        if (files.length >= 10) break; // Limit to 10 files
        
        if (platformFile.path == null) {
          _log('⚠️ FILE PATH IS NULL', platformFile.name);
          continue;
        }
        
        final file = File(platformFile.path!);
        if (!await file.exists()) {
          _log('⚠️ FILE DOES NOT EXIST', platformFile.path);
          continue;
        }
        
        final stat = await file.stat();
        if (stat.size > MAX_FILE_SIZE) {
          _log('⚠️ FILE TOO LARGE, SKIPPING', '${platformFile.name} (${stat.size} bytes)');
          continue;
        }
        
        _log('📄 PROCESSING SELECTED FILE', '${platformFile.name} (${stat.size} bytes)');
        
        final bytes = await file.readAsBytes();
        final mimeType = lookupMimeType(file.path) ?? 'application/octet-stream';
        final checksum = sha256.convert(bytes).toString();
        
        files.add(FileData(
          name: platformFile.name,
          path: file.path,
          size: stat.size,
          mimeType: mimeType,
          checksum: checksum,
          content: bytes,
        ));
        
        _log('✅ SELECTED FILE PROCESSED', '${platformFile.name} (${mimeType})');
      }
      
      if (files.isEmpty) {
        return ClipboardContent.text('No valid files selected');
      }
      
      return ClipboardContent.files(files);
    } catch (e) {
      _log('❌ ERROR SELECTING FILES', e.toString());
      return ClipboardContent.text('Error selecting files: $e');
    }
  }
}

// Data classes for clipboard content
class ClipboardContent {
  final String text;
  final List<FileData> files;
  final bool isFiles;

  ClipboardContent.text(this.text) : files = [], isFiles = false;
  ClipboardContent.files(this.files) : text = '', isFiles = true;
  
  @override
  String toString() {
    if (isFiles) {
      return 'ClipboardContent(${files.length} files: ${files.map((f) => f.name).join(', ')})';
    } else {
      return 'ClipboardContent(text: ${text.length} chars)';
    }
  }
}

class FileData {
  final String name;
  final String path;
  final int size;
  final String mimeType;
  final String checksum;
  final Uint8List content;

  FileData({
    required this.name,
    required this.path,
    required this.size,
    required this.mimeType,
    required this.checksum,
    required this.content,
  });

  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'path': path,
      'size': size,
      'mimeType': mimeType,
      'checksum': checksum,
      'content': base64Encode(content),
    };
  }

  static FileData fromJson(Map<String, dynamic> json) {
    return FileData(
      name: json['name'],
      path: json['path'],
      size: json['size'],
      mimeType: json['mimeType'],
      checksum: json['checksum'],
      content: base64Decode(json['content']),
    );
  }
  
  @override
  String toString() {
    return 'FileData(name: $name, size: $size, mimeType: $mimeType)';
  }
}
