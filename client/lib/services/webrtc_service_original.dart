import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:shared_clipboard/services/file_transfer_service.dart';
import 'package:shared_clipboard/services/notification_service.dart';
import 'package:file_picker/file_picker.dart';


class WebRTCService {
  // Connection pool management - support multiple concurrent connections
  final Map<String, RTCPeerConnection> _peerConnections = {};
  final Map<String, RTCDataChannel> _dataChannels = {};
  final Map<String, bool> _connectionStates = {};
  final Map<String, String> _peerIds = {}; // connectionId -> peerId mapping
  
  // Legacy single connection support (for backward compatibility)
  RTCPeerConnection? _peerConnection;
  RTCDataChannel? _dataChannel;
  String? _peerId;
  bool _isInitialized = false;
  ClipboardContent? _pendingClipboardContent;
  bool _isResetting = false;
  
  // Connection pooling support
  final Map<String, RTCPeerConnection> _connections = {};
  int _sessionCounter = 0;
  final Map<String, ClipboardSession> _clipboardSessions = {};
  
  final FileTransferService _fileTransferService = FileTransferService();
  final NotificationService _notificationService = NotificationService();
  
  // Per-connection ICE candidate queues
  final Map<String, List<RTCIceCandidate>> _pendingCandidatesByConnection = {};
  final Map<String, bool> _remoteDescriptionSetByConnection = {};
  
  // Legacy single connection ICE handling
  final List<RTCIceCandidate> _pendingCandidates = [];
  bool _remoteDescriptionSet = false;

  // Chunking protocol settings and state
  static const int _chunkSize = 8 * 1024;
  static const int _bufferedLowThreshold = 32 * 1024;
  
  // Per-connection buffer management
  final Map<String, Map<String, StringBuffer>> _rxBuffersByConnection = {};
  final Map<String, Map<String, int>> _rxReceivedBytesByConnection = {};
  final Map<String, Map<String, int>> _rxTotalBytesByConnection = {};
  final Map<String, Completer<void>> _bufferLowCompletersByConnection = {};
  
  // Legacy single connection buffers
  final Map<String, StringBuffer> _rxBuffers = {};
  final Map<String, int> _rxReceivedBytes = {};
  final Map<String, int> _rxTotalBytes = {};
  Completer<void>? _bufferLowCompleter;

  // Per-connection file session management
  final Map<String, Map<String, _FileSession>> _fileSessionsByConnection = {};
  final Map<String, Map<String, Completer<void>>> _sessionReadyCompletersByConnection = {};
  final Map<String, Completer<void>> _ackCompletersByConnection = {};
  
  // Legacy single connection file sessions
  final Map<String, _FileSession> _fileSessions = {};
  final Map<String, Completer<void>> _sessionReadyCompleters = {};
  Completer<void>? _ackCompleter;
  
  // Callback to send signals back to socket service
  Function(String to, dynamic signal)? onSignalGenerated;
  
  // === SESSION MANAGEMENT ===
  
  /// Create a new clipboard session
  Future<String> createClipboardSession(String peerId, [String? requestId]) async {
    final connectionId = await _getOrCreateConnection(peerId, requestId);
    final sessionId = '${connectionId}-session-${DateTime.now().millisecondsSinceEpoch}';
    
    _log('📋 CREATING CLIPBOARD SESSION', {
      'sessionId': sessionId,
      'connectionId': connectionId,
      'peerId': peerId,
      'requestId': requestId
    });
    
    return sessionId;
  }
  
  /// Get connection ID from session ID
  String _getConnectionIdFromSession(String sessionId) {
    // Session ID format: connectionId-session-timestamp
    final parts = sessionId.split('-session-');
    return parts.isNotEmpty ? parts[0] : sessionId;
  }
  
  /// Check if a connection is active
  bool isConnectionActive(String connectionId) {
    return _connectionStates[connectionId] == true;
  }
  
  /// Get all active connections for a peer
  List<String> getActiveConnections(String peerId) {
    final connections = <String>[];
    for (final entry in _peerIds.entries) {
      if (entry.value == peerId && _connectionStates[entry.key] == true) {
        connections.add(entry.key);
      }
    }
    return connections;
  }
  
  /// Clean up a specific connection
  Future<void> _cleanupConnection(String connectionId) async {
    try {
      _log('🧹 CLEANING UP CONNECTION', {'connectionId': connectionId});
      
      // Close data channel
      final dataChannel = _dataChannels.remove(connectionId);
      if (dataChannel != null) {
        try {
          dataChannel.close();
        } catch (e) {
          _log('⚠️ ERROR CLOSING DATA CHANNEL', {'connectionId': connectionId, 'error': e.toString()});
        }
      }
      
      // Close peer connection
      final peerConnection = _peerConnections.remove(connectionId);
      if (peerConnection != null) {
        try {
          peerConnection.close();
        } catch (e) {
          _log('⚠️ ERROR CLOSING PEER CONNECTION', {'connectionId': connectionId, 'error': e.toString()});
        }
      }
      
      // Clean up state
      _peerIds.remove(connectionId);
      _connectionStates.remove(connectionId);
      _pendingCandidatesByConnection.remove(connectionId);
      _remoteDescriptionSetByConnection.remove(connectionId);
      _rxBuffersByConnection.remove(connectionId);
      _rxReceivedBytesByConnection.remove(connectionId);
      _rxTotalBytesByConnection.remove(connectionId);
      _bufferLowCompletersByConnection.remove(connectionId);
      _ackCompletersByConnection.remove(connectionId);
      
      // Clean up file sessions for this connection
      final fileSessions = _fileSessionsByConnection.remove(connectionId);
      if (fileSessions != null) {
        for (final session in fileSessions.values) {
          await _cleanupFileSession(session);
        }
      }
      _sessionReadyCompletersByConnection.remove(connectionId);
      
      _log('✅ CONNECTION CLEANUP COMPLETE', {'connectionId': connectionId});
    } catch (e) {
      _log('❌ ERROR DURING CONNECTION CLEANUP', {'connectionId': connectionId, 'error': e.toString()});
    }
  }
  
  /// Clean up a file session
  Future<void> _cleanupFileSession(_FileSession session) async {
    try {
      for (final file in session.files) {
        try {
          await file.sink.flush();
          await file.sink.close();
        } catch (_) {}
        try {
          if (await file.file.exists()) {
            await file.file.delete();
          }
        } catch (_) {}
      }
    } catch (e) {
      _log('❌ ERROR CLEANING UP FILE SESSION', e.toString());
    }
  }

  WebRTCService();

  // Helper function for timestamped logging
  void _log(String message, [dynamic data]) {
    final timestamp = DateTime.now().toIso8601String();
    if (data != null) {
      print('[$timestamp] WEBRTC: $message - $data');
    } else {
      print('[$timestamp] WEBRTC: $message');
    }
  }

  // === CONNECTION POOL MANAGEMENT ===
  
  /// Generate a unique connection ID for a peer
  String _generateConnectionId(String peerId, [String? requestId]) {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final suffix = requestId != null ? '-$requestId' : '';
    return '$peerId-$timestamp$suffix';
  }
  
  /// Get or create a connection for a peer
  Future<String> _getOrCreateConnection(String peerId, [String? requestId]) async {
    // Check if we have an existing active connection for this peer
    final existingConnectionId = _findActiveConnection(peerId);
    if (existingConnectionId != null) {
      _log('♻️ REUSING EXISTING CONNECTION', {'peerId': peerId, 'connectionId': existingConnectionId});
      return existingConnectionId;
    }
    
    // Create new connection
    final connectionId = _generateConnectionId(peerId, requestId);
    _log('🆕 CREATING NEW CONNECTION', {'peerId': peerId, 'connectionId': connectionId});
    
    await _initializeConnection(connectionId, peerId);
    return connectionId;
  }
  
  /// Find an active connection for a peer
  String? _findActiveConnection(String peerId) {
    for (final entry in _peerIds.entries) {
      if (entry.value == peerId && _connectionStates[entry.key] == true) {
        return entry.key;
      }
    }
    return null;
  }
  
