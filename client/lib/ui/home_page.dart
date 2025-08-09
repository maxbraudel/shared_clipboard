import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:io' show Platform;
import 'package:hotkey_manager/hotkey_manager.dart';
import 'dart:async';
import 'package:shared_clipboard/services/socket_service.dart';
import 'package:shared_clipboard/services/webrtc_service.dart';
import 'package:shared_clipboard/services/file_transfer_service.dart';
import 'package:shared_clipboard/services/notification_service.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  _HomePageState createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  String _status = 'Initializing...';
  late SocketService _socketService;
  late WebRTCService _webrtcService;
  late FileTransferService _fileTransferService;
  final NotificationService _notificationService = NotificationService();
  bool _isInitialized = false;
  bool _isLoadingDevices = true; // Track device discovery loading state
  List<Map<String, dynamic>> _connectedDevices = [];
  Timer? _updateTimer;

  // Helper function to truncate long text with ellipsis
  String _truncateText(String text, {int maxLength = 200}) {
    if (text.length <= maxLength) {
      return text;
    }
    return '${text.substring(0, maxLength)}...';
  }

  Future<void> _registerGlobalHotkeys() async {
    try {
      // Clear any prior registrations to avoid duplicates
      await hotKeyManager.unregisterAll();

      final isMac = Platform.isMacOS;
      final shareModifiers = isMac ? [HotKeyModifier.meta] : [HotKeyModifier.control];
      final requestModifiers = isMac ? [HotKeyModifier.meta] : [HotKeyModifier.control];

      // Share clipboard: Cmd+F12 (macOS) or Ctrl+F12 (Windows)
      await hotKeyManager.register(
        HotKey(
          key: LogicalKeyboardKey.f12,
          modifiers: shareModifiers,
          scope: HotKeyScope.system, // ensure system-wide
        ),
        keyDownHandler: (hotKey) async {
          print('🔎 Hotkey SHARE triggered');
          _shareClipboard();
        },
      );

      // Request clipboard: Cmd+F11 (macOS) or Ctrl+F11 (Windows)
      await hotKeyManager.register(
        HotKey(
          key: LogicalKeyboardKey.f11,
          modifiers: requestModifiers,
          scope: HotKeyScope.system,
        ),
        keyDownHandler: (hotKey) async {
          print('🔎 Hotkey REQUEST triggered');
          _requestClipboard();
        },
      );

      print('✅ Global hotkeys registered');
    } catch (e, st) {
      print('❌ Failed to register global hotkeys: $e');
      print(st);
    }
  }


  @override
  void initState() {
    super.initState();
    _initializeServices();
  }

  @override
  void dispose() {
    _updateTimer?.cancel();
    super.dispose();
  }

  void _initializeServices() async {
    try {
      print('🚀 STARTING SERVICE INITIALIZATION');
      
      // Initialize services
      _socketService = SocketService();
      _webrtcService = WebRTCService();
      _fileTransferService = FileTransferService();
      
      // Initialize WebRTC first
      print('🔧 INITIALIZING WEBRTC SERVICE');
      _webrtcService.init();
      
      // Then initialize Socket service
      print('🔧 INITIALIZING SOCKET SERVICE');
      _socketService.init(webrtcService: _webrtcService);
      
      // Set up device event callbacks
      _socketService.onDeviceConnected = (device) {
        setState(() {
          // Add device if not already in the list and not ourselves
          final deviceId = device['id'] ?? device['socketId'] ?? 'unknown';
          final isOwnDevice = deviceId == _socketService.socket.id;
          
          if (!isOwnDevice) {
            final existingIndex = _connectedDevices.indexWhere((d) => d['id'] == deviceId);
            if (existingIndex == -1) {
              _connectedDevices.add({
                'id': deviceId,
                'name': device['name'] ?? device['deviceName'] ?? 'Unknown Device',
                'connectedAt': DateTime.now(),
              });
            }
          }
          
          // Stop loading when we get device responses (discovery is working)
          _isLoadingDevices = false;
        });
      };
      
      _socketService.onDeviceDisconnected = (device) {
        setState(() {
          final deviceId = device['deviceId'] ?? device['id'] ?? device['socketId'] ?? 'unknown';
          _connectedDevices.removeWhere((d) => d['id'] == deviceId);
        });
      };
      
      _socketService.onConnectedDevicesList = (devices) {
        setState(() {
          // Replace the current list with the devices from the server (excluding ourselves)
          _connectedDevices.clear();
          for (var device in devices) {
            final deviceId = device['id'] ?? device['socketId'] ?? 'unknown';
            final isOwnDevice = deviceId == _socketService.socket.id;
            
            if (!isOwnDevice) {
              _connectedDevices.add({
                'id': deviceId,
                'name': device['name'] ?? device['deviceName'] ?? 'Unknown Device',
                'connectedAt': DateTime.now(), // We don't know the actual connection time
              });
            }
          }
          
          // Stop loading when we get the device list response
          _isLoadingDevices = false;
        });
      };
      
      setState(() {
        _status = 'Ready';
        _isInitialized = true;
      });
      
      // Set a timeout to stop loading if no devices are discovered
      Timer(Duration(seconds: 5), () {
        if (mounted && _isLoadingDevices) {
          setState(() {
            _isLoadingDevices = false;
          });
        }
      });
      
      // Start timer to update connected devices durations
      _updateTimer = Timer.periodic(Duration(minutes: 1), (timer) {
        if (mounted && _connectedDevices.isNotEmpty) {
          setState(() {
            // Trigger rebuild to update duration displays
          });
        }
      });
      
      print('✅ SERVICES INITIALIZED SUCCESSFULLY');

      // Register global hotkeys after services are ready
      await _registerGlobalHotkeys();
    } catch (e) {
      print('❌ SERVICE INITIALIZATION ERROR: $e');
      setState(() {
        _status = 'Initialization failed: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Shared Clipboard'),
        backgroundColor: Colors.blue,
      ),
      body: Container(
        color: Colors.white,
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              const Icon(
                Icons.content_copy,
                size: 64,
                color: Colors.blue,
              ),
              const SizedBox(height: 20),
              const Text(
                'Shared Clipboard',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                _status,
                style: TextStyle(
                  fontSize: 16,
                  color: Colors.grey[600],
                ),
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
                maxLines: 3,
              ),
              const SizedBox(height: 30),
              _buildConnectedDevicesSection(),
              const SizedBox(height: 30),
              ElevatedButton.icon(
                onPressed: _isInitialized ? () {
                  _shareClipboard();
                } : null,
                icon: const Icon(Icons.share),
                label: const Text('Share Clipboard (Cmd/Ctrl+F12)'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                ),
              ),
              const SizedBox(height: 10),
              ElevatedButton.icon(
                onPressed: _isInitialized ? () {
                  _requestClipboard();
                } : null,
                icon: const Icon(Icons.download),
                label: const Text('Get Clipboard (Cmd/Ctrl+F11)'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _shareClipboard() async {
    if (!_isInitialized) return;
    
    setState(() {
      _status = 'Reading clipboard...';
    });
    
    try {
      print('� READING CLIPBOARD FOR SHARING');
      
      // Use file transfer service to detect files or text
      final clipboardContent = await _fileTransferService.getClipboardContent();
      
      if (clipboardContent.isFiles && clipboardContent.files.isNotEmpty) {
        // Files detected in clipboard
        print('📁 FILES DETECTED IN CLIPBOARD: ${clipboardContent.files.length} files');
        print('📤 SENDING SHARE-READY TO SERVER (FILES)');
        _socketService.sendShareReady();
        setState(() {
          final fileNames = clipboardContent.files.map((f) => f.name).join(', ');
          _status = 'Ready to share ${clipboardContent.files.length} files: ${_truncateText(fileNames)}';
        });
        print("📋 FILES READY TO SHARE: ${clipboardContent.files.map((f) => f.name).join(', ')}");
        
        // Show success notification for clipboard share preparation
        _notificationService.showClipboardShareSuccess();
      } else if (clipboardContent.text.isNotEmpty) {
        // Regular text in clipboard
        print('📝 TEXT DETECTED IN CLIPBOARD: "${clipboardContent.text}"');
        print('📤 SENDING SHARE-READY TO SERVER (TEXT)');
        _socketService.sendShareReady();
        setState(() {
          _status = 'Ready to share: "${_truncateText(clipboardContent.text)}"';
        });
        print("📋 TEXT READY TO SHARE: ${clipboardContent.text}");
        
        // Show success notification for clipboard share preparation
        _notificationService.showClipboardShareSuccess();
      } else {
        setState(() {
          _status = 'No content in clipboard';
        });
        print('❌ NO CONTENT IN CLIPBOARD');
        
        // Show failure notification for empty clipboard
        _notificationService.showClipboardShareFailure(reason: 'No content in clipboard');
      }
    } catch (e) {
      setState(() {
        _status = 'Error reading clipboard: $e';
      });
      print('❌ CLIPBOARD READ ERROR: $e');
      
      // Show failure notification for clipboard share error
      _notificationService.showClipboardShareFailure(reason: 'Error reading clipboard: $e');
    }
  }

  void _requestClipboard() {
    if (!_isInitialized) return;
    
    setState(() {
      _status = 'Requesting clipboard...';
    });
    print("📥 REQUESTING CLIPBOARD FROM SERVER");
    
    _socketService.sendRequestShare();
    
    // Reset status after a delay if no response
    Future.delayed(const Duration(seconds: 5), () {
      if (mounted && _status == 'Requesting clipboard...') {
        setState(() {
          _status = 'Ready';
        });
      }
    });
  }

  Widget _buildConnectedDevicesSection() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.devices,
                color: Colors.blue,
                size: 20,
              ),
              const SizedBox(width: 8),
              Text(
                _isLoadingDevices 
                    ? 'Connected Devices (discovering...)'
                    : 'Connected Devices (${_connectedDevices.length})',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: Colors.grey[800],
                ),
              ),
            ],
          ),
          const SizedBox(height: 15),
          Container(
            constraints: BoxConstraints(
              maxHeight: 200,
              maxWidth: 400,
            ),
            child: _isLoadingDevices
                ? Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: Colors.blue[50],
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.blue[200]!),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation<Color>(Colors.blue),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Text(
                          'Discovering devices...',
                          style: TextStyle(
                            color: Colors.blue[700],
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  )
                : _connectedDevices.isEmpty
                    ? Container(
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          color: Colors.grey[100],
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.grey[300]!),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.info_outline,
                              color: Colors.grey[500],
                              size: 20,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              'No devices connected',
                              style: TextStyle(
                                color: Colors.grey[600],
                                fontSize: 14,
                              ),
                            ),
                          ],
                        ),
                      )
                : Container(
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.grey[300]!),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: _connectedDevices.length,
                      itemBuilder: (context, index) {
                        final device = _connectedDevices[index];
                        final connectedAt = device['connectedAt'] as DateTime;
                        final duration = DateTime.now().difference(connectedAt);
                        
                        String durationText;
                        if (duration.inMinutes < 1) {
                          durationText = 'Just now';
                        } else if (duration.inHours < 1) {
                          durationText = '${duration.inMinutes}m ago';
                        } else {
                          durationText = '${duration.inHours}h ago';
                        }
                        
                        return Container(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                          decoration: BoxDecoration(
                            color: index % 2 == 0 ? Colors.grey[50] : Colors.white,
                            border: index > 0 ? Border(top: BorderSide(color: Colors.grey[200]!)) : null,
                          ),
                          child: Row(
                            children: [
                              Container(
                                width: 8,
                                height: 8,
                                decoration: BoxDecoration(
                                  color: Colors.green,
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      device['name'],
                                      style: TextStyle(
                                        fontWeight: FontWeight.w500,
                                        fontSize: 14,
                                      ),
                                    ),
                                    Text(
                                      'ID: ${device['id']}',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: Colors.grey[600],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Text(
                                durationText,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey[500],
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

