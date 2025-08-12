import 'package:flutter/material.dart';
import 'dart:io' show Platform;
import 'package:shared_clipboard/services/settings_service.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = SettingsService.instance;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: AnimatedBuilder(
        animation: settings,
        builder: (context, _) {
          final tiles = <Widget>[];
          if (Platform.isMacOS) {
            tiles.addAll([
              SwitchListTile(
                title: const Text('Display a download progress indicator'),
                subtitle: const Text('Show Picture-in-Picture window when a download starts'),
                value: settings.displayDownloadProgressIndicator,
                onChanged: (v) => settings.displayDownloadProgressIndicator = v,
              ),
              const Divider(height: 1),
            ]);
          }
          tiles.add(
            SwitchListTile(
              title: const Text('Send download progress notifications'),
              subtitle: const Text('Show 0%, 10%, 20% ... 90% system notifications during download'),
              value: settings.sendDownloadProgressNotifications,
              onChanged: (v) => settings.sendDownloadProgressNotifications = v,
            ),
          );
          return ListView(children: tiles);
        },
      ),
    );
  }
}