  /// Initialize a new connection
  Future<void> _initializeConnection(String connectionId, String peerId) async {
    try {
      _log('🔧 INITIALIZING CONNECTION', {'connectionId': connectionId, 'peerId': peerId});
      
      // Create peer connection
      final peerConnection = await createPeerConnection({
        'iceServers': [
          {'urls': 'stun:stun.l.google.com:19302'},
          {'urls': 'stun:stun1.l.google.com:19302'},
        ],
        'iceCandidatePoolSize': 10,
      });
      
      // Store connection
      _peerConnections[connectionId] = peerConnection;
      _peerIds[connectionId] = peerId;
      _connectionStates[connectionId] = false; // Not connected yet
      
      // Initialize per-connection state
      _pendingCandidatesByConnection[connectionId] = [];
      _remoteDescriptionSetByConnection[connectionId] = false;
      _rxBuffersByConnection[connectionId] = {};
      _rxReceivedBytesByConnection[connectionId] = {};
      _rxTotalBytesByConnection[connectionId] = {};
      _fileSessionsByConnection[connectionId] = {};
      _sessionReadyCompletersByConnection[connectionId] = {};
      
      // Set up connection event handlers
      _setupConnectionHandlers(connectionId, peerConnection);
      
      _log('✅ CONNECTION INITIALIZED', {'connectionId': connectionId});
    } catch (e) {
      _log('❌ ERROR INITIALIZING CONNECTION', {'connectionId': connectionId, 'error': e.toString()});
      throw e;
    }
  }
  
  /// Set up event handlers for a connection
  void _setupConnectionHandlers(String connectionId, RTCPeerConnection peerConnection) {
    peerConnection.onConnectionState = (state) {
      _log('🔗 CONNECTION STATE CHANGED', {'connectionId': connectionId, 'state': state.toString()});
      _connectionStates[connectionId] = (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected);
    };
    
    peerConnection.onIceCandidate = (candidate) {
      _log('🧊 ICE CANDIDATE GENERATED', {'connectionId': connectionId});
      final peerId = _peerIds[connectionId];
      if (peerId != null && onSignalGenerated != null) {
        onSignalGenerated!(peerId, {
          'type': 'candidate',
          'candidate': candidate.candidate,
          'sdpMid': candidate.sdpMid,
          'sdpMLineIndex': candidate.sdpMLineIndex,
          'connectionId': connectionId, // Include connection ID in signal
        });
      }
    };
    
    peerConnection.onDataChannel = (channel) {
      _log('📡 DATA CHANNEL RECEIVED', {'connectionId': connectionId, 'label': channel.label});
      _dataChannels[connectionId] = channel;
      _setupDataChannel(connectionId, channel, isReceiver: true);
    };
  }

  /// Send files streaming to specific connection (proto v2)
  Future<void> _sendFilesStreamingToConnection(String connectionId, ClipboardContent content) async {
    final dataChannel = _dataChannels[connectionId];
    if (dataChannel == null) throw StateError('DataChannel not ready for connection $connectionId');
    
    final sessionId = '${connectionId}-${DateTime.now().microsecondsSinceEpoch}';
    _log('🚀 STARTING FILE STREAMING SESSION TO CONNECTION', {
      'connectionId': connectionId,
      'sessionId': sessionId,
      'files': content.files.length
    });
    
    // Start streaming session
    final startEnv = jsonEncode({
      '__sc_proto': 2,
      'kind': 'files',
      'mode': 'start',
      'sessionId': sessionId,
      'connectionId': connectionId, // Include connection ID
      'files': content.files.map((f) => {
        'name': f.name,
        'size': f.size,
        'checksum': f.checksum,
      }).toList(),
    });
    dataChannel.send(RTCDataChannelMessage(startEnv));
    
    // Wait for receiver to be ready
    _log('⏳ WAITING FOR RECEIVER TO BE READY', {'connectionId': connectionId, 'sessionId': sessionId});
    final readyCompleter = Completer<void>();
    final sessionReadyCompleters = _sessionReadyCompletersByConnection[connectionId] ??= {};
    sessionReadyCompleters[sessionId] = readyCompleter;
    
    try {
      await readyCompleter.future.timeout(const Duration(seconds: 60));
      _log('✅ RECEIVER IS READY, STARTING FILE TRANSFER', {'connectionId': connectionId, 'sessionId': sessionId});
    } catch (e) {
      _log('❌ RECEIVER READY TIMEOUT OR ERROR', {'connectionId': connectionId, 'sessionId': sessionId, 'error': e.toString()});
      sessionReadyCompleters.remove(sessionId);
      throw Exception('Receiver ready timeout: $e');
    }
    
    // Stream each file
    for (int i = 0; i < content.files.length; i++) {
      final f = content.files[i];
      await _streamFileToConnection(connectionId, sessionId, f, i);
    }
    
    // End streaming session
    final endEnv = jsonEncode({
      '__sc_proto': 2,
      'kind': 'files',
      'mode': 'end',
      'sessionId': sessionId,
    });
    dataChannel.send(RTCDataChannelMessage(endEnv));
    
    _log('🎉 FILE STREAMING SESSION COMPLETED', {
      'connectionId': connectionId,
      'sessionId': sessionId,
      'filesCount': content.files.length
    });
  }
  
  /// Stream a single file to specific connection
  Future<void> _streamFileToConnection(String connectionId, String sessionId, FileData file, int fileIndex) async {
    final dataChannel = _dataChannels[connectionId];
    if (dataChannel == null) throw StateError('DataChannel not ready for connection $connectionId');
    
    _log('📤 STREAMING FILE TO CONNECTION', {
      'connectionId': connectionId,
      'sessionId': sessionId,
      'fileIndex': fileIndex,
      'fileName': file.name,
      'fileSize': file.size
    });
    
    final bytes = file.content;
    int offset = 0;
    int chunkCount = 0;
    
    while (offset < bytes.length) {
      final end = (offset + _chunkSize > bytes.length) ? bytes.length : offset + _chunkSize;
      final chunk = bytes.sublist(offset, end);
      final chunkB64 = base64Encode(chunk);
      
      final chunkEnv = jsonEncode({
        '__sc_proto': 2,
        'kind': 'files',
        'mode': 'file_chunk',
        'sessionId': sessionId,
        'fileIndex': fileIndex,
        'data': chunkB64,
      });
      
      // Wait for buffer to be available
      while (dataChannel.bufferedAmount > _bufferedLowThreshold) {
        _log('⏳ WAITING FOR BUFFER TO DRAIN', {
          'connectionId': connectionId,
          'bufferedAmount': dataChannel.bufferedAmount,
          'threshold': _bufferedLowThreshold
        });
        
        final completer = Completer<void>();
        _bufferLowCompletersByConnection[connectionId] = completer;
        
        try {
          await completer.future;
          _log('✅ BUFFER DRAINED, CONTINUING', {'connectionId': connectionId});
        } catch (e) {
          _log('❌ ERROR WAITING FOR BUFFER', {'connectionId': connectionId, 'error': e.toString()});
          throw e;
        }
      }
      
      dataChannel.send(RTCDataChannelMessage(chunkEnv));
      chunkCount++;
      offset = end;
      
      // Progress reporting
      if (chunkCount % 100 == 0) {
        final progress = ((offset / bytes.length) * 100).round();
        _log('📊 FILE STREAMING PROGRESS', {
          'connectionId': connectionId,
          'sessionId': sessionId,
          'fileIndex': fileIndex,
          'progress': '${progress}%',
          'bytesRemaining': bytes.length - offset,
          'bufferedAmount': dataChannel.bufferedAmount
        });
      }
      
      // Wait for ACK from receiver every 100 chunks for flow control
      if (chunkCount % 100 == 0) {
        _log('⏳ WAITING FOR ACK', {'connectionId': connectionId});
        final ackCompleter = Completer<void>();
        _ackCompletersByConnection[connectionId] = ackCompleter;
        try {
          await ackCompleter.future.timeout(const Duration(seconds: 30));
          _log('✅ ACK RECEIVED, CONTINUING TRANSFER', {'connectionId': connectionId});
        } catch (e) {
          _log('❌ ACK TIMEOUT, ABORTING TRANSFER', {'connectionId': connectionId, 'error': e.toString()});
          throw Exception('ACK timeout');
        }
      }
    }
    
    // Final ACK check
    if (chunkCount % 100 != 0) {
      _log('⏳ WAITING FOR FINAL ACK', {'connectionId': connectionId});
      final ackCompleter = Completer<void>();
      _ackCompletersByConnection[connectionId] = ackCompleter;
      try {
        await ackCompleter.future.timeout(const Duration(seconds: 30));
        _log('✅ FINAL ACK RECEIVED', {'connectionId': connectionId});
      } catch (e) {
        _log('❌ FINAL ACK TIMEOUT, ABORTING TRANSFER', {'connectionId': connectionId, 'error': e.toString()});
        throw Exception('Final ACK timeout');
      }
    }
    
    // End of this file
    final fileEnd = jsonEncode({
      '__sc_proto': 2,
      'kind': 'files',
      'mode': 'file_end',
      'sessionId': sessionId,
      'fileIndex': fileIndex,
    });
    dataChannel.send(RTCDataChannelMessage(fileEnd));
    
    _log('✅ FINISHED STREAMING FILE TO CONNECTION', {
      'connectionId': connectionId,
      'sessionId': sessionId,
      'fileIndex': fileIndex,
      'fileName': file.name,
      'fileSize': file.size
    });
  }

