import 'package:flutter/material.dart';
import 'package:shared_clipboard/ui/home_page.dart';
import 'package:shared_clipboard/services/tray_service.dart';
import 'package:shared_clipboard/services/notification_service.dart';
import 'package:window_manager/window_manager.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // hotkey_manager does not require explicit ensureInitialized on desktop
  
  // Initialize window manager
  await windowManager.ensureInitialized();
  
  // Configure window options but don't show yet
  WindowOptions windowOptions = const WindowOptions(
    size: Size(1000, 700),
    minimumSize: Size(700, 700),
    center: true,
    backgroundColor: Colors.black,
    skipTaskbar: true,
    titleBarStyle: TitleBarStyle.normal,
  );
  
  // Wait until ready but keep hidden
  await windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.setPreventClose(true);
    await windowManager.setSkipTaskbar(true);
    // Keep the window hidden on startup explicitly
    await windowManager.hide();
  });
  
  // Initialize system tray after window is ready
  await TrayService.init();
  
  // Initialize notification service
  await NotificationService().init();
  
  // Run the app
  runApp(const BackgroundApp());
}

class BackgroundApp extends StatefulWidget {
  const BackgroundApp({super.key});

  @override
  State<BackgroundApp> createState() => _BackgroundAppState();
}

class _BackgroundAppState extends State<BackgroundApp> with WindowListener {
  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    // Extra safety: ensure close is prevented and app starts hidden
    windowManager.setPreventClose(true);
    windowManager.setSkipTaskbar(true);
    windowManager.hide();
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowClose() async {
    // Always hide instead of close
    await TrayService.hideApp();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Shared Clipboard',
      theme: ThemeData(
        primarySwatch: Colors.blue,
      ),
      home: const HomePage(),
      debugShowCheckedModeBanner: false,
    );
  }
}
