import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:shared_clipboard/services/webrtc_service.dart';
import 'dart:io';

class SocketService {
  late IO.Socket socket;
  late WebRTCService _webrtcService;
  
  // Callbacks for UI updates
  Function(Map<String, dynamic> device)? onDeviceConnected;
  Function(Map<String, dynamic> device)? onDeviceDisconnected;
  Function(List<Map<String, dynamic>> devices)? onConnectedDevicesList;

  // Helper function for timestamped logging
  void _log(String message, [dynamic data]) {
    final timestamp = DateTime.now().toIso8601String();
    if (data != null) {
      print('[$timestamp] CLIENT: $message - $data');
    } else {
      print('[$timestamp] CLIENT: $message');
    }
  }

  void init({required WebRTCService webrtcService}) {
    _log('🚀 INITIALIZING SOCKET SERVICE');
    _webrtcService = webrtcService;
    
    // Set up the callback for WebRTC to send signals back through socket
    _webrtcService.onSignalGenerated = (String to, dynamic signal) {
      sendSignal(to, signal);
    };
    
    _log('🔗 CREATING SOCKET CONNECTION');
    
    socket = IO.io('https://test3.braudelserveur.com', <String, dynamic>{
      'transports': ['websocket', 'polling'],
      'autoConnect': false,
      'timeout': 20000,
      'forceNew': true,
      'upgrade': true,
      'rememberUpgrade': false,
    });

    socket.onConnectError((error) {
      _log('❌ CONNECTION ERROR', error.toString());
    });

    socket.onError((error) {
      _log('❌ SOCKET ERROR', error.toString());
    });

    _log('🔌 ATTEMPTING TO CONNECT');
    socket.connect();

    socket.onConnect((_) async {
      _log('✅ CONNECTED TO SERVER');
      _log('🆔 OUR SOCKET ID', socket.id);
      
      // Get hostname/computer name
      String deviceName = 'Unknown Device';
      try {
        // Try to get the hostname from Platform
        if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
          // For desktop platforms, try to get hostname
          final result = await Process.run('hostname', []);
          if (result.exitCode == 0 && result.stdout.toString().trim().isNotEmpty) {
            deviceName = result.stdout.toString().trim();
          }
        } else if (Platform.isAndroid) {
          deviceName = 'Android Device';
        } else if (Platform.isIOS) {
          deviceName = 'iOS Device';
        }
      } catch (e) {
        _log('⚠️ Could not get hostname', e.toString());
        // Fallback to platform name
        if (Platform.isMacOS) {
          deviceName = 'Mac';
        } else if (Platform.isWindows) {
          deviceName = 'Windows PC';
        } else if (Platform.isLinux) {
          deviceName = 'Linux PC';
        }
      }
      
      _log('📝 REGISTERING WITH DEVICE NAME', deviceName);
      socket.emit('register', {
        'deviceName': deviceName,
        'platform': Platform.operatingSystem,
      });
      
      // Request existing connected devices with a delay to ensure we're registered
      Future.delayed(Duration(milliseconds: 500), () {
        _log('📋 REQUESTING EXISTING DEVICES');
        // Try multiple possible event names to request device list
        socket.emit('get-devices', {});
        socket.emit('list-devices', {});
        socket.emit('get-connected-devices', {});
        socket.emit('devices', {});
        socket.emit('clients', {});
        socket.emit('room-info', {});
        
        // Set a timeout to collect any device events that might come
        Future.delayed(Duration(seconds: 2), () {
          _log('⏰ DEVICE DISCOVERY TIMEOUT - checking what we learned');
          
          // If no devices were discovered, broadcast a "hello" message
          // to let existing clients know we're here and ask them to respond
          _log('📢 BROADCASTING HELLO TO DISCOVER EXISTING DEVICES');
          socket.emit('hello-i-am-here', {
            'deviceId': socket.id,
            'timestamp': DateTime.now().millisecondsSinceEpoch,
          });
        });
      });
    });

    socket.on('share-request', (data) async {
      _log('📥 SHARE REQUEST RECEIVED', data);
      String requesterId = data['from'] ?? 'unknown';
      // Guard: if server mistakenly routes our own request back to us, ignore
      if (requesterId == socket.id) {
        _log('🚫 IGNORING SELF SHARE-REQUEST', {
          'requesterId': requesterId,
          'ourId': socket.id,
        });
        return;
      }
      _log('📤 CREATING OFFER TO SEND CLIPBOARD TO REQUESTER', requesterId);
      
      try {
        await _webrtcService.createOffer(requesterId);
        _log('✅ WEBRTC createOffer COMPLETED SUCCESSFULLY');
      } catch (e, stackTrace) {
        _log('❌ ERROR CALLING WEBRTC createOffer', e.toString());
        _log('❌ STACK TRACE', stackTrace.toString());
      }
    });