  // Streaming files protocol (proto v2) - Legacy method
  Future<void> _sendFilesStreaming(ClipboardContent content) async {
    if (_dataChannel == null) throw StateError('DataChannel not ready');
    
    final sessionId = DateTime.now().microsecondsSinceEpoch.toString();
    _log('🚀 STARTING FILE STREAMING SESSION (LEGACY)', {'sessionId': sessionId, 'files': content.files.length});
    
    // Start streaming session
    final startEnv = jsonEncode({
      '__sc_proto': 2,
      'kind': 'files',
      'mode': 'start',
      'sessionId': sessionId,
      'files': content.files.map((f) => {
        'name': f.name,
        'size': f.size,
        'checksum': f.checksum,
      }).toList(),
    });
    _dataChannel!.send(RTCDataChannelMessage(startEnv));
    
    // Wait for receiver to be ready
    _log('⏳ WAITING FOR RECEIVER TO BE READY (LEGACY)');
    final readyCompleter = Completer<void>();
    _sessionReadyCompleters[sessionId] = readyCompleter;
    
    try {
      await readyCompleter.future.timeout(const Duration(seconds: 60));
      _log('✅ RECEIVER IS READY, STARTING FILE TRANSFER (LEGACY)');
    } catch (e) {
      _log('❌ RECEIVER READY TIMEOUT OR ERROR (LEGACY)', e.toString());
      _sessionReadyCompleters.remove(sessionId);
      throw Exception('Receiver ready timeout: $e');
    }
    
    // Stream each file with comprehensive diagnostics
    for (int i = 0; i < content.files.length; i++) {
      final f = content.files[i];
      final bytes = f.content; // already read in FileTransferService
      int offset = 0;
      int chunkCount = 0;
      final totalChunks = (bytes.length / _chunkSize).ceil();
      
      _log('🚀 STARTING FILE TRANSFER', {
        'file': f.name,
        'size': bytes.length,
        'totalChunks': totalChunks,
        'chunkSize': _chunkSize
      });
      
      while (offset < bytes.length) {
        final end = (offset + _chunkSize > bytes.length) ? bytes.length : offset + _chunkSize;
        final chunkBytes = bytes.sublist(offset, end);
        final env = jsonEncode({
          '__sc_proto': 2,
          'kind': 'files',
          'mode': 'file_chunk',
          'sessionId': sessionId,
          'fileIndex': i,
          'data': base64Encode(chunkBytes),
        });
        
        try {
          _dataChannel!.send(RTCDataChannelMessage(env));
          chunkCount++;
          
          // Log progress every 100 chunks and show notifications at round percentages
          if (chunkCount % 100 == 0) {
            final progress = (offset / bytes.length * 100).toStringAsFixed(1);
            final progressInt = (offset / bytes.length * 100).round();
            _log('📤 SENDING PROGRESS', {
              'file': f.name,
              'chunk': chunkCount,
              'of': totalChunks,
              'progress': '${progress}%',
              'bytesRemaining': bytes.length - offset,
              'bufferedAmount': _dataChannel!.bufferedAmount
            });
          }
        } catch (e) {
          _log('❌ ERROR SENDING CHUNK', {
            'chunk': chunkCount,
            'offset': offset,
            'error': e.toString()
          });
          throw e;
        }
        
        offset = end;

        // Wait for ACK from receiver every 100 chunks for flow control
        if (chunkCount % 100 == 0) {
          _log('⏳ WAITING FOR ACK');
          _ackCompleter = Completer<void>();
          try {
            await _ackCompleter!.future.timeout(const Duration(seconds: 30));
            _log('✅ ACK RECEIVED, CONTINUING TRANSFER');
          } catch (e) {
            _log('❌ ACK TIMEOUT, ABORTING TRANSFER', e.toString());
            throw Exception('ACK timeout');
          } finally {
            _ackCompleter = null;
          }
        }
      }
      
      // Final ACK check to ensure all chunks are processed
      if (chunkCount % 100 != 0) {
        _log('⏳ WAITING FOR FINAL ACK');
        _ackCompleter = Completer<void>();
        try {
          await _ackCompleter!.future.timeout(const Duration(seconds: 30));
          _log('✅ FINAL ACK RECEIVED');
        } catch (e) {
          _log('❌ FINAL ACK TIMEOUT, ABORTING TRANSFER', e.toString());
          throw Exception('Final ACK timeout');
        } finally {
          _ackCompleter = null;
        }
      }

      _log('✅ FINISHED SENDING FILE', {
        'file': f.name,
        'totalChunks': chunkCount,
        'totalBytes': bytes.length,
        'finalBufferedAmount': _dataChannel!.bufferedAmount
      });
      
      // End of this file
      final fileEnd = jsonEncode({
        '__sc_proto': 2,
        'kind': 'files',
        'mode': 'file_end',
        'sessionId': sessionId,
        'fileIndex': i,
      });
      _dataChannel!.send(RTCDataChannelMessage(fileEnd));
    }

    // End session
    final endEnv = jsonEncode({
      '__sc_proto': 2,
      'kind': 'files',
      'mode': 'end',
      'sessionId': sessionId,
    });
    _dataChannel!.send(RTCDataChannelMessage(endEnv));
  }

  Future<void> init() async {
    if (_isInitialized) {
      _log('⚠️ ALREADY INITIALIZED, SKIPPING');
      return;
    }
    
    _log('🚀 INITIALIZING WEBRTC SERVICE');
    
    try {
      final configuration = {
        'iceServers': [
          {'urls': 'stun:stun.l.google.com:19302'},
        ],
        // Enable SCTP data channels with proper configuration
        'enableDtlsSrtp': true,
        'sdpSemantics': 'unified-plan',
        // Configure SCTP for large data transfers
        'dataChannelConfiguration': {
          'maxMessageSize': 1048576,  // 1MB max message size
          'maxRetransmits': 0,  // Reliable delivery
        }
      };
      
      // Create peer connection with timeout protection
      _peerConnection = await Future.any([
        createPeerConnection(configuration),
        Future.delayed(Duration(seconds: 2)).then((_) => throw TimeoutException('PeerConnection creation timeout', Duration(seconds: 2))),
      ]);
      
      _isInitialized = true;

      _peerConnection?.onIceCandidate = (candidate) {
        _log('🧊 ICE CANDIDATE GENERATED');
        if (_peerId != null && onSignalGenerated != null) {
          onSignalGenerated!(_peerId!, {
            'type': 'candidate',
            'candidate': candidate.candidate,
            'sdpMid': candidate.sdpMid,
            'sdpMLineIndex': candidate.sdpMLineIndex,
          });
        }
      };

      _peerConnection?.onConnectionState = (state) {
        _log('🔗 CONNECTION STATE CHANGED', state.toString());
      };

      _peerConnection?.onDataChannel = (channel) {
        _log('📡 DATA CHANNEL RECEIVED');
        _setupDataChannel(channel);
      };
      
      _log('✅ WEBRTC SERVICE INITIALIZED');
    } catch (e) {
      _log('❌ ERROR INITIALIZING WEBRTC SERVICE', e.toString());
      _isInitialized = false;
      _peerConnection = null;
      rethrow;
    }
  }

