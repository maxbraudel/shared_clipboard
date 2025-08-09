import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:shared_clipboard/services/file_transfer_service.dart';
import 'package:shared_clipboard/services/notification_service.dart';
import 'package:path/path.dart' as path;

/// Session status enumeration
enum SessionStatus { active, completed, cancelled, error }

/// Clipboard session data structure
class ClipboardSession {
  final String sessionId;
  final String peerId;
  final String connectionId;
  final DateTime createdAt;
  SessionStatus status;
  
  ClipboardSession({
    required this.sessionId,
    required this.peerId,
    required this.connectionId,
    required this.createdAt,
    this.status = SessionStatus.active,
  });
}

/// Enhanced WebRTC Service with concurrent clipboard support
class WebRTCService {
  // Connection pooling support
  final Map<String, RTCPeerConnection> _connections = {};
  final Map<String, RTCDataChannel> _dataChannels = {};
  final Map<String, String> _peerIds = {}; // connectionId -> peerId mapping
  final Map<String, ClipboardSession> _clipboardSessions = {};
  int _sessionCounter = 0;
  
  // Legacy single connection support (for backward compatibility)
  RTCPeerConnection? _peerConnection;
  RTCDataChannel? _dataChannel;
  String? _peerId;
  bool _isInitialized = false;
  ClipboardContent? _pendingClipboardContent;
  bool _isResetting = false;
  
  // Services
  final FileTransferService _fileTransferService = FileTransferService();
  final NotificationService _notificationService = NotificationService();
  
  // ICE candidate management
  final Map<String, List<RTCIceCandidate>> _pendingCandidatesByConnection = {};
  final List<RTCIceCandidate> _pendingCandidates = [];
  bool _remoteDescriptionSet = false;
  
  // File session management
  final Map<String, _FileSession> _fileSessions = {};
  final Map<String, Completer<void>> _sessionReadyCompleters = {};
  Completer<void>? _ackCompleter;
  
  // Chunking protocol settings
  static const int _chunkSize = 8 * 1024;
  
  // Callback to send signals
  Function(String to, dynamic signal)? onSignalGenerated;
  
  /// Helper function for timestamped logging
  void _log(String message, [dynamic data]) {
    final timestamp = DateTime.now().toIso8601String();
    if (data != null) {
      print('[$timestamp] WebRTC: $message - $data');
    } else {
      print('[$timestamp] WebRTC: $message');
    }
  }
  
  /// Initialize the WebRTC service
  Future<void> init() async {
    if (_isInitialized) return;
    
    _log('🚀 INITIALIZING WEBRTC SERVICE');
    
    try {
      final configuration = {
        'iceServers': [
          {'urls': 'stun:stun.l.google.com:19302'},
        ],
      };
      
      _peerConnection = await createPeerConnection(configuration);
      _setupLegacyConnectionHandlers();
      
      _isInitialized = true;
      _log('✅ WEBRTC SERVICE INITIALIZED');
    } catch (e) {
      _log('❌ ERROR INITIALIZING WEBRTC SERVICE', e.toString());
      rethrow;
    }
  }
  
  /// Setup handlers for legacy connection
  void _setupLegacyConnectionHandlers() {
    if (_peerConnection == null) return;
    
    _peerConnection!.onIceCandidate = (candidate) {
      if (onSignalGenerated != null && candidate.candidate != null && _peerId != null) {
        onSignalGenerated!(_peerId!, {
          'type': 'ice-candidate',
          'candidate': candidate.candidate,
          'sdpMLineIndex': candidate.sdpMLineIndex,
          'sdpMid': candidate.sdpMid,
        });
      }
    };
    
    _peerConnection!.onDataChannel = (channel) {
      _log('📡 DATA CHANNEL RECEIVED', channel.label);
      _dataChannel = channel;
      _setupLegacyDataChannel();
    };
  }
  
  /// Setup legacy data channel
  void _setupLegacyDataChannel() {
    if (_dataChannel == null) return;
    
    _dataChannel!.onDataChannelState = (state) {
      if (state == RTCDataChannelState.RTCDataChannelOpen) {
        _log('✅ DATA CHANNEL OPENED');
        _sendClipboardContent();
      }
    };
    
    _dataChannel!.onMessage = (message) {
      _handleLegacyDataChannelMessage(message);
    };
  }
  
