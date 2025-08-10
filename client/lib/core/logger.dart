import 'dart:developer' as developer;
import 'package:flutter/foundation.dart';

/// Lightweight app logger with level support and optional tagging.
/// Uses debugPrint in debug/profile and developer.log in release.
class AppLogger {
  final String tag;
  const AppLogger(this.tag);

  static const bool enableInRelease = true; // set false to silence in release

  void _emit(String level, String message, [Object? data, StackTrace? st]) {
    final ts = DateTime.now().toIso8601String();
    final payload = data != null ? ' - $data' : '';
    final line = '[$ts] $tag: $message$payload';
    if (kReleaseMode) {
      if (enableInRelease) {
        developer.log(line, name: tag, error: data, stackTrace: st, level: _levelToInt(level));
      }
    } else {
      debugPrint(line);
      if (st != null) {
        debugPrint(st.toString());
      }
    }
  }

  int _levelToInt(String level) {
    switch (level) {
      case 'E':
        return 1000;
      case 'W':
        return 900;
      case 'D':
        return 500;
      case 'I':
      default:
        return 800;
    }
  }

  void i(String message, [Object? data]) => _emit('I', message, data);
  void d(String message, [Object? data]) => _emit('D', message, data);
  void w(String message, [Object? data]) => _emit('W', message, data);
  void e(String message, [Object? data, StackTrace? st]) => _emit('E', message, data, st);
}

/// Convenience factory for tagged loggers
AppLogger logTag(String tag) => AppLogger(tag);