    socket.on('webrtc-signal', (data) async {
      _log('🔄 WEBRTC SIGNAL RECEIVED', {
        'from': data['from'],
        'signalType': data['signal']['type']
      });
      // Guard: ignore echo of our own signals (can happen if server pairs us with ourselves)
      if (data is Map && data['from'] == socket.id) {
        _log('🚫 IGNORING SELF-GENERATED WEBRTC SIGNAL ECHO', {
          'from': data['from'],
          'ourId': socket.id,
        });
        return;
      }
      
      final fromPeer = data['from'];
      if (fromPeer == null) {
        _log('❌ WEBRTC SIGNAL MISSING FROM PEER ID', data);
        return;
      }
      
      if (data['signal']['type'] == 'offer') {
        await _webrtcService.handleOffer(data['signal'], fromPeer);
      } else if (data['signal']['type'] == 'answer') {
        await _webrtcService.handleAnswer(data['signal'], fromPeer);
      } else if (data['signal']['type'] == 'candidate') {
        await _webrtcService.handleCandidate(data['signal'], fromPeer);
      }
    });

    // CRITICAL DEBUG: Log every single event to understand the server behavior
    socket.onAny((event, data) {
      _log('🔍 EVERY EVENT', {'event': event, 'data': data, 'ourId': socket.id});
      
      // Check for any events that might contain device/client information
      if (event.contains('device') || event.contains('client') || event.contains('user') || 
          event.contains('room') || event.contains('list') || event.contains('hello')) {
        _log('🔍 POTENTIAL DEVICE INFO EVENT', {'event': event, 'data': data});
        
        // Skip disconnection events here - they are handled by their specific handlers
        if (event == 'device-disconnected') {
          return;
        }
        
        // Try to extract device information from any event
        if (data is Map) {
          _tryExtractDeviceInfo(event, data.cast<String, dynamic>());
        } else if (data is List) {
          _log('🔍 LIST EVENT DATA', {'event': event, 'listLength': data.length, 'items': data});
          for (var item in data) {
            if (item is Map) {
              _tryExtractDeviceInfo(event, item.cast<String, dynamic>());
            }
          }
        }
      }
    });
    
    // Handle specific device list response events
    socket.on('devices', (data) {
      _log('📋 DEVICES EVENT', data);
      _handleDeviceListResponse(data);
    });
    
    socket.on('clients', (data) {
      _log('📋 CLIENTS EVENT', data);
      _handleDeviceListResponse(data);
    });
    
    socket.on('room-info', (data) {
      _log('📋 ROOM-INFO EVENT', data);
      if (data is Map && data['clients'] != null) {
        _handleDeviceListResponse(data['clients']);
      } else if (data is Map && data['devices'] != null) {
        _handleDeviceListResponse(data['devices']);
      }
    });

    socket.on('device-connected', (data) {
      _log('📱 DEVICE CONNECTED EVENT', data);
      _log('📱 OUR ID WHEN DEVICE CONNECTED', socket.id);
      
      if (data is Map) {
        final deviceId = data['id'] ?? data['socketId'] ?? data['clientId'];
        _log('📱 DEVICE ID IN EVENT', deviceId);
        _log('📱 IS THIS US?', deviceId == socket.id);
      }
      
      if (onDeviceConnected != null) {
        onDeviceConnected!(data);
      }
    });

    socket.on('device-disconnected', (data) {
      _log('📱 DEVICE DISCONNECTED EVENT', data);
      if (onDeviceDisconnected != null) {
        onDeviceDisconnected!(data);
      }
    });

    socket.on('share-available', (data) {
      _log('🚀 SHARE AVAILABLE', data);
    });

    // Handle clipboard share requests from other clients
    socket.on('request-share', (data) {
      _log('📥 RECEIVED CLIPBOARD REQUEST', data);
      
      // Extract requester information
      final fromDevice = data is Map ? data['from'] : null;
      if (fromDevice != null && fromDevice != socket.id) {
        _log('📋 INITIATING CLIPBOARD SHARE TO REQUESTER', fromDevice);
        
        // Create WebRTC offer to the requesting client
        if (_webrtcService != null) {
          _webrtcService!.createOffer(fromDevice).catchError((e) {
            _log('❌ ERROR CREATING OFFER FOR REQUEST', '$fromDevice: ${e.toString()}');
          });
        } else {
          _log('❌ WEBRTC SERVICE NOT AVAILABLE FOR REQUEST', fromDevice);
        }
      } else {
        _log('⚠️ INVALID REQUEST-SHARE DATA OR FROM SELF', data);
      }
    });

