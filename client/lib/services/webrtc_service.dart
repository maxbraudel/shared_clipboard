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
    
    _log('🔧 SETTING UP LEGACY CONNECTION HANDLERS');
    
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
    
    _peerConnection!.onConnectionState = (state) {
      _log('🔗 CONNECTION STATE CHANGED', state.toString());
    };
    
    _peerConnection!.onIceConnectionState = (state) {
      _log('🧊 ICE CONNECTION STATE CHANGED', state.toString());
    };
  }
  
  /// Setup legacy data channel
  void _setupLegacyDataChannel() {
    if (_dataChannel == null) return;
    
    _dataChannel!.onDataChannelState = (state) {
      _log('📡 DATA CHANNEL STATE CHANGED', state.toString());
      if (state == RTCDataChannelState.RTCDataChannelOpen) {
        _log('✅ DATA CHANNEL OPENED');
        // Only send content if we're the sender (have pending content)
        if (_pendingClipboardContent != null) {
          _log('📤 SENDING CLIPBOARD CONTENT FROM STATE CALLBACK');
          _sendClipboardContent();
        } else {
          _log('📡 RECEIVER DATA CHANNEL READY - WAITING FOR CONTENT');
        }
      }
    };
    
    _dataChannel!.onMessage = (message) {
      _handleLegacyDataChannelMessage(message);
    };
    
    // Immediate check in case the data channel is already open
    if (_dataChannel!.state == RTCDataChannelState.RTCDataChannelOpen && _pendingClipboardContent != null) {
      _log('📤 DATA CHANNEL ALREADY OPEN - SENDING CONTENT IMMEDIATELY');
      _sendClipboardContent();
    }
  }
  
  /// Handle legacy data channel messages
  Future<void> _handleLegacyDataChannelMessage(RTCDataChannelMessage message) async {
    try {
      final data = jsonDecode(message.text);
      
      if (data['__sc_proto'] == 2) {
        // Protocol v2 message handling
        await _handleProtocolV2Message(data);
      } else {
        // Legacy text message
        await _handleTextMessage(message.text);
      }
    } catch (e) {
      _log('❌ ERROR HANDLING MESSAGE', e.toString());
    }
  }
  
  /// Handle protocol v2 messages
  Future<void> _handleProtocolV2Message(Map<String, dynamic> data) async {
    final kind = data['kind'];
    
    switch (kind) {
      case 'text':
        await _handleTextContent(data['content']);
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
  Future<void> _handleTextContent(String text) async {
    _log('📝 RECEIVED TEXT CONTENT', text.length);
    
    try {
      // Set the received text to clipboard
      final clipboardContent = ClipboardContent.text(text);
      await _fileTransferService.setClipboardContent(clipboardContent);
      
      _log('✅ TEXT CONTENT SET TO CLIPBOARD', text);
      
      // Show notification
      _notificationService.showClipboardReceiveSuccess(
        'Text received from ${_peerId ?? "Unknown Device"}'
      );
    } catch (e) {
      _log('❌ ERROR SETTING TEXT TO CLIPBOARD', e.toString());
      
      // Show error notification
      _notificationService.showClipboardReceiveFailure(
        'Failed to set text to clipboard: $e'
      );
    }
  }
  
  /// Handle text message (legacy)
  Future<void> _handleTextMessage(String text) async {
    _log('📝 RECEIVED LEGACY TEXT', text.length);
    
    try {
      // Set the received text to clipboard
      final clipboardContent = ClipboardContent.text(text);
      await _fileTransferService.setClipboardContent(clipboardContent);
      
      _log('✅ LEGACY TEXT CONTENT SET TO CLIPBOARD', text);
      
      // Show notification
      _notificationService.showClipboardReceiveSuccess(
        'Text received from ${_peerId ?? "Unknown Device"}'
      );
    } catch (e) {
      _log('❌ ERROR SETTING LEGACY TEXT TO CLIPBOARD', e.toString());
      
      // Show error notification
      _notificationService.showClipboardReceiveFailure(
        'Failed to set text to clipboard: $e'
      );
    }
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
    final dataChannelInit = RTCDataChannelInit();
    _log('🔨 CREATING DATA CHANNEL WITH CONFIG', dataChannelInit.toString());
    _dataChannel = await _peerConnection!.createDataChannel('clipboard', dataChannelInit);
    _log('📡 DATA CHANNEL CREATED', {'state': _dataChannel!.state.toString(), 'label': _dataChannel!.label, 'id': _dataChannel!.id});
    _setupLegacyDataChannel();
    
    // Add a small delay and check again to handle race conditions
    Future.delayed(Duration(milliseconds: 100), () {
      if (_dataChannel?.state == RTCDataChannelState.RTCDataChannelOpen && _pendingClipboardContent != null) {
        _log('📤 DELAYED CHECK - SENDING CONTENT');
        _sendClipboardContent();
      }
    });
    
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
    channel.onDataChannelState = (state) async {
      if (state == RTCDataChannelState.RTCDataChannelOpen) {
        _log('✅ DATA CHANNEL OPENED', connectionId);
        if (!isReceiver) {
          await _sendClipboardContentToConnection(connectionId);
        } else {
          _log('📡 RECEIVER DATA CHANNEL READY', connectionId);
        }
      }
    };
    
    channel.onMessage = (message) {
      _handleDataChannelMessage(connectionId, message);
    };
  }
  
  /// Handle data channel message for specific connection
  Future<void> _handleDataChannelMessage(String connectionId, RTCDataChannelMessage message) async {
    // Similar to legacy handling but connection-specific
    await _handleLegacyDataChannelMessage(message);
  }
  
  /// Send clipboard content to specific connection
  Future<void> _sendClipboardContentToConnection(String connectionId) async {
    _log('📤 SENDING CLIPBOARD CONTENT TO CONNECTION', connectionId);
    
    try {
      // Read current clipboard content
      final clipboardContent = await _fileTransferService.getClipboardContent();
      
      if (clipboardContent.isFiles) {
        _log('📁 SENDING FILES TO CONNECTION', {'connectionId': connectionId, 'fileCount': clipboardContent.files.length});
        await _sendFilesContentToConnection(connectionId, clipboardContent);
      } else if (clipboardContent.text.isNotEmpty) {
        _log('📝 SENDING TEXT TO CONNECTION', {'connectionId': connectionId, 'textLength': clipboardContent.text.length});
        await _sendTextContentToConnection(connectionId, clipboardContent.text);
      } else {
        _log('❌ NO CLIPBOARD CONTENT TO SEND TO CONNECTION', connectionId);
      }
    } catch (e) {
      _log('❌ ERROR READING CLIPBOARD FOR CONNECTION', {'connectionId': connectionId, 'error': e.toString()});
    }
  }
  
  /// Send text content to specific connection
  Future<void> _sendTextContentToConnection(String connectionId, String text) async {
    final channel = _dataChannels[connectionId];
    if (channel?.state == RTCDataChannelState.RTCDataChannelOpen) {
      final message = jsonEncode({
        '__sc_proto': 2,
        'kind': 'text',
        'content': text,
      });
      channel!.send(RTCDataChannelMessage(message));
      _log('📤 TEXT CONTENT SENT TO CONNECTION', {'connectionId': connectionId, 'textLength': text.length});
    } else {
      _log('❌ DATA CHANNEL NOT AVAILABLE FOR CONNECTION', connectionId);
    }
  }
  
  /// Send files content to specific connection
  Future<void> _sendFilesContentToConnection(String connectionId, ClipboardContent content) async {
    _log('📁 SENDING FILES TO CONNECTION', {'connectionId': connectionId, 'fileCount': content.files.length});
    // Implementation for sending files to specific connection
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
      await _createLegacyAnswer(peerId, signal);
    } else if (signalType == 'answer') {
      await handleAnswer(signal);
    } else if (signalType == 'ice-candidate') {
      await handleCandidate(signal);
    }
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