  /// Handle legacy data channel messages
  void _handleLegacyDataChannelMessage(RTCDataChannelMessage message) {
    try {
      final data = jsonDecode(message.text);
      
      if (data['__sc_proto'] == 2) {
        // Protocol v2 message handling
        _handleProtocolV2Message(data);
      } else {
        // Legacy text message
        _handleTextMessage(message.text);
      }
    } catch (e) {
      _log('❌ ERROR HANDLING MESSAGE', e.toString());
    }
  }
  
  /// Handle protocol v2 messages
  void _handleProtocolV2Message(Map<String, dynamic> data) {
    final kind = data['kind'];
    
    switch (kind) {
      case 'text':
        _handleTextContent(data['content']);
        break;
      case 'files_meta':
        _handleFilesMeta(data);
        break;
      case 'file_chunk':
        _handleFileChunk(data['sessionId'], data['fileIndex'], data['data']);
        break;
      case 'file_end':
        _handleFileEnd(data['sessionId'], data['fileIndex']);
        break;
      case 'session_end':
        _finalizeFileSession(data['sessionId']);
        break;
      case 'ack':
        _handleAck();
        break;
      default:
        _log('⚠️ UNKNOWN MESSAGE KIND', kind);
    }
  }
  
  /// Handle text content
  void _handleTextContent(String text) {
    _log('📝 RECEIVED TEXT CONTENT', text.length);
    // Set clipboard content
    // Implementation depends on your clipboard service
  }
  
  /// Handle text message (legacy)
  void _handleTextMessage(String text) {
    _log('📝 RECEIVED LEGACY TEXT', text.length);
    // Handle legacy text messages
  }
  
  /// Handle files metadata
  void _handleFilesMeta(Map<String, dynamic> data) {
    final sessionId = data['sessionId'];
    final filesMeta = List<Map<String, dynamic>>.from(data['files']);
    
    _log('📁 RECEIVED FILES META', {'sessionId': sessionId, 'files': filesMeta.length});
    
    // Prepare files for download
    _promptDirectoryAndPrepareFiles(sessionId, filesMeta);
  }
  
  /// Handle file chunk
  void _handleFileChunk(String sessionId, int fileIndex, String dataB64) {
    final session = _fileSessions[sessionId];
    if (session == null) {
      _log('⚠️ RECEIVED CHUNK FOR UNKNOWN SESSION', sessionId);
      return;
    }
    
    if (fileIndex >= session.incomingFiles.length) {
      _log('⚠️ INVALID FILE INDEX', {'sessionId': sessionId, 'index': fileIndex});
      return;
    }
    
    final incoming = session.incomingFiles[fileIndex];
    final chunkBytes = base64Decode(dataB64);
    
    try {
      incoming.sink.add(chunkBytes);
      incoming.received += chunkBytes.length;
      
      // Send ACK every 100 chunks
      if (incoming.received % (100 * _chunkSize) == 0) {
        _sendAck();
      }
    } catch (e) {
      _log('❌ ERROR WRITING FILE CHUNK', e.toString());
    }
  }
  
  /// Handle file end
  void _handleFileEnd(String sessionId, int fileIndex) {
    final session = _fileSessions[sessionId];
    if (session == null) return;
    
    if (fileIndex < session.incomingFiles.length) {
      final incoming = session.incomingFiles[fileIndex];
      incoming.sink.close();
      _log('✅ FILE COMPLETED', {'file': incoming.name, 'bytes': incoming.received});
    }
  }
  
  /// Finalize file session
  void _finalizeFileSession(String sessionId) {
    final session = _fileSessions.remove(sessionId);
    if (session == null) return;
    
    _log('🎉 FILE SESSION COMPLETED', sessionId);
    
    // Notify completion
    for (final file in session.incomingFiles) {
      _notificationService.showFileDownloadComplete(file.name, _peerId ?? 'Unknown Device');
    }
  }
  
