import 'package:flutter/material.dart';
import 'package:shared_clipboard/ui/home_page.dart';
import 'package:shared_clipboard/services/tray_service.dart';
import 'package:window_manager/window_manager.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Initialize window manager
  await windowManager.ensureInitialized();
  
  // Configure window options but don't show yet
  WindowOptions windowOptions = const WindowOptions(
    size: Size(800, 600),
    center: true,
    backgroundColor: Colors.white,
    skipTaskbar: true,
    titleBarStyle: TitleBarStyle.normal,
  );
  
  // Wait until ready but keep hidden
  await windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.setPreventClose(true);
    await windowManager.setSkipTaskbar(true);
    // DON'T call show() - keep it hidden
  });
  
  // Initialize system tray after window is ready
  await TrayService.init();
  
  // Run the app
  runApp(BackgroundApp());
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
      home: HomePage(),
      debugShowCheckedModeBanner: false,
    );
  }
}
