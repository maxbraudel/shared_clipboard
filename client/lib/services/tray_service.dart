import 'package:system_tray/system_tray.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';
import 'dart:io';
import 'package:shared_clipboard/core/logger.dart';
import 'package:shared_clipboard/core/navigation.dart';
import 'package:shared_clipboard/ui/settings_page.dart';
import 'package:shared_clipboard/core/constants.dart';

class TrayService {
  static final SystemTray _systemTray = SystemTray();
  static final AppLogger _logger = logTag('TRAY');
  static Menu? _menu;
  static MenuItemLabel? _toggleItem;

  static Future<void> init() async {
    try {
      _logger.i('Initializing system tray...');
      
      // Initialize system tray with icon
      // Use .ico on Windows for crisp tray rendering, PNG elsewhere
      String iconPath = Platform.isWindows ? 'assets/icon.ico' : 'assets/icon.png';

      await _systemTray.initSystemTray(
        title: AppConstants.appName,
        iconPath: iconPath,
        toolTip: "${AppConstants.appName} - Click to show window",
      );

      _logger.i('System tray icon created, setting up menu...');

      final Menu menu = Menu();
      _menu = menu;
      _toggleItem = MenuItemLabel(label: 'Show Window', onClicked: (menuItem) async {
        await _toggleWindow();
      });
      await menu.buildFrom([
        _toggleItem!,
        MenuItemLabel(label: 'Settings', onClicked: (menuItem) async {
          await showApp();
          // Push settings page on top of current route
          final nav = navigatorKey.currentState;
          if (nav != null) {
            nav.push(MaterialPageRoute(builder: (_) => const SettingsPage()));
          }
        }),
        MenuSeparator(),
        MenuItemLabel(label: 'Quit', onClicked: (menuItem) => exitApp()),
      ]);

      await _systemTray.setContextMenu(menu);

      // Set initial toggle label according to current visibility
      _updateToggleLabel();

      _systemTray.registerSystemTrayEventHandler((eventName) async {
        _logger.d('System tray event', eventName);
        if (eventName == kSystemTrayEventClick) {
          // Toggle window on single click
          await _toggleWindow();
        } else if (eventName == kSystemTrayEventRightClick) {
          // Refresh toggle label before showing menu
          await _updateToggleLabel();
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
      await _updateToggleLabel();
    } catch (e) {
      _logger.e('Failed to show window', e);
    }
  }

  static Future<void> hideApp() async {
    try {
      _logger.i('Hiding app window');
      await windowManager.hide();
      await windowManager.setSkipTaskbar(true);
      await _updateToggleLabel();
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

  static Future<void> _toggleWindow() async {
    final isVisible = await windowManager.isVisible();
    if (isVisible) {
      await hideApp();
    } else {
      await showApp();
    }
  }

  static Future<void> _updateToggleLabel() async {
    try {
      if (_toggleItem == null || _menu == null) return;
      final isVisible = await windowManager.isVisible();
      final newLabel = isVisible ? 'Hide Window' : 'Show Window';
      // Rebuild item with new label; system_tray requires rebuild
      final items = <MenuItemBase>[
        MenuItemLabel(label: newLabel, onClicked: (item) async => _toggleWindow()),
        MenuItemLabel(label: 'Settings', onClicked: (menuItem) async {
          await showApp();
          final nav = navigatorKey.currentState;
          if (nav != null) {
            nav.push(MaterialPageRoute(builder: (_) => const SettingsPage()));
          }
        }),
        MenuSeparator(),
        MenuItemLabel(label: 'Quit', onClicked: (menuItem) => exitApp()),
      ];
      await _menu!.buildFrom(items);
      await _systemTray.setContextMenu(_menu!);
    } catch (e, st) {
      _logger.w('Failed to update toggle label', e);
      _logger.d('stack', st);
    }
  }
}
