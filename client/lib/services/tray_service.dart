import 'package:system_tray/system_tray.dart';

class TrayService {
  static final SystemTray _systemTray = SystemTray();

  static Future<void> init() async {
    try {
      // Initialize system tray with title only (no icon needed)
      await _systemTray.initSystemTray(
        title: "Shared Clipboard",
      );

      final Menu menu = Menu();
      await menu.buildFrom([
        MenuItemLabel(label: 'Show App', onClicked: (menuItem) => showApp()),
        MenuItemLabel(label: 'Enable', onClicked: (menuItem) => setEnabled(true)),
        MenuItemLabel(label: 'Disable', onClicked: (menuItem) => setEnabled(false)),
        MenuSeparator(),
        MenuItemLabel(label: 'Exit', onClicked: (menuItem) => exitApp()),
      ]);

      await _systemTray.setContextMenu(menu);

      _systemTray.registerSystemTrayEventHandler((eventName) {
        if (eventName == kSystemTrayEventClick) {
          _systemTray.popUpContextMenu();
        } else if (eventName == kSystemTrayEventRightClick) {
          _systemTray.popUpContextMenu();
        }
      });

      print('System tray initialized successfully');
    } catch (e) {
      print('Failed to initialize system tray: $e');
    }
  }

  static void showApp() {
    print("Show app clicked");
  }

  static void setEnabled(bool enabled) {
    // Logic to enable/disable the service
    print("Service enabled: $enabled");
  }

  static void exitApp() {
    // Logic to exit the app
    print("Exit app clicked");
  }
}
