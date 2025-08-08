import 'package:system_tray/system_tray.dart';
import 'package:window_manager/window_manager.dart';
import 'dart:io';

class TrayService {
  static final SystemTray _systemTray = SystemTray();

  static Future<void> init() async {
    try {
      print('Initializing system tray...');
      
      // Initialize system tray with icon
      // Use bundled PNG for all platforms (ensure asset is declared in pubspec.yaml)
      String iconPath = 'assets/icon.png';

      await _systemTray.initSystemTray(
        title: "Shared Clipboard",
        iconPath: iconPath,
        toolTip: "Shared Clipboard - Click to show window",
      );

      print('System tray icon created, setting up menu...');

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

      _systemTray.registerSystemTrayEventHandler((eventName) {
        print('System tray event: $eventName');
        if (eventName == kSystemTrayEventClick) {
          showApp(); // Show window on single click
        } else if (eventName == kSystemTrayEventRightClick) {
          _systemTray.popUpContextMenu();
        }
      });

      print('System tray initialized successfully');
    } catch (e, stackTrace) {
      print('Failed to initialize system tray: $e');
      print('Stack trace: $stackTrace');
    }
  }

  static Future<void> showApp() async {
    try {
      print("Attempting to show window...");
      
      // Make sure window is created and ready
      await windowManager.show();
      await windowManager.focus();
      await windowManager.setSkipTaskbar(false);
      
      print("Window shown successfully");
    } catch (e) {
      print("Failed to show window: $e");
    }
  }

  static Future<void> hideApp() async {
    try {
      print("Hiding window...");
      
      await windowManager.hide();
      await windowManager.setSkipTaskbar(true);
      
      print("Window hidden successfully");
    } catch (e) {
      print("Failed to hide window: $e");
    }
  }

  static void setEnabled(bool enabled) {
    // Logic to enable/disable the service
    print("Service enabled: $enabled");
  }

  static Future<void> exitApp() async {
    try {
      await _systemTray.destroy();
      exit(0);
    } catch (e) {
      print("Failed to exit app: $e");
      exit(1);
    }
  }

  static Future<void> updateTooltip(String tooltip) async {
    try {
      await _systemTray.setToolTip(tooltip);
    } catch (e) {
      print("Failed to update tooltip: $e");
    }
  }
}