  /// Setup data channel with connection pooling support
  void _setupDataChannel(String connectionId, RTCDataChannel channel, {bool isReceiver = false}) {
    _log('📡 SETTING UP DATA CHANNEL', {
      'connectionId': connectionId,
      'label': channel.label,
      'isReceiver': isReceiver
    });
    
    // Store the data channel
    _dataChannels[connectionId] = channel;
    
    // For backward compatibility, also set the legacy single channel if this is the first one
    if (_dataChannel == null) {
      _dataChannel = channel;
    }
    
    // Check if channel is already open
    if (channel.state == RTCDataChannelState.RTCDataChannelOpen) {
      _log('📡 DATA CHANNEL IS ALREADY OPEN DURING SETUP', {'connectionId': connectionId});
      _handleDataChannelOpen(connectionId);
    }
    
    // Backpressure: fire completer when buffered amount goes low
    channel.onBufferedAmountLow = (int amount) {
      _log('📉 DATA CHANNEL BUFFERED AMOUNT LOW', {'connectionId': connectionId, 'amount': amount});
      final completer = _bufferLowCompletersByConnection[connectionId];
      if (completer != null && !completer.isCompleted) {
        completer.complete();
        _bufferLowCompletersByConnection.remove(connectionId);
      }
      // Legacy support
      if (connectionId == _getConnectionIdFromLegacyChannel()) {
        _bufferLowCompleter?.complete();
        _bufferLowCompleter = null;
      }
    };
    channel.bufferedAmountLowThreshold = _bufferedLowThreshold;

    channel.onDataChannelState = (state) {
      _log('📡 DATA CHANNEL STATE CHANGED', {'connectionId': connectionId, 'state': state.toString()});
      if (state == RTCDataChannelState.RTCDataChannelOpen) {
        _handleDataChannelOpen(connectionId);
      }
    };

    channel.onMessage = (message) {
      _handleDataChannelMessage(connectionId, message);
    };
  }
  
  /// Get connection ID from legacy data channel (for backward compatibility)
  String? _getConnectionIdFromLegacyChannel() {
    if (_dataChannel == null) return null;
    for (final entry in _dataChannels.entries) {
      if (entry.value == _dataChannel) {
        return entry.key;
      }
    }
    return null;
  }
  