  /// Handle ACK
  void _handleAck() {
    if (_ackCompleter != null && !_ackCompleter!.isCompleted) {
      _ackCompleter!.complete();
    }
  }
  
  /// Send ACK
  void _sendAck() {
    if (_dataChannel?.state == RTCDataChannelState.RTCDataChannelOpen) {
      _dataChannel!.send(RTCDataChannelMessage('{"__sc_proto":2,"kind":"ack"}'));
    }
  }
  
  /// Create offer for peer
  Future<void> createOffer(String peerId, {String? requestId}) async {
    try {
      _log('🎯 CREATING OFFER', {'peerId': peerId, 'requestId': requestId});
      
      if (!_isInitialized) {
        await init();
      }
      
      if (requestId != null) {
        // Use connection pooling for new concurrent requests
        await _createOfferWithConnectionPooling(peerId, requestId);
      } else {
        // Use legacy single connection
        await _createLegacyOffer(peerId);
      }
    } catch (e) {
      _log('❌ ERROR CREATING OFFER', e.toString());
      rethrow;
    }
  }
  
  /// Create offer with connection pooling
  Future<void> _createOfferWithConnectionPooling(String peerId, String requestId) async {
    final connectionId = _generateConnectionId(peerId, requestId);
    
    // Create new connection
    final configuration = {
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
      ],
    };
    
    final connection = await createPeerConnection(configuration);
    _connections[connectionId] = connection;
    _peerIds[connectionId] = peerId;
    
    // Setup connection handlers
    _setupConnectionHandlers(connectionId, connection);
    
    // Create data channel
    final dataChannel = await connection.createDataChannel('clipboard', RTCDataChannelInit());
    _dataChannels[connectionId] = dataChannel;
    _setupDataChannel(connectionId, dataChannel);
    
    // Create offer
    final offer = await connection.createOffer();
    await connection.setLocalDescription(offer);
    
    // Send offer
    if (onSignalGenerated != null) {
      onSignalGenerated!(peerId, {
        'type': 'offer',
        'sdp': offer.sdp,
        'connectionId': connectionId,
        'requestId': requestId,
      });
    }
    