    // Handle hello messages from new clients
    socket.on('hello-i-am-here', (data) {
      _log('👋 RECEIVED HELLO FROM NEW CLIENT', data);
      
      // Respond back to let them know we exist
      if (data is Map && data['deviceId'] != null && data['deviceId'] != socket.id) {
        _log('👋 RESPONDING TO HELLO WITH OUR INFO');
        socket.emit('hello-response', {
          'deviceId': socket.id,
          'respondingTo': data['deviceId'],
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        });
        
        // Also treat this as a device connection
        if (onDeviceConnected != null) {
          onDeviceConnected!({
            'id': data['deviceId'],
            'deviceId': data['deviceId'],
            'name': 'Device ${data['deviceId']}',
            'discoveredVia': 'hello-exchange'
          });
        }
      }
    });

    // Handle responses to our hello message
    socket.on('hello-response', (data) {
      _log('👋 RECEIVED HELLO RESPONSE', data);
      
      // Add this device to our list
      if (data is Map && data['deviceId'] != null && data['deviceId'] != socket.id) {
        _log('👋 DISCOVERED EXISTING DEVICE VIA HELLO RESPONSE');
        if (onDeviceConnected != null) {
          onDeviceConnected!({
            'id': data['deviceId'],
            'deviceId': data['deviceId'],
            'name': 'Device ${data['deviceId']}',
            'discoveredVia': 'hello-response'
          });
        }
      }
    });

    socket.onDisconnect((reason) {
      _log('❌ DISCONNECTED FROM SERVER', reason);
    });
  }

  void sendShareReady() {
    _log('📤 SENDING SHARE-READY');
    socket.emit('share-ready');
  }

  // Defensive: explicitly clear any ready-to-share status before requesting
  void clearShareReady() {
    _log('🧹 CLEARING SHARE-READY STATE');
    // Try common event names the server might recognize
    socket.emit('share-not-ready');
    socket.emit('not-ready');
  }

  void sendRequestShare() {
    _log('📤 SENDING REQUEST-SHARE', {'from': socket.id});
    socket.emit('request-share', {
      'from': socket.id,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    });
  }

  void sendSignal(String to, dynamic signal) {
    _log('📤 SENDING WEBRTC SIGNAL', {
      'to': to,
      'signalType': signal['type'],
    });
    // Guard: do not send to ourselves
    if (to == socket.id) {
      _log('🚫 BLOCKED SENDING SIGNAL TO SELF', {
        'to': to,
        'ourId': socket.id,
        'signalType': signal['type'],
      });
      return;
    }
    
    socket.emit('webrtc-signal', {'to': to, 'signal': signal});
  }

  bool get isConnected => socket.connected;
  
  void reconnect() {
    _log('🔄 MANUAL RECONNECTION ATTEMPT');
    socket.disconnect();
    socket.connect();
  }
  
  void _tryExtractDeviceInfo(String event, Map<String, dynamic> data) {
    final possibleIdKeys = ['id', 'socketId', 'clientId', 'deviceId', 'userId'];
    
    for (var idKey in possibleIdKeys) {
      if (data[idKey] != null) {
        final deviceId = data[idKey].toString();
        if (deviceId != socket.id) {
          _log('🔍 FOUND DEVICE INFO', {
            'event': event,
            'deviceId': deviceId,
            'data': data
          });
          
          // Simulate a device-connected event
          if (onDeviceConnected != null) {
            onDeviceConnected!(data);
          }
        }
        break;
      }
    }
  }
  
  void _handleDeviceListResponse(dynamic data) {
    _log('📋 HANDLING DEVICE LIST RESPONSE', data);
    
    List<Map<String, dynamic>> devices = [];
    
    if (data is List) {
      for (var item in data) {
        if (item is Map) {
          final deviceId = item['id'] ?? item['socketId'] ?? item['clientId'] ?? item['deviceId'];
          if (deviceId != null && deviceId != socket.id) {
            devices.add(item.cast<String, dynamic>());
          }
        }
      }
    } else if (data is Map) {
      final deviceId = data['id'] ?? data['socketId'] ?? data['clientId'] ?? data['deviceId'];
      if (deviceId != null && deviceId != socket.id) {
        devices.add(data.cast<String, dynamic>());
      }
    }
    
    if (devices.isNotEmpty && onConnectedDevicesList != null) {
      _log('📋 SENDING DEVICE LIST TO UI', devices);
      onConnectedDevicesList!(devices);
    }
  }
}