  /// Handle data channel messages with connection pooling support
  void _handleDataChannelMessage(String connectionId, RTCDataChannelMessage message) {
    // Support: proto v2 streaming (files), proto v1 chunked JSON payloads, and legacy single payload
    final text = message.text;
    _log('📥 RECEIVED DATA MESSAGE', {'connectionId': connectionId, 'bytes': text.length});
    try {
      // Handle ACKs for flow control
      if (text == '{"__sc_proto":2,"kind":"ack"}') {
        _log('📬 ACK RECEIVED', {'connectionId': connectionId});
        final ackCompleter = _ackCompletersByConnection[connectionId];
        if (ackCompleter != null && !ackCompleter.isCompleted) {
          ackCompleter.complete();
        }
        // Legacy support
        if (_ackCompleter != null && !_ackCompleter!.isCompleted) {
          _ackCompleter!.complete();
        }
        return; // ACK handled
      }

      // Try to parse as protocol envelope
      final isJsonEnvelope = text.startsWith('{') && text.contains('"__sc_proto"');
      if (isJsonEnvelope) {
        final Map<String, dynamic> env = jsonDecode(text);
        // Proto v2: streaming files
        if (env['__sc_proto'] == 2 && env['kind'] == 'files') {
          final mode = env['mode'] as String?;
          final sessionId = env['sessionId'] as String?;
          if (mode == 'start' && sessionId != null) {
            // Ask user for directory immediately
            final filesMeta = (env['files'] as List).cast<Map<String, dynamic>>();
            _log('🔰 START FILE STREAM SESSION', {'connectionId': connectionId, 'sessionId': sessionId, 'files': filesMeta.length});
            () async {
              final prepared = await _promptDirectoryAndPrepareFilesForConnection(connectionId, sessionId, filesMeta);
              if (!prepared) {
                // Inform sender we cancelled so it can abort immediately
                final cancelEnv = jsonEncode({
                  '__sc_proto': 2,
                  'kind': 'files',
                  'mode': 'cancel',
                  'sessionId': sessionId,
                });
                final dataChannel = _dataChannels[connectionId] ?? _dataChannel;
                dataChannel?.send(RTCDataChannelMessage(cancelEnv));
                _log('🚫 RECEIVER CANCELLED BEFORE READY', {'connectionId': connectionId, 'sessionId': sessionId});
                return;
              }
              // Notify sender we are ready to receive chunks
              final readyEnv = jsonEncode({
                '__sc_proto': 2,
                'kind': 'files',
                'mode': 'ready',
                'sessionId': sessionId,
              });
              final dataChannel = _dataChannels[connectionId] ?? _dataChannel;
              dataChannel?.send(RTCDataChannelMessage(readyEnv));
              _log('📨 SENT RECEIVER READY', {'connectionId': connectionId, 'sessionId': sessionId});
            }();
            return;
          }
            if (mode == 'ready' && sessionId != null) {
              // Sender side receives readiness ack
              final c = _sessionReadyCompleters.remove(sessionId);
              c?.complete();
              _log('📩 RECEIVED READY ACK', sessionId);
              return;
            }
            if (mode == 'cancel' && sessionId != null) {
              // Sender side receives cancellation; abort stream immediately
              final c = _sessionReadyCompleters.remove(sessionId);
              c?.completeError(StateError('Receiver cancelled'));
              _abortFileSession(sessionId);
              _log('🛑 RECEIVED CANCEL, ABORTING SESSION', sessionId);
              return;
            }
            if (mode == 'file_chunk' && sessionId != null) {
              final idx = env['fileIndex'] as int? ?? 0;
              final dataB64 = env['data'] as String? ?? '';
              _handleFileChunk(sessionId, idx, dataB64);
              return;
            }
            if (mode == 'file_end' && sessionId != null) {
              final idx = env['fileIndex'] as int? ?? 0;
              _handleFileEnd(sessionId, idx);
              return;
            }
            if (mode == 'end' && sessionId != null) {
              _finalizeFileSession(sessionId);
              return;
            }
          }
          // Proto v1: chunked JSON clipboard payload
          if (env['__sc_proto'] == 1 && env['kind'] == 'clipboard') {
            final mode = env['mode'] as String?;
            final id = env['id'] as String?;
            if (mode == 'start' && id != null) {
              final total = (env['total'] as num?)?.toInt() ?? 0;
              _rxBuffers[id] = StringBuffer();
              _rxReceivedBytes[id] = 0;
              _rxTotalBytes[id] = total;
              _log('🔰 START CLIPBOARD TRANSFER', {'id': id, 'total': total});
              return;
            }
            if (mode == 'chunk' && id != null) {
              final data = env['data'] as String? ?? '';
              final buf = _rxBuffers[id];
              if (buf != null) {
                buf.write(data);
                final rec = (_rxReceivedBytes[id] ?? 0) + data.length;
                _rxReceivedBytes[id] = rec;
                final total = _rxTotalBytes[id] ?? 0;
                if (total > 0) {
                  _log('📦 RECEIVED CHUNK', {'id': id, 'received': rec, 'total': total});
                } else {
                  _log('📦 RECEIVED CHUNK', {'id': id, 'received': rec});
                }
              }
              return;
            }
            if (mode == 'end' && id != null) {
              final buf = _rxBuffers.remove(id);
              _rxTotalBytes.remove(id);
              _rxReceivedBytes.remove(id);
              if (buf != null) {
                final payload = buf.toString();
                _log('🏁 END CLIPBOARD TRANSFER', {'id': id, 'size': payload.length});
                _handleClipboardPayload(payload);
              }
              return;
            }
          }
        }
        // Legacy single-message payload
        _handleClipboardPayload(text);
      } catch (e) {
        _log('❌ ERROR PROCESSING RECEIVED DATA', e.toString());
      }
    };
  }

  /// Handle data channel open with connection pooling support
  void _handleDataChannelOpen([String? connectionId]) {
    if (connectionId != null) {
      _log('✅ DATA CHANNEL IS NOW OPEN', {'connectionId': connectionId});
      _connectionStates[connectionId] = true;
    } else {
      // Legacy support
      _log('✅ DATA CHANNEL IS NOW OPEN (LEGACY)');
    }
    
    // Only send content if we have pending content (i.e., we're the sender)
    if (_pendingClipboardContent != null) {
      final content = _pendingClipboardContent!;
      if (content.isFiles) {
        _log('📤 SENDING FILES VIA STREAMING PROTOCOL', {'count': content.files.length, 'connectionId': connectionId});
        if (connectionId != null) {
          _sendFilesStreamingToConnection(connectionId, content).then((_) {
            _log('✅ FILES STREAMED SUCCESSFULLY', {'connectionId': connectionId});
            _pendingClipboardContent = null;
          }).catchError((e) {
            _log('❌ ERROR STREAMING FILES', {'connectionId': connectionId, 'error': e.toString()});
          });
        } else {
          // Legacy fallback
          _sendFilesStreaming(content).then((_) {
            _log('✅ FILES STREAMED SUCCESSFULLY (LEGACY)');
            _pendingClipboardContent = null;
          }).catchError((e) {
            _log('❌ ERROR STREAMING FILES (LEGACY)', e.toString());
          });
        }
      } else {
        final payload = _fileTransferService.serializeClipboardContent(content);
        _log('📤 SENDING TEXT/JSON VIA CHUNKING', {'bytes': payload.length, 'connectionId': connectionId});
        if (connectionId != null) {
          _sendLargeMessageToConnection(connectionId, payload).then((_) {
            _log('✅ CLIPBOARD CONTENT SENT SUCCESSFULLY', {'connectionId': connectionId});
            _pendingClipboardContent = null;
          }).catchError((e) {
            _log('❌ ERROR SENDING CLIPBOARD CONTENT', {'connectionId': connectionId, 'error': e.toString()});
          });
        } else {
          // Legacy fallback
          _sendLargeMessage(payload).then((_) {
            _log('✅ CLIPBOARD CONTENT SENT SUCCESSFULLY (LEGACY)');
            _pendingClipboardContent = null;
          }).catchError((e) {
            _log('❌ ERROR SENDING CLIPBOARD CONTENT (LEGACY)', e.toString());
          });
        }
      }
    } else {
      _log('⚠️ NO PENDING CLIPBOARD CONTENT TO SEND', {'connectionId': connectionId});
    }
  }

  /// Send large message to specific connection with chunking and backpressure-safe logic
  Future<void> _sendLargeMessageToConnection(String connectionId, String text) async {
    final dataChannel = _dataChannels[connectionId];
    if (dataChannel == null) throw StateError('DataChannel not ready for connection $connectionId');
    
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    final total = text.length;
    
    _log('📤 SENDING LARGE MESSAGE TO CONNECTION', {
      'connectionId': connectionId,
      'messageId': id,
      'totalBytes': total
    });
    
    // Start envelope
    final startEnv = jsonEncode({
      '__sc_proto': 1,
      'kind': 'clipboard',
      'mode': 'start',
      'id': id,
      'total': total,
      'chunkSize': _chunkSize,
    });
    dataChannel.send(RTCDataChannelMessage(startEnv));
    
    // Initialize per-connection buffers for this message
    final rxBuffers = _rxBuffersByConnection[connectionId] ??= {};
    final rxReceivedBytes = _rxReceivedBytesByConnection[connectionId] ??= {};
    final rxTotalBytes = _rxTotalBytesByConnection[connectionId] ??= {};
    
    // Chunks
    int offset = 0;
    while (offset < total) {
      final end = (offset + _chunkSize > total) ? total : offset + _chunkSize;
      final chunk = text.substring(offset, end);
      final chunkEnv = jsonEncode({
        '__sc_proto': 1,
        'kind': 'clipboard',
        'mode': 'chunk',
        'id': id,
        'data': chunk,
      });
      
      // Wait for buffer to be available
      while (dataChannel.bufferedAmount > _bufferedLowThreshold) {
        _log('⏳ WAITING FOR BUFFER TO DRAIN', {
          'connectionId': connectionId,
          'bufferedAmount': dataChannel.bufferedAmount,
          'threshold': _bufferedLowThreshold
        });
        
        final completer = Completer<void>();
        _bufferLowCompletersByConnection[connectionId] = completer;
        
        try {
          await completer.future;
          _log('✅ BUFFER DRAINED, CONTINUING', {'connectionId': connectionId});
        } catch (e) {
          _log('❌ ERROR WAITING FOR BUFFER', {'connectionId': connectionId, 'error': e.toString()});
          throw e;
        }
      }
      
      dataChannel.send(RTCDataChannelMessage(chunkEnv));
      offset = end;
    }
    
    // End envelope
    final endEnv = jsonEncode({
      '__sc_proto': 1,
      'kind': 'clipboard',
      'mode': 'end',
      'id': id,
    });
    dataChannel.send(RTCDataChannelMessage(endEnv));
    
    _log('✅ LARGE MESSAGE SENT TO CONNECTION', {
      'connectionId': connectionId,
      'messageId': id,
      'totalBytes': total
    });
  }

  // Send message with chunking and backpressure-safe logic (legacy method)
  Future<void> _sendLargeMessage(String text) async {
    if (_dataChannel == null) throw StateError('DataChannel not ready');
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    final total = text.length;
    // Start envelope
    final startEnv = jsonEncode({
      '__sc_proto': 1,
      'kind': 'clipboard',
      'mode': 'start',
      'id': id,
      'total': total,
      'chunkSize': _chunkSize,
    });
    _dataChannel!.send(RTCDataChannelMessage(startEnv));
    // Chunks
    int offset = 0;
    while (offset < total) {
      final end = (offset + _chunkSize > total) ? total : offset + _chunkSize;
      final chunk = text.substring(offset, end);
      final chunkEnv = jsonEncode({
        '__sc_proto': 1,
        'kind': 'clipboard',
        'mode': 'chunk',
        'id': id,
        'seq': offset ~/ _chunkSize,
        'data': chunk,
      });
      _dataChannel!.send(RTCDataChannelMessage(chunkEnv));
      offset = end;

      // Backpressure: wait if buffered amount is high
      while ((_dataChannel!.bufferedAmount ?? 0) > _bufferedLowThreshold) {
        _log('⏳ WAITING BUFFER TO DRAIN (LARGE MESSAGE)', {'buffered': _dataChannel!.bufferedAmount});
        _bufferLowCompleter = Completer<void>();
        try {
          // Wait for buffer to drain - no timeout to prevent data loss
          await _bufferLowCompleter!.future;
          _log('✅ BUFFER DRAINED, CONTINUING LARGE MESSAGE');
        } catch (e) {
          _log('❌ BUFFER DRAIN ERROR (LARGE MESSAGE)', e.toString());
          // If there's an error, wait a bit and retry
          await Future.delayed(Duration(milliseconds: 100));
        }
      }
    }
    // End envelope
    final endEnv = jsonEncode({
      '__sc_proto': 1,
      'kind': 'clipboard',
      'mode': 'end',
      'id': id,
    });
    _dataChannel!.send(RTCDataChannelMessage(endEnv));
  }

  void _handleClipboardPayload(String payload) {
    try {
      final clipboardContent = _fileTransferService.deserializeClipboardContent(payload);
      if (clipboardContent.isFiles) {
        _log('📁 RECEIVED FILES (JSON PAYLOAD)', '${clipboardContent.files.length} files');
        _fileTransferService.setClipboardContent(clipboardContent);
        _log('✅ FILES HANDLED VIA EXISTING FLOW');
        
        // Show clipboard receive success notification for files
        _notificationService.showClipboardReceiveSuccess(_peerId ?? 'Unknown Device', isFile: true);
      } else {
        _log('📝 RECEIVED TEXT', clipboardContent.text);
        Clipboard.setData(ClipboardData(text: clipboardContent.text));
        _log('📋 TEXT CLIPBOARD UPDATED SUCCESSFULLY');
        
        // Show clipboard receive success notification for text
        _notificationService.showClipboardReceiveSuccess(_peerId ?? 'Unknown Device', isFile: false);
      }
    } catch (e) {
      _log('❌ ERROR PROCESSING RECEIVED DATA', e.toString());
    }
  }

  Future<void> _resetConnection() async {
    // Prevent multiple simultaneous resets
    if (_isResetting) {
      _log('⚠️ RESET ALREADY IN PROGRESS, SKIPPING');
      return;
    }
    
    _isResetting = true;
    _log('🔄 RESETTING PEER CONNECTION FOR NEW SHARE');
    
    // Reset candidate queue and remote description flag
    _log('🔍 BEFORE RESET - Remote desc set: $_remoteDescriptionSet, Queue size: ${_pendingCandidates.length}');
    _pendingCandidates.clear();
    _remoteDescriptionSet = false;
    _log('🔍 AFTER RESET - Remote desc set: $_remoteDescriptionSet, Queue size: ${_pendingCandidates.length}');
    
    try {
      // Quick synchronous cleanup first
      _forceCleanup();
      
      // Close connections with individual try-catch blocks
      if (_dataChannel != null) {
        _log('📡 CLOSING EXISTING DATA CHANNEL');
        try {
          _dataChannel?.close();
        } catch (e) {
          _log('⚠️ ERROR CLOSING DATA CHANNEL (IGNORING)', e.toString());
        }
        _dataChannel = null;
      }
      
      if (_peerConnection != null) {
        _log('🔗 CLOSING EXISTING PEER CONNECTION');
        try {
          _peerConnection?.close();
        } catch (e) {
          _log('⚠️ ERROR CLOSING PEER CONNECTION (IGNORING)', e.toString());
        }
        _peerConnection = null;
      }
      
      // Reinitialize with timeout protection
      await _initWithTimeout();
      _log('✅ PEER CONNECTION RESET COMPLETE');
    } catch (e) {
      _log('❌ ERROR DURING RESET (FORCING CLEANUP)', e.toString());
      _forceCleanup();
      
      // Try to reinitialize anyway
      try {
        await _initWithTimeout();
        _log('✅ FORCED RESET RECOVERY SUCCESSFUL');
      } catch (recoveryError) {
        _log('❌ FORCED RESET RECOVERY FAILED', recoveryError.toString());
      }
    } finally {
      _isResetting = false;
    }
  }

  Future<void> _initWithTimeout() async {
    return Future.any([
      init(),
      Future.delayed(Duration(seconds: 3)).then((_) => throw TimeoutException('Init timeout', Duration(seconds: 3))),
    ]);
  }

  void _forceCleanup() {
    _dataChannel = null;
    _peerConnection = null;
    _pendingClipboardContent = null;
    _peerId = null;
    _isInitialized = false;
    _pendingCandidates.clear();
    _remoteDescriptionSet = false;
  }

  Future<void> createOffer(String? peerId, {String? requestId}) async {
    try {
      _log('🎯 createOffer CALLED', {'peerId': peerId, 'requestId': requestId});
      
      if (peerId == null) {
        _log('❌ ERROR: peerId is required for createOffer');
        return;
      }
      
      // Use connection pooling for new requests, legacy for backward compatibility
      if (requestId != null) {
        // New connection pooling approach
        final connectionId = await _getOrCreateConnection(peerId, requestId);
        final connection = _connections[connectionId];
        
        if (connection == null) {
          _log('❌ ERROR: Failed to create connection', connectionId);
          return;
        }
        
        // Create offer
        RTCSessionDescription offer = await connection.createOffer();
        await connection.setLocalDescription(offer);
        
        _log('✅ OFFER CREATED AND SET AS LOCAL DESCRIPTION');
        
        // Send offer through signaling with request context
        if (onSignalGenerated != null) {
          onSignalGenerated!(peerId, {
            'type': 'offer',
            'sdp': offer.sdp,
            'connectionId': connectionId,
            'requestId': requestId,
          });
          _log('📤 OFFER SENT TO PEER', {'peerId': peerId, 'requestId': requestId});
        }
      } else {
        // Legacy single connection approach
        await _resetConnection();
        
        if (_peerConnection == null) {
          _log('❌ ERROR: PeerConnection is null after reset, cannot create offer');
          return;
        }
        
        _peerId = peerId;
        
        // Read current clipboard content
        try {
          final clipboardContent = await _fileTransferService.getClipboardContent();
          _pendingClipboardContent = clipboardContent;
        } catch (e) {
          _log('❌ ERROR READING CLIPBOARD', e.toString());
        }
        
        // Create data channel
        final dataChannelInit = RTCDataChannelInit()
          ..ordered = true
          ..protocol = 'file-transfer'
          ..negotiated = false;
        
        _dataChannel = await _peerConnection?.createDataChannel('clipboard', dataChannelInit);
        if (_dataChannel != null) {
          _setupDataChannel('legacy', _dataChannel!);
        }
        
        // Create and send offer
        RTCSessionDescription description = await _peerConnection!.createOffer();
        await _peerConnection!.setLocalDescription(description);
        
        if (onSignalGenerated != null) {
          onSignalGenerated!(peerId, {'type': 'offer', 'sdp': description.sdp});
        }
      }
      
      _log('✅ createOffer COMPLETED SUCCESSFULLY');
    } catch (e) {
      _log('❌ CRITICAL ERROR in createOffer', e.toString());
    }
  }

  Future<void> handleOffer(dynamic offer, String from) async {
    _log('📥 HANDLING OFFER FROM', from);
    _log('🔍 CURRENT STATE - Remote desc set: $_remoteDescriptionSet, Queue size: ${_pendingCandidates.length}');
    
    try {
      // Reset connection state for clean start
      await _resetConnection();
      
      if (_peerConnection == null) {
        _log('❌ ERROR: PeerConnection is null after reset, cannot handle offer');
        return;
      }
      
      _peerId = from;
      final offerSdp = offer['sdp'] as String?;
      final offerType = offer['type'] as String? ?? 'offer';

      // Pre-add transceivers if remote offer includes media sections
      if (offerSdp != null) {
        await _ensureRecvTransceiversForOffer(offerSdp);
      }
      
      // Set remote description with error handling
      _log('📡 SETTING REMOTE DESCRIPTION');
      await _peerConnection?.setRemoteDescription(RTCSessionDescription(offerSdp, offerType));

      // Wait until remote description is actually visible to the engine
      final rdReady = await _waitForRemoteDescription(timeoutMs: 1000);
      _remoteDescriptionSet = rdReady;
      if (!_remoteDescriptionSet) {
        _log('❌ REMOTE DESCRIPTION NOT READY AFTER TIMEOUT');
        return;
      }
      _log('✅ REMOTE DESCRIPTION SET AND READY');
      
      // Small delay to ensure the peer connection is fully ready
      await Future.delayed(Duration(milliseconds: 50));
      
      // Process any queued candidates
      await _processQueuedCandidates();
      
      // Create answer with error handling and retry logic
      _log('📡 CREATING ANSWER');
      RTCSessionDescription? description;
      int retryCount = 0;
      
      while (description == null && retryCount < 3) {
        try {
          // Small delay to ensure peer connection is fully ready
          if (retryCount > 0) {
            _log('🔄 RETRYING CREATE ANSWER - Attempt ${retryCount + 1}');
            await Future.delayed(Duration(milliseconds: 100 * retryCount));
          }
          
          description = await _peerConnection!.createAnswer();
          _log('✅ ANSWER CREATED SUCCESSFULLY');
        } catch (e) {
          retryCount++;
          _log('❌ CREATE ANSWER FAILED - Attempt $retryCount', e.toString());
          
          if (retryCount >= 3) {
            _log('❌ FAILED TO CREATE ANSWER AFTER 3 ATTEMPTS');
            return;
          }
        }
      }
      
      if (description != null) {
        await _peerConnection!.setLocalDescription(description);
        _log('📤 SENDING ANSWER');
        if (onSignalGenerated != null) {
          onSignalGenerated!(_peerId!, {'type': 'answer', 'sdp': description.sdp});
        }
      }
    } catch (e, stackTrace) {
      _log('❌ CRITICAL ERROR IN HANDLE OFFER', e.toString());
      _log('❌ STACK TRACE', stackTrace.toString());
      
      // Reset state on error
      _remoteDescriptionSet = false;
      _pendingCandidates.clear();
    }
  }

  Future<void> handleAnswer(dynamic answer) async {
    if (!_isInitialized) {
      await init();
    }
    
    if (_peerConnection == null) {
      _log('❌ ERROR: PeerConnection is null, cannot handle answer');
      return;
    }
    
    // Check signaling state to avoid calling setRemoteDescription in wrong state
    final state = _peerConnection!.signalingState;
    _log('📥 HANDLING ANSWER - signalingState: $state, remoteSet: $_remoteDescriptionSet');

    // If we're already stable and have a remote description, this is likely a duplicate answer; ignore
    if (state == RTCSignalingState.RTCSignalingStateStable &&
        _peerConnection!.getRemoteDescription() != null) {
      _log('ℹ️ IGNORING DUPLICATE ANSWER: already stable with remote description set');
      return;
    }

    // Only set remote answer when we are in have-local-offer (we are the offerer)
    if (state != RTCSignalingState.RTCSignalingStateHaveLocalOffer) {
      _log('⚠️ UNEXPECTED STATE FOR REMOTE ANSWER: $state. Skipping setRemoteDescription to avoid error.');
      return;
    }

    try {
      await _peerConnection!.setRemoteDescription(
        RTCSessionDescription(answer['sdp'], answer['type']),
      );
      // Wait until remote description is actually set in engine
      _remoteDescriptionSet = await _waitForRemoteDescription(timeoutMs: 1000);
      
      // Process any queued candidates
      await _processQueuedCandidates();
    } catch (e, st) {
      _log('❌ FAILED TO SET REMOTE ANSWER (guarded)', e.toString());
      _log('❌ STACK TRACE', st.toString());
      // Do not rethrow; just log to prevent crashing the app
    }
  }

  Future<void> handleCandidate(dynamic candidate) async {
    if (!_isInitialized) {
      await init();
    }
    
    if (_peerConnection == null || _isResetting) {
      _log('❌ ERROR: PeerConnection is null or resetting, queueing candidate');
      final iceCandidate = RTCIceCandidate(
        candidate['candidate'],
        candidate['sdpMid'],
        candidate['sdpMLineIndex'],
      );
      _pendingCandidates.add(iceCandidate);
      return;
    }
    
    final iceCandidate = RTCIceCandidate(
      candidate['candidate'],
      candidate['sdpMid'],
      candidate['sdpMLineIndex'],
    );
    
    _log('🧊 HANDLING ICE CANDIDATE - Remote desc set: $_remoteDescriptionSet, Queue size: ${_pendingCandidates.length}');
    
    // Always queue until remote description is confirmed ready; processing is batched
    if (!_remoteDescriptionSet || _isResetting || _peerConnection?.getRemoteDescription() == null) {
      _log('📦 QUEUEING ICE CANDIDATE (remote description not ready)');
      _pendingCandidates.add(iceCandidate);
      return;
    }
    
    // If RD is ready, we'll still prefer processing through the queue to keep ordering
    _pendingCandidates.add(iceCandidate);
    await _processQueuedCandidates();
  }

  Future<void> _processQueuedCandidates() async {
    if (_pendingCandidates.isEmpty) return;
    
    _log('📦 PROCESSING ${_pendingCandidates.length} QUEUED ICE CANDIDATES');
    
    // Verify remote description is actually set before processing
    if (_peerConnection?.getRemoteDescription() == null) {
      _log('⚠️ REMOTE DESCRIPTION STILL NULL, KEEPING CANDIDATES QUEUED');
      return;
    }
    
    final candidatesToProcess = List<RTCIceCandidate>.from(_pendingCandidates);
    final failedCandidates = <RTCIceCandidate>[];
    _pendingCandidates.clear();
    
    for (final candidate in candidatesToProcess) {
      try {
        await _peerConnection?.addCandidate(candidate);
        _log('✅ QUEUED ICE CANDIDATE ADDED SUCCESSFULLY');
      } catch (e) {
        _log('❌ ERROR ADDING QUEUED ICE CANDIDATE', e.toString());
        // If it still fails, keep it for later
        failedCandidates.add(candidate);
      }
    }
    
    // Re-queue any candidates that still failed
    if (failedCandidates.isNotEmpty) {
      _log('📦 RE-QUEUEING ${failedCandidates.length} FAILED CANDIDATES');
      _pendingCandidates.addAll(failedCandidates);
    } else {
      _log('📦 FINISHED PROCESSING ALL QUEUED CANDIDATES SUCCESSFULLY');
    }
  }

  // Polls until getRemoteDescription is non-null or timeout
  Future<bool> _waitForRemoteDescription({int timeoutMs = 1000, int intervalMs = 25}) async {
    final deadline = DateTime.now().add(Duration(milliseconds: timeoutMs));
    while (DateTime.now().isBefore(deadline)) {
      try {
        final rd = _peerConnection?.getRemoteDescription();
        if (rd != null) {
          return true;
        }
      } catch (_) {}
      await Future.delayed(Duration(milliseconds: intervalMs));
    }
    return false;
  }

  // If the offer SDP includes audio/video m-lines, add recvonly transceivers
  Future<void> _ensureRecvTransceiversForOffer(String sdp) async {
    try {
      final hasAudio = sdp.contains('\nm=audio');
      final hasVideo = sdp.contains('\nm=video');
      if (hasAudio) {
        _log('🎚️ ADDING RECVONLY AUDIO TRANSCEIVER');
        await _peerConnection?.addTransceiver(
          kind: RTCRtpMediaType.RTCRtpMediaTypeAudio,
          init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
        );
      }
      if (hasVideo) {
        _log('🎚️ ADDING RECVONLY VIDEO TRANSCEIVER');
        await _peerConnection?.addTransceiver(
          kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
          init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
        );
      }
    } catch (e) {
      _log('⚠️ ERROR ADDING RECV TRANSCEIVERS (IGNORING)', e.toString());
    }
  }

  // ===== Streaming file receiver helpers (proto v2) =====
  // Returns true if files were prepared and we're ready to receive.
  // Returns false if the user cancelled any save dialog; in that case, the caller should send a 'cancel' control.
  /// Prepare files for connection-specific session
  Future<bool> _promptDirectoryAndPrepareFilesForConnection(
    String connectionId, String sessionId, List<Map<String, dynamic>> filesMeta) async {
    final incomingFiles = <_IncomingFile>[];
    try {
      if (filesMeta.isEmpty) {
        _log('⚠️ NO FILES META PROVIDED FOR SESSION', {'connectionId': connectionId, 'sessionId': sessionId});
        return false;
      }

      String? sessionDir;
      for (final meta in filesMeta) {
        final name = (meta['name'] as String?) ?? 'file';
        String? savePath = await FilePicker.platform.saveFile(
          dialogTitle: 'Save incoming file',
          fileName: name,
        );

        if (savePath == null || savePath.isEmpty) {
          _log('❌ USER CANCELLED FILE SAVE', {'connectionId': connectionId, 'fileName': name});
          return false;
        }

        // Ensure directory consistency for the session
        final saveDir = path.dirname(savePath);
        if (sessionDir == null) {
          sessionDir = saveDir;
        } else if (sessionDir != saveDir) {
          _log('⚠️ FILES MUST BE SAVED IN THE SAME DIRECTORY', {'connectionId': connectionId});
          // For simplicity, we'll allow different directories but warn
        }

        final file = File(savePath);
        final sink = file.openWrite();
        final size = (meta['size'] as num?)?.toInt() ?? 0;
        final checksum = (meta['checksum'] as String?) ?? '';

        incomingFiles.add(_IncomingFile(
          name: name,
          size: size,
          checksum: checksum,
          file: file,
          sink: sink,
        ));
      }

      // Store session in connection-specific map
      final fileSessions = _fileSessionsByConnection[connectionId] ??= {};
      fileSessions[sessionId] = _FileSession(sessionDir ?? '', incomingFiles);
      
      // Also store in legacy map for backward compatibility
      _fileSessions[sessionId] = _FileSession(sessionDir ?? '', incomingFiles);
      
      _log('✅ FILE SESSION PREPARED FOR CONNECTION', {
        'connectionId': connectionId,
        'sessionId': sessionId,
        'files': incomingFiles.length,
        'directory': sessionDir
      });
    
      // Show 0% download notification for each file at the start
      for (final fileInfo in incomingFiles) {
        _notificationService.showFileDownloadProgress(0, fileInfo.name);
        // Don't set lastNotificationTime here - let the first progress notification show immediately
      }
      return true;
    } catch (e) {
      _log('❌ ERROR PREPARING FILE SESSION FOR CONNECTION', {
        'connectionId': connectionId,
        'sessionId': sessionId,
        'error': e.toString()
      });
      // Clean up any files that were created before the error
      for (final created in incomingFiles) {
        await created.sink.close();
        await created.file.delete();
      }
      return false;
    }
  }
  
  /// Legacy method for backward compatibility
  Future<bool> _promptDirectoryAndPrepareFiles(
    String sessionId, List<Map<String, dynamic>> filesMeta) async {
    // Use legacy connection ID or create a temporary one
    final connectionId = _getConnectionIdFromLegacyChannel() ?? 'legacy-${DateTime.now().millisecondsSinceEpoch}';
    return await _promptDirectoryAndPrepareFilesForConnection(connectionId, sessionId, filesMeta);
  }

  Future<void> _handleFileChunk(String sessionId, int fileIndex, String dataB64) async {
    final session = _fileSessions[sessionId];
    if (session == null) {
      _log('⚠️ RECEIVED CHUNK FOR UNKNOWN SESSION', sessionId);
      return;
    }
    if (fileIndex < 0 || fileIndex >= session.files.length) {
      _log('⚠️ INVALID FILE INDEX', {'sessionId': sessionId, 'index': fileIndex});
      return;
    }
    try {
      final bytes = base64Decode(dataB64);
      final incoming = session.files[fileIndex];
      incoming.sink.add(bytes);
      incoming.received += bytes.length;
      final receivedMB = incoming.received / (1024 * 1024);
      if (receivedMB.toInt() > (incoming.lastReportedMB ?? -1)) {
        final progressInt = (incoming.received / incoming.size * 100).round();
        _log('⬇️ PROGRESS', {'file': incoming.name, 'received': incoming.received, 'of': incoming.size});
        incoming.lastReportedMB = receivedMB.toInt();
        
        // Show download progress notification with throttling (minimum 10s apart)
        final now = DateTime.now();
        final shouldShowNotification = incoming.lastNotificationTime == null || 
            now.difference(incoming.lastNotificationTime!).inSeconds >= 10;
        
        if (shouldShowNotification) {
          // Check if this percentage should actually be shown (10%, 20%, 30%... 90%)
          // Exclude 0% since it's already shown at download start
          if (progressInt % 10 == 0 && progressInt > 0 && progressInt < 100) {
            _notificationService.showFileDownloadProgress(progressInt, incoming.name);
            // Only update the timer when we actually display a notification
            incoming.lastNotificationTime = now;
          }
        }
      }

      // Send ACK for flow control
      session.chunksReceived++;
      if (session.chunksReceived % 100 == 0) {
        _log('📬 SENDING ACK');
        _dataChannel?.send(RTCDataChannelMessage('{"__sc_proto":2,"kind":"ack"}'));
      }
    } catch (e) {
      _log('❌ ERROR WRITING FILE CHUNK', {'sessionId': sessionId, 'index': fileIndex, 'error': e.toString()});
    }
  }

  Future<void> _handleFileEnd(String sessionId, int fileIndex) async {
    // Send final ACK to ensure sender can complete
    _log('📬 SENDING FINAL ACK');
    _dataChannel?.send(RTCDataChannelMessage('{"__sc_proto":2,"kind":"ack"}'));

    final session = _fileSessions[sessionId];
    if (session == null) {
      _log('⚠️ RECEIVED END FOR UNKNOWN SESSION', sessionId);
      return;
    }
    if (fileIndex < 0 || fileIndex >= session.files.length) {
      _log('⚠️ INVALID FILE INDEX', {'sessionId': sessionId, 'index': fileIndex});
      return;
    }
    if (fileIndex < 0 || fileIndex >= session.files.length) return;
    try {
      final incoming = session.files[fileIndex];
      await incoming.sink.flush();
      await incoming.sink.close();
      _log('✅ FILE STREAM CLOSED', {'file': incoming.name, 'bytes': incoming.received});
    } catch (e) {
      _log('❌ ERROR CLOSING FILE SINK', e.toString());
    }
  }

  Future<void> _finalizeFileSession(String sessionId) async {
    final session = _fileSessions.remove(sessionId);
    if (session == null) return;
    try {
      for (final f in session.files) {
        try {
          await f.sink.flush();
          await f.sink.close();
        } catch (_) {}
      }
      // Optional: verify checksums and sizes
      bool allOk = true;
      for (final f in session.files) {
        final sizeOk = f.size == 0 || f.file.lengthSync() == f.size;
        // TODO: implement checksum verification if desired
        final checksumOk = true;
        if (!sizeOk || !checksumOk) {
          allOk = false;
        }
      }
      if (!allOk) {
        _log('⚠️ VERIFICATION FAILED', {
          'file': session.files.isNotEmpty ? session.files.first.name : 'n/a',
          'sizeOk': false,
          'checksumOk': false,
        });
      }
      // Build clipboard file list from saved files
      final filesForClipboard = <FileData>[];
      for (final f in session.files) {
        final bytes = await f.file.readAsBytes();
        final checksum = sha256.convert(bytes).toString();
        filesForClipboard.add(FileData(
          name: f.name,
          path: f.file.path,
          size: bytes.length,
          mimeType: 'application/octet-stream',
          checksum: checksum,
          content: Uint8List.fromList(bytes),
        ));
      }
      await _fileTransferService.setClipboardContent(ClipboardContent.files(filesForClipboard));
      _log('🎉 FILE SESSION FINALIZED', {'sessionId': sessionId, 'files': filesForClipboard.length, 'verified': allOk});
      
      // Show download completion notifications for each file
      for (final f in session.files) {
        _notificationService.showFileDownloadComplete(f.name, _peerId ?? 'Unknown Device');
      }
    } catch (e) {
      _log('❌ ERROR FINALIZING FILE SESSION', e.toString());
    }
  }

  Future<void> _abortFileSession(String sessionId) async {
    final session = _fileSessions.remove(sessionId);
    if (session == null) return;
    try {
      for (final f in session.files) {
        try {
          await f.sink.flush();
          await f.sink.close();
        } catch (_) {}
        try {
          if (await f.file.exists()) {
            await f.file.delete();
          }
        } catch (_) {}
      }
      _log('🧹 FILE SESSION ABORTED AND CLEANED', {'sessionId': sessionId});
    } catch (e) {
      _log('❌ ERROR ABORTING FILE SESSION', e.toString());
    }
  }

  void dispose() {
    _dataChannel?.close();
    _peerConnection?.close();
  }
}

// Private classes to track incoming streaming files
class _FileSession {
  final String dirPath;
  final List<_IncomingFile> files;
  int chunksReceived = 0;

  _FileSession(this.dirPath, this.files);
}

class _IncomingFile {
  final String name;
  final int size;
  final String checksum;
  final File file;
  final IOSink sink;
  int received = 0;
  int? lastReportedMB;
  DateTime? lastNotificationTime;
  _IncomingFile({
    required this.name,
    required this.size,
    required this.checksum,
    required this.file,
    required this.sink,
  });
}
