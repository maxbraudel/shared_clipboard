import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SettingsService with ChangeNotifier {
  SettingsService._internal();
  static final SettingsService _instance = SettingsService._internal();
  static SettingsService get instance => _instance;

  static const _kDisplayPipKey = 'display_download_progress_indicator';
  static const _kSendProgressNotificationsKey = 'send_download_progress_notifications';

  bool _displayPip = true;
  bool _sendProgressNotifications = true;
  bool _initialized = false;

  bool get isInitialized => _initialized;

  bool get displayDownloadProgressIndicator => _displayPip;
  set displayDownloadProgressIndicator(bool value) {
    if (_displayPip != value) {
      _displayPip = value;
      _saveBool(_kDisplayPipKey, value);
      notifyListeners();
    }
  }

  bool get sendDownloadProgressNotifications => _sendProgressNotifications;
  set sendDownloadProgressNotifications(bool value) {
    if (_sendProgressNotifications != value) {
      _sendProgressNotifications = value;
      _saveBool(_kSendProgressNotificationsKey, value);
      notifyListeners();
    }
  }

  Future<void> init() async {
    if (_initialized) return;
    final prefs = await SharedPreferences.getInstance();
    _displayPip = prefs.getBool(_kDisplayPipKey) ?? true;
    _sendProgressNotifications = prefs.getBool(_kSendProgressNotificationsKey) ?? true;
    _initialized = true;
    notifyListeners();
  }

  Future<void> _saveBool(String key, bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(key, value);
  }
}