    _log('✅ OFFER CREATED WITH CONNECTION POOLING', connectionId);
  }
  
  /// Create legacy offer
  Future<void> _createLegacyOffer(String peerId) async {
    if (_peerConnection == null) return;
    
    _peerId = peerId;
    
    // Read clipboard content
    try {
      _pendingClipboardContent = await _fileTransferService.getClipboardContent();
    } catch (e) {
      _log('❌ ERROR READING CLIPBOARD', e.toString());
    }
    
    // Create data channel
    _dataChannel = await _peerConnection!.createDataChannel('clipboard', RTCDataChannelInit());
    _setupLegacyDataChannel();
    
    // Create offer
    final offer = await _peerConnection!.createOffer();
    await _peerConnection!.setLocalDescription(offer);
    
    // Send offer
    if (onSignalGenerated != null) {
      onSignalGenerated!(peerId, {
        'type': 'offer',
        'sdp': offer.sdp,
      });
    }
    
    _log('✅ LEGACY OFFER CREATED');
  }
  
  /// Generate connection ID
  String _generateConnectionId(String peerId, String requestId) {
    return '${peerId}_${requestId}_${DateTime.now().millisecondsSinceEpoch}';
  }
  
  /// Setup connection handlers
  void _setupConnectionHandlers(String connectionId, RTCPeerConnection connection) {
    connection.onIceCandidate = (candidate) {
      if (onSignalGenerated != null && candidate.candidate != null) {
        final peerId = _peerIds[connectionId];
        if (peerId != null) {
          onSignalGenerated!(peerId, {
            'type': 'ice-candidate',
            'candidate': candidate.candidate,
            'sdpMLineIndex': candidate.sdpMLineIndex,
            'sdpMid': candidate.sdpMid,
            'connectionId': connectionId,
          });
        }
      }
    };
    
    connection.onDataChannel = (channel) {
      _log('📡 DATA CHANNEL RECEIVED', {'connectionId': connectionId, 'label': channel.label});
      _dataChannels[connectionId] = channel;
      _setupDataChannel(connectionId, channel, isReceiver: true);
    };
  }
  
  /// Setup data channel
  void _setupDataChannel(String connectionId, RTCDataChannel channel, {bool isReceiver = false}) {
    channel.onDataChannelState = (state) {
      if (state == RTCDataChannelState.RTCDataChannelOpen) {
        _log('✅ DATA CHANNEL OPENED', connectionId);
        if (!isReceiver) {
          _sendClipboardContentToConnection(connectionId);
        }
      }
    };
    
    channel.onMessage = (message) {
      _handleDataChannelMessage(connectionId, message);
    };
  }
  
  /// Handle data channel message for specific connection
  void _handleDataChannelMessage(String connectionId, RTCDataChannelMessage message) {
    // Similar to legacy handling but connection-specific
    _handleLegacyDataChannelMessage(message);
  }
  
  /// Send clipboard content to specific connection
  void _sendClipboardContentToConnection(String connectionId) {
    // Implementation for sending clipboard content to specific connection
    _log('📤 SENDING CLIPBOARD CONTENT TO CONNECTION', connectionId);
  }
  
  /// Send clipboard content (legacy)
  void _sendClipboardContent() {
    if (_pendingClipboardContent == null || _dataChannel?.state != RTCDataChannelState.RTCDataChannelOpen) {
      return;
    }
    
    final content = _pendingClipboardContent!;
    
    if (content.isFiles) {
      _sendFilesContent(content);
    } else {
      _sendTextContent(content.text);
    }
  }
  
  /// Send text content
  void _sendTextContent(String text) {
    if (_dataChannel?.state == RTCDataChannelState.RTCDataChannelOpen) {
      final message = jsonEncode({
        '__sc_proto': 2,
        'kind': 'text',
        'content': text,
      });
      _dataChannel!.send(RTCDataChannelMessage(message));
      _log('📤 TEXT CONTENT SENT', text.length);
    }
  }
  
  /// Send files content
  void _sendFilesContent(ClipboardContent content) {
    // Implementation for sending files
    _log('📁 SENDING FILES CONTENT', content.files.length);
  }
  
  /// Handle WebRTC signals
  Future<void> handleSignal(String peerId, dynamic signal, {String? requestId}) async {
    final signalType = signal['type'];
    final connectionId = signal['connectionId'];
    
    _log('🔄 HANDLING SIGNAL', {
      'from': peerId,
      'type': signalType,
      'connectionId': connectionId,
      'requestId': requestId
    });
    
    try {
      if (connectionId != null && _connections.containsKey(connectionId)) {
        // Handle signal for specific connection
        await _handleConnectionSignal(connectionId, signal);
      } else {
        // Handle legacy signal
        await _handleLegacySignal(peerId, signal);
      }
    } catch (e) {
      _log('❌ ERROR HANDLING SIGNAL', e.toString());
    }
  }
  
  /// Handle signal for specific connection
  Future<void> _handleConnectionSignal(String connectionId, dynamic signal) async {
    final connection = _connections[connectionId];
    if (connection == null) return;
    
    final signalType = signal['type'];
    
    if (signalType == 'offer') {
      await connection.setRemoteDescription(RTCSessionDescription(signal['sdp'], signal['type']));
      final answer = await connection.createAnswer();
      await connection.setLocalDescription(answer);
      
      final peerId = _peerIds[connectionId];
      if (onSignalGenerated != null && peerId != null) {
        onSignalGenerated!(peerId, {
          'type': 'answer',
          'sdp': answer.sdp,
          'connectionId': connectionId,
        });
      }
    } else if (signalType == 'answer') {
      await connection.setRemoteDescription(RTCSessionDescription(signal['sdp'], signal['type']));
    } else if (signalType == 'ice-candidate') {
      final candidate = RTCIceCandidate(
        signal['candidate'],
        signal['sdpMid'],
        signal['sdpMLineIndex'],
      );
      await connection.addCandidate(candidate);
    }
  }
  
  /// Handle legacy signal
  Future<void> _handleLegacySignal(String peerId, dynamic signal) async {
    if (_peerConnection == null) {
      await init();
    }
    
    final signalType = signal['type'];
    
    if (signalType == 'offer') {
      await handleOffer(signal, peerId);
    } else if (signalType == 'answer') {
      await handleAnswer(signal);
    } else if (signalType == 'ice-candidate') {
      await handleCandidate(signal);
    }
  }
  
  /// Handle offer (legacy)
  Future<void> handleOffer(dynamic offer, String from) async {
    if (!_isInitialized) await init();
    if (_peerConnection == null) return;
    
    _peerId = from;
    
    await _peerConnection!.setRemoteDescription(RTCSessionDescription(offer['sdp'], offer['type']));
    
    final answer = await _peerConnection!.createAnswer();
    await _peerConnection!.setLocalDescription(answer);
    
    if (onSignalGenerated != null) {
      onSignalGenerated!(from, {'type': 'answer', 'sdp': answer.sdp});
    }
    
    _remoteDescriptionSet = true;
    _processQueuedCandidates();
  }
  
  /// Handle answer (legacy)
  Future<void> handleAnswer(dynamic answer) async {
    if (_peerConnection == null) return;
    
    await _peerConnection!.setRemoteDescription(RTCSessionDescription(answer['sdp'], answer['type']));
    _remoteDescriptionSet = true;
    _processQueuedCandidates();
  }
  
  /// Handle ICE candidate (legacy)
  Future<void> handleCandidate(dynamic candidate) async {
    if (_peerConnection == null) return;
    
    final iceCandidate = RTCIceCandidate(
      candidate['candidate'],
      candidate['sdpMid'],
      candidate['sdpMLineIndex'],
    );
    
    if (_remoteDescriptionSet) {
      await _peerConnection!.addCandidate(iceCandidate);
    } else {
      _pendingCandidates.add(iceCandidate);
    }
  }
  
  /// Process queued ICE candidates
  Future<void> _processQueuedCandidates() async {
    for (final candidate in _pendingCandidates) {
      try {
        await _peerConnection?.addCandidate(candidate);
      } catch (e) {
        _log('❌ ERROR ADDING QUEUED CANDIDATE', e.toString());
      }
    }
    _pendingCandidates.clear();
  }
  
  /// Create clipboard session
  Future<String> createClipboardSession(String peerId, [String? requestId]) async {
    final sessionId = requestId ?? 'session_${DateTime.now().millisecondsSinceEpoch}_${_sessionCounter++}';
    final connectionId = _generateConnectionId(peerId, sessionId);
    
    _clipboardSessions[sessionId] = ClipboardSession(
      sessionId: sessionId,
      peerId: peerId,
      connectionId: connectionId,
      createdAt: DateTime.now(),
      status: SessionStatus.active,
    );
    
    _log('📋 CLIPBOARD SESSION CREATED', {
      'sessionId': sessionId,
      'peerId': peerId,
      'connectionId': connectionId
    });
    
    return sessionId;
  }
  
  /// Prompt directory and prepare files
  bool _promptDirectoryAndPrepareFiles(String sessionId, List<Map<String, dynamic>> filesMeta) {
    // Implementation for file preparation
    _log('📁 PREPARING FILES FOR SESSION', {'sessionId': sessionId, 'files': filesMeta.length});
    return true;
  }
  
  /// Dispose resources
  void dispose() {
    _log('🧹 DISPOSING WEBRTC SERVICE');
    
    // Close all connections
    for (final connection in _connections.values) {
      connection.close();
    }
    _connections.clear();
    
    // Close all data channels
    for (final channel in _dataChannels.values) {
      channel.close();
    }
    _dataChannels.clear();
    
    // Close legacy connection
    _dataChannel?.close();
    _peerConnection?.close();
    
    _clipboardSessions.clear();
    _fileSessions.clear();
  }
}

/// File session data structure
class _FileSession {
  final String sessionDir;
  final List<_IncomingFile> incomingFiles;
  
  _FileSession(this.sessionDir, this.incomingFiles);
}

/// Incoming file data structure
class _IncomingFile {
  final String name;
  final int size;
  final String hash;
  final IOSink sink;
  int received = 0;
  
  _IncomingFile({
    required this.name,
    required this.size,
    required this.hash,
    required this.sink,
  });
}
