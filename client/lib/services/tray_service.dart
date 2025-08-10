import 'package:system_tray/system_tray.dart';
import 'package:window_manager/window_manager.dart';
import 'dart:io';
import 'package:shared_clipboard/core/logger.dart';

class TrayService {
  static final SystemTray _systemTray = SystemTray();
  static final AppLogger _logger = logTag('TRAY');

  static Future<void> init() async {
    try {
      _logger.i('Initializing system tray...');
      
      // Initialize system tray with icon
      // Use .ico on Windows for crisp tray rendering, PNG elsewhere
      String iconPath = Platform.isWindows ? 'assets/icon.ico' : 'assets/icon.png';

      await _systemTray.initSystemTray(
        title: "Shared Clipboard",
        iconPath: iconPath,
        toolTip: "Shared Clipboard - Click to show window",
      );

      _logger.i('System tray icon created, setting up menu...');

      final Menu menu = Menu();
      await menu.buildFrom([
        MenuItemLabel(label: 'Show Window', onClicked: (menuItem) => showApp()),
        MenuItemLabel(label: 'Hide Window', onClicked: (menuItem) => hideApp()),
        MenuItemLabel(label: '', enabled: false), // Separator
        MenuItemLabel(label: 'Enable', onClicked: (menuItem) => setEnabled(true)),
        MenuItemLabel(label: 'Disable', onClicked: (menuItem) => setEnabled(false)),
        MenuItemLabel(label: '', enabled: false), // Separator
        MenuItemLabel(label: 'Quit', onClicked: (menuItem) => exitApp()),
      ]);

      await _systemTray.setContextMenu(menu);

      _systemTray.registerSystemTrayEventHandler((eventName) async {
        _logger.d('System tray event', eventName);
        if (eventName == kSystemTrayEventClick) {
          // Toggle window on single click
          final isVisible = await windowManager.isVisible();
          if (isVisible) {
            await hideApp();
          } else {
            await showApp();
          }
        } else if (eventName == kSystemTrayEventRightClick) {
          _systemTray.popUpContextMenu();
        }
      });

      _logger.i('System tray initialized successfully');
    } catch (e, st) {
      _logger.e('Failed to initialize system tray', e, st);
    }
  }

  static Future<void> showApp() async {
    _logger.i('Showing app window');
    try {
      // Make sure window is created and ready
      await windowManager.show();
      await windowManager.focus();
      // Keep the app off the taskbar; it is controlled via the system tray
      await windowManager.setSkipTaskbar(true);
    } catch (e) {
      _logger.e('Failed to show window', e);
    }
  }

  static Future<void> hideApp() async {
    try {
      _logger.i('Hiding app window');
      await windowManager.hide();
      await windowManager.setSkipTaskbar(true);
    } catch (e) {
      _logger.e('Failed to hide window', e);
    }
  }

  static Future<void> setEnabled(bool enabled) async {
    _logger.i('Setting app enabled', {'enabled': enabled});
    // Logic to enable/disable the service
  }

  static Future<void> exitApp() async {
    _logger.i('Exiting app via tray menu');
    try {
      await _systemTray.destroy();
      exit(0);
    } catch (e) {
      _logger.e('Failed to exit app', e);
      exit(1);
    }
  }

  static Future<void> updateTooltip(String tooltip) async {
    try {
      await _systemTray.setToolTip(tooltip);
    } catch (e) {
      _logger.e('Failed to update tooltip', e);
    }
  }

  static Future<void> updateTitle(String title) async {
    try {
      // Not all platforms allow changing title in runtime, but try
      await _systemTray.setTitle(title);
    } catch (e) {
      // Safe to ignore if not supported
      _logger.w('Failed to update title', e);
    }
  }
}
