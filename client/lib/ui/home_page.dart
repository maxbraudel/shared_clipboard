import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:io' show Platform;
import 'package:hotkey_manager/hotkey_manager.dart';
import 'dart:async';
import 'package:shared_clipboard/services/socket_service.dart';
import 'package:shared_clipboard/services/webrtc_service.dart';
import 'package:shared_clipboard/services/file_transfer_service.dart';
import 'package:shared_clipboard/services/notification_service.dart';
import 'package:shared_clipboard/core/logger.dart';
// ignore_for_file: library_private_types_in_public_api

// Enum for clipboard request status
enum ClipboardRequestStatus {
  sendingRequest,
  waitingForResponse,
  waitingForDownloadToComplete,
  waitingForUserLocation,
  downloading,
  processing
}

// Class to track detailed clipboard request information
class ClipboardRequest {
  final String deviceName;
  ClipboardRequestStatus status;
  final DateTime createdAt;
  String? additionalInfo;

  ClipboardRequest({
    required this.deviceName,
    required this.status,
    String? additionalInfo,
  }) : createdAt = DateTime.now(), additionalInfo = additionalInfo;

  String get statusMessage {
    switch (status) {
      case ClipboardRequestStatus.sendingRequest:
        return 'Sending clipboard request to the network';
      case ClipboardRequestStatus.waitingForResponse:
        return 'Waiting for response from $deviceName';
      case ClipboardRequestStatus.waitingForDownloadToComplete:
        return 'Waiting for a download to complete';
      case ClipboardRequestStatus.waitingForUserLocation:
        return 'Waiting for user to choose a download location';
      case ClipboardRequestStatus.downloading:
        return additionalInfo != null ? 'Downloading $additionalInfo' : 'Downloading file';
      case ClipboardRequestStatus.processing:
        return 'Processing received content';
    }
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  _HomePageState createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {

  late SocketService _socketService;
  late WebRTCService _webrtcService;
  late FileTransferService _fileTransferService;
  final NotificationService _notificationService = NotificationService();
  final AppLogger _logger = logTag('HOME');
  bool _isInitialized = false;
  bool _isLoadingDevices = true; // Track device discovery loading state
  final List<Map<String, dynamic>> _connectedDevices = [];
  Timer? _updateTimer;

  // New state tracking for UI categories
  String? _lastSharedType; // 'file' or 'text'
  String? _lastSharedContent; // file name or first 30 chars of text
  String? _lastRetrievedType; // 'file' or 'text'
  String? _lastRetrievedContent; // file name or first 30 chars of text
  String? _lastRetrievedOrigin; // sender client name
  final List<ClipboardRequest> _pendingRequests = []; // queued clipboard requests with detailed status
  bool _isDownloading = false;
  double _downloadProgress = 0.0;
  String? _currentDownloadFileName;
  
  // Request queue management (requesting client side)
  final List<String> _requestQueue = []; // queue of pending requests to process
  bool _isRequestingClipboard = false; // track if currently requesting

  // Helper function to truncate long text with ellipsis
  String _truncateText(String text, {int maxLength = 200}) {
    if (text.length <= maxLength) {
      return text;
    }
    return '${text.substring(0, maxLength)}...';
  }

  // State update methods for UI categories
  void _updateSharedClipboard(String type, String content) {
    setState(() {
      _lastSharedType = type;
      _lastSharedContent = type == 'text' ? _truncateText(content, maxLength: 30) : content;
    });
  }

  void _updateRetrievedClipboard(String type, String content, String origin) {
    setState(() {
      _lastRetrievedType = type;
      _lastRetrievedContent = type == 'text' ? _truncateText(content, maxLength: 30) : content;
      _lastRetrievedOrigin = origin;
    });
  }

  void _addPendingRequest(String deviceName, ClipboardRequestStatus status, {String? additionalInfo}) {
    setState(() {
      _pendingRequests.add(ClipboardRequest(
        deviceName: deviceName,
        status: status,
        additionalInfo: additionalInfo,
      ));
    });
  }

  void _removePendingRequest(String deviceName) {
    setState(() {
      _pendingRequests.removeWhere((request) => request.deviceName == deviceName);
    });
  }

  void _updatePendingRequestStatus(String deviceName, ClipboardRequestStatus status, {String? additionalInfo}) {
    setState(() {
      final requestIndex = _pendingRequests.indexWhere((request) => request.deviceName == deviceName);
      if (requestIndex != -1) {
        _pendingRequests[requestIndex].status = status;
        if (additionalInfo != null) {
          _pendingRequests[requestIndex].additionalInfo = additionalInfo;
        }
      }
    });
  }

  void _updateDownloadProgress(String fileName, double progress) {
    setState(() {
      _isDownloading = true;
      _currentDownloadFileName = fileName;
      _downloadProgress = progress;
    });
  }

  void _clearDownloadProgress() {
    setState(() {
      _isDownloading = false;
      _currentDownloadFileName = null;
      _downloadProgress = 0.0;
    });
  }

  void _setupWebRTCCallbacks() {
    // Set up callback for when clipboard content is successfully received
    _webrtcService.onClipboardReceived = (String type, String content, String origin) {
      _logger.i('Clipboard received callback: $type from $origin');
      
      // Update status to processing before clearing
      if (_pendingRequests.isNotEmpty) {
        final deviceName = _pendingRequests.first.deviceName;
        _updatePendingRequestStatus(deviceName, ClipboardRequestStatus.processing);
      }
      
      // Clear any pending requests (since we successfully received content)
      setState(() {
        _pendingRequests.clear();
        _isRequestingClipboard = false; // Clear requesting state
      });
      
      // Update retrieved clipboard state
      _updateRetrievedClipboard(type, content, origin);
      
      // Process next queued request if any
      _processNextQueuedRequest();
      
      _logger.i('UI state updated for received clipboard content');
    };
    
    // Set up callback for download progress updates
    _webrtcService.onDownloadProgress = (String fileName, double progress) {
      _logger.i('Download progress callback: $fileName at ${(progress * 100).toInt()}%');
      _updateDownloadProgress(fileName, progress);
      
      // Update pending request status to show downloading with file name
      if (_pendingRequests.isNotEmpty) {
        final deviceName = _pendingRequests.first.deviceName;
        _updatePendingRequestStatus(deviceName, ClipboardRequestStatus.downloading, additionalInfo: fileName);
      }
    };
    
    // Set up callback for download completion
    _webrtcService.onDownloadComplete = () {
      _logger.i('Download complete callback');
      _clearDownloadProgress();
      
      // Clear requesting state and process next queued request
      setState(() {
        _isRequestingClipboard = false;
      });
      _processNextQueuedRequest();
    };
    
    // Set up callback for when no clipboard content is available
    _webrtcService.onNoContentAvailable = (String origin) {
      _logger.i('No content available callback from: $origin');
      
      // Clear pending requests since no content is available
      setState(() {
        _pendingRequests.clear();
        _isRequestingClipboard = false;
      });
      
      // Show notification to user with clean message
      _notificationService.showClipboardReceiveFailure('No device is ready to share a clipboard');
      
      // Process next queued request if any
      _processNextQueuedRequest();
      
      _logger.i('UI state cleared due to no content available');
    };
    
    // Set up callback for when waiting for user to choose download location
    _webrtcService.onWaitingForUserLocation = (String fileName) {
      _logger.i('Waiting for user location callback for file: $fileName');
      
      // Update pending request status to show waiting for user location
      if (_pendingRequests.isNotEmpty) {
        final deviceName = _pendingRequests.first.deviceName;
        _updatePendingRequestStatus(deviceName, ClipboardRequestStatus.waitingForUserLocation, additionalInfo: fileName);
      }
    };
    
    // Set up callback for when download fails or is cancelled
    _webrtcService.onDownloadFailed = (String reason) {
      _logger.i('Download failed callback: $reason');
      
      // Clear pending requests since download failed
      setState(() {
        _pendingRequests.clear();
        _isRequestingClipboard = false;
        _isDownloading = false;
        _downloadProgress = 0.0;
        _currentDownloadFileName = null;
      });
      
      // Show notification about the failure
      _notificationService.showClipboardReceiveFailure('Download failed: $reason');
      
      // Process next queued request if any
      _processNextQueuedRequest();
      
      _logger.i('UI state cleared due to download failure');
    };
    
    _logger.i('WebRTC callbacks setup completed');
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
          _logger.d('Hotkey SHARE triggered');
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
          _logger.d('Hotkey REQUEST triggered');
          _requestClipboard();
        },
      );

      _logger.i('Global hotkeys registered');
    } catch (e, st) {
      _logger.e('Failed to register global hotkeys', e, st);
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
      _logger.i('Starting service initialization');
      
      // Initialize services
      _socketService = SocketService();
      _webrtcService = WebRTCService();
      _fileTransferService = FileTransferService();
      
      // Initialize WebRTC first
      _logger.i('Initializing WebRTC service');
      _webrtcService.init();
      
      // Set up WebRTC callbacks for UI state tracking
      _setupWebRTCCallbacks();
      
      // Then initialize Socket service
      _logger.i('Initializing Socket service');
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
        _isInitialized = true;
      });
      
      // Set a timeout to stop loading if no devices are discovered
      Timer(const Duration(seconds: 5), () {
        if (mounted && _isLoadingDevices) {
          setState(() {
            _isLoadingDevices = false;
          });
        }
      });
      
      // Start timer to update connected devices durations
      _updateTimer = Timer.periodic(const Duration(minutes: 1), (timer) {
        if (mounted && _connectedDevices.isNotEmpty) {
          setState(() {
            // Trigger rebuild to update duration displays
          });
        }
      });
      
      _logger.i('Services initialized successfully');

      // Register global hotkeys after services are ready
      await _registerGlobalHotkeys();
    } catch (e) {
      _logger.e('Service initialization error', e);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Shared Clipboard'),
        backgroundColor: Colors.blue,
        foregroundColor: Colors.white,
      ),
      body: Container(
        color: Colors.grey[50],
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [

            
            // Action Buttons
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _isInitialized ? _shareClipboard : null,
                    icon: const Icon(Icons.share),
                    label: const Text('Share (Cmd/Ctrl+F12)'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _isInitialized ? _requestClipboard : null,
                    icon: const Icon(Icons.download),
                    label: const Text('Request (Cmd/Ctrl+F11)'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.orange,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            
            // Categories
            Expanded(
              child: Column(
                children: [
                  // Connected devices section (full width)
                  _buildConnectedDevicesSection(),
                  const SizedBox(height: 16),
                  
                  // Grid layout for clipboard sections
                  Expanded(
                    child: Row(
                      children: [
                        // Left column
                        Expanded(
                          child: Column(
                            children: [
                              // Top left: Shared Clipboard
                              Expanded(child: _buildSharedClipboardSection()),
                              const SizedBox(height: 16),
                              // Bottom left: Retrieved Clipboard
                              Expanded(child: _buildRetrievedClipboardSection()),
                            ],
                          ),
                        ),
                        const SizedBox(width: 16),
                        // Right column
                        Expanded(
                          child: Column(
                            children: [
                              // Top right: Pending Clipboard Requests
                              Expanded(child: _buildPendingRequestsSection()),
                              const SizedBox(height: 16),
                              // Bottom right: Current Download
                              Expanded(child: _buildCurrentDownloadSection()),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _shareClipboard() async {
    if (!_isInitialized) return;
    

    
    try {
      _logger.i('Reading clipboard for sharing');
      
      // Use file transfer service to detect files or text
      final clipboardContent = await _fileTransferService.getClipboardContent();
      
      if (clipboardContent.isFiles && clipboardContent.files.isNotEmpty) {
        // Files detected in clipboard
        _logger.i('Files detected in clipboard', {'count': clipboardContent.files.length});
        _logger.d('Sending share-ready to server (files)');
        _socketService.sendShareReady();
        
        final fileNames = clipboardContent.files.map((f) => f.name).join(', ');

        
        // Update shared clipboard UI state
        _updateSharedClipboard('file', clipboardContent.files.first.name);
        
        _logger.d('Files ready to share', {
          'files': clipboardContent.files.map((f) => f.name).join(', '),
        });
        
        // Show success notification for files
        final deviceNames = _connectedDevices.map((d) => d['name'] as String).join(', ');
        if (deviceNames.isNotEmpty) {
          _notificationService.showClipboardShareSuccess(deviceNames);
        }
      } else if (clipboardContent.text.isNotEmpty) {
        // Regular text in clipboard
        _logger.i('Text detected in clipboard');
        _logger.d('Sending share-ready to server (text)');
        _socketService.sendShareReady();
        
        // Get raw clipboard text for UI display (avoid processed error messages)
        final clipboardData = await Clipboard.getData(Clipboard.kTextPlain);
        final rawText = clipboardData?.text ?? clipboardContent.text;
        

        
        // Update shared clipboard UI state with raw text
        _updateSharedClipboard('text', rawText);
        
        _logger.d('Text ready to share');
        
        // Show success notification for text
        final deviceNames = _connectedDevices.map((d) => d['name'] as String).join(', ');
        if (deviceNames.isNotEmpty) {
          _notificationService.showClipboardShareSuccess(deviceNames);
        }
      } else {

        _logger.w('No content in clipboard');
        _notificationService.showClipboardShareFailure('Clipboard is empty');
      }
    } catch (e) {
      _logger.e('Clipboard read error', e);
      _notificationService.showClipboardShareFailure(e.toString());
    }
  }

  void _requestClipboard() {
    if (!_isInitialized) return;
    
    // Check if we have connected devices
    if (_connectedDevices.isEmpty) {
      _logger.w('No connected devices to request from');
      _notificationService.showClipboardReceiveFailure('No connected devices');
      return;
    }
    
    final deviceName = _connectedDevices.isNotEmpty ? _connectedDevices.first['name'] : 'device';
    
    // If already downloading/requesting, queue this request locally
    if (_isRequestingClipboard || _isDownloading) {
      _logger.i('Already downloading/requesting, queueing request locally');
      _requestQueue.add('Clipboard request from $deviceName');
      _addPendingRequest(deviceName, ClipboardRequestStatus.waitingForDownloadToComplete);
      
      // Show queued notification
      _notificationService.showTransferQueued('clipboard content', _currentDownloadFileName ?? 'current transfer');
      return;
    }
    
    // Process request immediately
    _processClipboardRequest(deviceName);
  }
  
  void _processClipboardRequest(String deviceName) {
    _logger.i('Processing clipboard request to $deviceName');
    
    try {
      _isRequestingClipboard = true;
      
      // Add pending request with "sending request" status
      _addPendingRequest(deviceName, ClipboardRequestStatus.sendingRequest);
      
      _socketService.sendRequestShare();
      _logger.i('Clipboard request sent successfully');
      
      // Update status to waiting for response
      _updatePendingRequestStatus(deviceName, ClipboardRequestStatus.waitingForResponse);
      
    } catch (e) {
      _logger.e('Error requesting clipboard', e);
      _notificationService.showClipboardReceiveFailure(e.toString());
      _isRequestingClipboard = false;
      _removePendingRequest(deviceName);
    }
  }
  
  void _processNextQueuedRequest() {
    if (_requestQueue.isEmpty || _isRequestingClipboard || _isDownloading) {
      return;
    }
    
    _logger.i('Processing next queued request');
    final nextRequest = _requestQueue.removeAt(0);
    
    // Extract device name from request string
    final deviceName = _connectedDevices.isNotEmpty ? _connectedDevices.first['name'] : 'device';
    _processClipboardRequest(deviceName);
  }

  Widget _buildConnectedDevicesSection() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
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
            constraints: const BoxConstraints(
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
                        const SizedBox(
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
                                decoration: const BoxDecoration(
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
                                      style: const TextStyle(
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

  Widget _buildSharedClipboardSection() {
    return _buildCategorySection(
      title: 'Shared Clipboard',
      icon: Icons.upload,
      iconColor: Colors.green,
      child: _lastSharedContent != null
          ? ListTile(
              leading: Icon(
                _lastSharedType == 'file' ? Icons.insert_drive_file : Icons.text_snippet,
                color: Colors.green,
              ),
              title: Text(
                _lastSharedType == 'file' ? _lastSharedContent! : 'Text: ${_lastSharedContent!}',
                style: const TextStyle(fontSize: 14),
              ),
              subtitle: Text('Type: ${_lastSharedType!}'),
            )
          : const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'No clipboard content shared yet',
                style: TextStyle(color: Colors.grey, fontSize: 14),
              ),
            ),
    );
  }

  Widget _buildRetrievedClipboardSection() {
    return _buildCategorySection(
      title: 'Retrieved Clipboard',
      icon: Icons.download,
      iconColor: Colors.blue,
      child: _lastRetrievedContent != null
          ? ListTile(
              leading: Icon(
                _lastRetrievedType == 'file' ? Icons.insert_drive_file : Icons.text_snippet,
                color: Colors.blue,
              ),
              title: Text(
                _lastRetrievedType == 'file' ? _lastRetrievedContent! : 'Text: ${_lastRetrievedContent!}',
                style: const TextStyle(fontSize: 14),
              ),
              subtitle: Text('From: ${_lastRetrievedOrigin ?? "Unknown"} • Type: ${_lastRetrievedType!}'),
            )
          : const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'No clipboard content retrieved yet',
                style: TextStyle(color: Colors.grey, fontSize: 14),
              ),
            ),
    );
  }

  Widget _buildPendingRequestsSection() {
    return _buildCategorySection(
      title: 'Pending Clipboard Requests',
      icon: Icons.schedule,
      iconColor: Colors.orange,
      child: _pendingRequests.isNotEmpty
          ? Column(
              children: _pendingRequests.map((request) => 
                ListTile(
                  leading: const Icon(Icons.hourglass_empty, color: Colors.orange),
                  title: Text(
                    request.deviceName,
                    style: const TextStyle(fontSize: 14),
                  ),
                  subtitle: Text(request.statusMessage),
                )
              ).toList(),
            )
          : const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'No pending requests',
                style: TextStyle(color: Colors.grey, fontSize: 14),
              ),
            ),
    );
  }

  Widget _buildCurrentDownloadSection() {
    return _buildCategorySection(
      title: 'Current Download',
      icon: Icons.cloud_download,
      iconColor: Colors.purple,
      child: _isDownloading
          ? Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _currentDownloadFileName ?? 'Downloading...',
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(height: 8),
                  LinearProgressIndicator(
                    value: _downloadProgress / 100,
                    backgroundColor: Colors.grey[300],
                    valueColor: const AlwaysStoppedAnimation<Color>(Colors.purple),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${_downloadProgress.toStringAsFixed(1)}%',
                    style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                  ),
                ],
              ),
            )
          : const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'No active downloads',
                style: TextStyle(color: Colors.grey, fontSize: 14),
              ),
            ),
    );
  }

  Widget _buildCategorySection({
    required String title,
    required IconData icon,
    required Color iconColor,
    required Widget child,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        boxShadow: [BoxShadow(color: Colors.grey.withOpacity(0.1), blurRadius: 4)],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: iconColor.withOpacity(0.1),
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(8),
                topRight: Radius.circular(8),
              ),
            ),
            child: Row(
              children: [
                Icon(icon, color: iconColor, size: 20),
                const SizedBox(width: 8),
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: iconColor,
                  ),
                ),
              ],
            ),
          ),
          child,
        ],
      ),
    );
  }
}

