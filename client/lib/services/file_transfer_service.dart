import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:mime/mime.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';

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
      // On Windows/macOS, file paths might be in clipboard as text
      final clipboardData = await Clipboard.getData(Clipboard.kTextPlain);
      if (clipboardData?.text == null) return false;
      
      final text = clipboardData!.text!;
      
      // Check if text looks like file paths
      if (_looksLikeFilePaths(text)) {
        _log('📁 DETECTED POTENTIAL FILE PATHS IN CLIPBOARD');
        return true;
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
    
    // Check if all lines look like file paths
    if (lines.isEmpty) return false;
    
    for (String line in lines) {
      // Windows: C:\path\to\file or D:\folder\file.txt
      // macOS: /Users/username/file.txt or /Applications/app.app
      if (!RegExp(r'^([a-zA-Z]:\\|/).*').hasMatch(line)) {
        return false;
      }
      
      // Check if file exists
      final file = File(line);
      if (!file.existsSync()) {
        return false;
      }
    }
    
    return lines.length <= 10; // Limit to 10 files
  }

  // Get clipboard content (text or files)
  Future<ClipboardContent> getClipboardContent() async {
    try {
      final clipboardData = await Clipboard.getData(Clipboard.kTextPlain);
      if (clipboardData?.text == null) {
        return ClipboardContent.text('');
      }
      
      final text = clipboardData!.text!;
      
      // Check if it's file paths
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
      
      for (String filePath in lines) {
        if (files.length >= 10) break; // Limit to 10 files
        
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

  // Set files to clipboard (create temp files and set paths)
  Future<void> _setFiles(List<FileData> files) async {
    try {
      // Create temporary directory for received files
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
        // Set file paths to clipboard as text (user can then navigate to open them)
        final pathsText = filePaths.join('\n');
        await Clipboard.setData(ClipboardData(text: pathsText));
        _log('✅ FILE PATHS SET TO CLIPBOARD', '${filePaths.length} files');
        
        // Also show a notification-style message
        _showFileReceivedMessage(files.length, receivedDir.path);
      }
    } catch (e) {
      _log('❌ ERROR SETTING FILES TO CLIPBOARD', e.toString());
    }
  }

  void _showFileReceivedMessage(int fileCount, String dirPath) {
    print('\n🎉 FILES RECEIVED SUCCESSFULLY! 🎉');
    print('📁 $fileCount file(s) saved to: $dirPath');
    print('📋 File paths copied to clipboard');
    print('💡 You can now paste to see the file paths or navigate to the folder\n');
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
