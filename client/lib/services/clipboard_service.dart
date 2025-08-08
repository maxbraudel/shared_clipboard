import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:shared_clipboard/services/socket_service.dart';
import 'package:shared_clipboard/services/webrtc_service.dart';


class ClipboardService {
  late SocketService _socketService;
  late WebRTCService _webrtcService;

  void init() async {
    _socketService = SocketService();
    _webrtcService = WebRTCService(socketService: _socketService);
    _socketService.init(webrtcService: _webrtcService);
    _webrtcService.init();
    // Must add this line.
    await hotKeyManager.unregisterAll();
    _registerHotkeys();
  }

  void _registerHotkeys() async {
    await hotKeyManager.register(
      HotKey(
        key: LogicalKeyboardKey.f12,
        modifiers: [HotKeyModifier.control, HotKeyModifier.meta],
      ),
      keyDownHandler: (hotKey) {
        shareClipboard();
      },
    );

    await hotKeyManager.register(
      HotKey(
        key: LogicalKeyboardKey.f11,
        modifiers: [HotKeyModifier.control, HotKeyModifier.meta],
      ),
      keyDownHandler: (hotKey) {
        requestClipboard();
      },
    );
  }

  void shareClipboard() async {
    print("Sharing clipboard content");
    _socketService.sendShareReady();
  }

  void requestClipboard() {
    print("Requesting clipboard content");
    // Defensive: ensure we're not advertised as ready-to-share while requesting
    _socketService.clearShareReady();
    _socketService.sendRequestShare();
  }

  void dispose() {
    hotKeyManager.unregisterAll();
  }
}
