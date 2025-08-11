import 'package:flutter/services.dart';

class PipService {
  static const MethodChannel _channel = MethodChannel('pip_controller');

  Future<void> start() async {
    try {
      print('PIP: Starting PiP window...');
      await _channel.invokeMethod('startPip');
      print('PIP: PiP started successfully');
    } catch (e) {
      print('PIP: Error starting PiP: $e');
    }
  }

  Future<void> stop() async {
    try {
      print('PIP: Stopping PiP window...');
      await _channel.invokeMethod('stopPip');
      print('PIP: PiP stopped successfully');
    } catch (e) {
      print('PIP: Error stopping PiP: $e');
    }
  }

  Future<void> updateProgress(double progress) async {
    try {
      print('PIP: Updating progress to ${(progress * 100).toInt()}%');
      await _channel.invokeMethod('updatePipProgress', {'progress': progress});
    } catch (e) {
      print('PIP: Error updating PiP progress: $e');
    }
  }
}
