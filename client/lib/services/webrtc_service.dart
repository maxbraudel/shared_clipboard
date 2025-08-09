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


// Data class to hold peer connection state
class _PeerConnectionState {
  RTCPeerConnection? peerConnection;
  RTCDataChannel? dataChannel;
  ClipboardContent? pendingClipboardContent;
  bool isResetting = false;
  
  // ICE candidates queue for this peer
  final List<RTCIceCandidate> pendingCandidates = [];
  bool remoteDescriptionSet = false;
  
  // Chunking protocol state per peer
  final Map<String, StringBuffer> rxBuffers = {};
  final Map<String, int> rxReceivedBytes = {};
  final Map<String, int> rxTotalBytes = {};
  Completer<void>? bufferLowCompleter;
  
  // File sessions for this peer
  final Map<String, _FileSession> fileSessions = {};
  final Map<String, Completer<void>> sessionReadyCompleters = {};
  Completer<void>? ackCompleter;
  
  _PeerConnectionState();
  
  void cleanup() {
    dataChannel = null;
    peerConnection = null;
    pendingClipboardContent = null;
    isResetting = false;
    pendingCandidates.clear();
    remoteDescriptionSet = false;
    rxBuffers.clear();
    rxReceivedBytes.clear();
    rxTotalBytes.clear();
    bufferLowCompleter?.complete();
    bufferLowCompleter = null;
    fileSessions.clear();
    sessionReadyCompleters.clear();
    ackCompleter?.complete();
    ackCompleter = null;
  }
}

class WebRTCService {
  // Multi-peer connection management
  final Map<String, _PeerConnectionState> _peers = {};
  bool _isInitialized = false;
  final FileTransferService _fileTransferService = FileTransferService();
  final NotificationService _notificationService = NotificationService();

  // Chunking protocol settings - shared across all peers
  static const int _chunkSize = 8 * 1024; // 8 KB chunks for better SCTP compatibility
  static const int _bufferedLowThreshold = 32 * 1024; // 32 KB backpressure threshold
  
  // Callback to send signals back to socket service
  Function(String to, dynamic signal)? onSignalGenerated;
  
  // Transfer progress callbacks for UI updates
  Function(String peerId, String operation, String description)? onTransferStarted;
  Function(String peerId, double progress, String description)? onTransferProgress;
  Function(String peerId, String description)? onTransferCompleted;
  Function(String peerId, String error)? onTransferError;

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

  // Helper method to get or create peer state
  _PeerConnectionState _getPeerState(String peerId) {
    return _peers.putIfAbsent(peerId, () => _PeerConnectionState());
  }

  // Streaming files protocol (proto v2) - now peer-specific
  Future<void> _sendFilesStreaming(String peerId, ClipboardContent content) async {
    final peerState = _getPeerState(peerId);
    if (peerState.dataChannel == null) throw StateError('DataChannel not ready for peer $peerId');
    
    final sessionId = DateTime.now().microsecondsSinceEpoch.toString();
    final filesMeta = content.files
        .map((f) => {
              'name': f.name,
              'size': f.size,
              'checksum': f.checksum,
            })
        .toList();
    
    // Start session with metadata so receiver can prompt immediately
    final startEnv = jsonEncode({
      '__sc_proto': 2,
      'kind': 'files',
      'mode': 'start',
      'sessionId': sessionId,
      'files': filesMeta,
    });
    peerState.dataChannel!.send(RTCDataChannelMessage(startEnv));

    // Wait for receiver to prepare and acknowledge readiness
    final ready = Completer<void>();
    peerState.sessionReadyCompleters[sessionId] = ready;
    try {
      // Allow ample time for the receiver to choose save locations
      await ready.future.timeout(Duration(minutes: 3));
      _log('✅ RECEIVER READY, STARTING STREAM', '$peerId:$sessionId');
    } catch (e) {
      _log('⚠️ RECEIVER READY TIMEOUT, ABORTING STREAM', '$peerId:$sessionId');
      peerState.sessionReadyCompleters.remove(sessionId);
      return;
    }

    // Notify UI of transfer start
    onTransferStarted?.call(peerId, 'sending', 'Preparing to send ${content.files.length} file(s)');
    
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
      
      // Notify UI of file-specific transfer start
      onTransferProgress?.call(peerId, (i / content.files.length), 'Sending ${f.name}');
      
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
          peerState.dataChannel!.send(RTCDataChannelMessage(env));
          chunkCount++;
          
          // Log progress every 100 chunks and show notifications at round percentages
          if (chunkCount % 100 == 0) {
            final progress = (offset / bytes.length * 100).toStringAsFixed(1);
            final progressInt = (offset / bytes.length * 100).round();
            _log('📤 SENDING PROGRESS', {
              'peer': peerId,
              'file': f.name,
              'chunk': chunkCount,
              'of': totalChunks,
              'progress': '${progress}%',
              'bytesRemaining': bytes.length - offset,
              'bufferedAmount': peerState.dataChannel!.bufferedAmount
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
          _log('⏳ WAITING FOR ACK', '$peerId:$sessionId');
          peerState.ackCompleter = Completer<void>();
          try {
            await peerState.ackCompleter!.future.timeout(const Duration(seconds: 30));
            _log('✅ ACK RECEIVED, CONTINUING TRANSFER', '$peerId:$sessionId');
          } catch (e) {
            _log('❌ ACK TIMEOUT, ABORTING TRANSFER', '$peerId:$sessionId - ${e.toString()}');
            throw Exception('ACK timeout');
          } finally {
            peerState.ackCompleter = null;
          }
        }
      }
      
      // Final ACK check to ensure all chunks are processed
      if (chunkCount % 100 != 0) {
        _log('⏳ WAITING FOR FINAL ACK', '$peerId:$sessionId');
        peerState.ackCompleter = Completer<void>();
        try {
          await peerState.ackCompleter!.future.timeout(const Duration(seconds: 30));
          _log('✅ FINAL ACK RECEIVED', '$peerId:$sessionId');
        } catch (e) {
          _log('❌ FINAL ACK TIMEOUT, ABORTING TRANSFER', '$peerId:$sessionId - ${e.toString()}');
          throw Exception('Final ACK timeout');
        } finally {
          peerState.ackCompleter = null;
        }
      }

      _log('✅ FINISHED SENDING FILE', {
        'peer': peerId,
        'file': f.name,
        'totalChunks': chunkCount,
        'totalBytes': bytes.length,
        'finalBufferedAmount': peerState.dataChannel!.bufferedAmount
      });
      
      // End of this file
      final fileEnd = jsonEncode({
        '__sc_proto': 2,
        'kind': 'files',
        'mode': 'file_end',
        'sessionId': sessionId,
        'fileIndex': i,
      });
      peerState.dataChannel!.send(RTCDataChannelMessage(fileEnd));
    }

    // End session
    final endEnv = jsonEncode({
      '__sc_proto': 2,
      'kind': 'files',
      'mode': 'end',
      'sessionId': sessionId,
    });
    peerState.dataChannel!.send(RTCDataChannelMessage(endEnv));
    
    // Notify UI of transfer completion
    onTransferCompleted?.call(peerId, 'Successfully sent ${content.files.length} file(s)');
  }

  // Initialize the WebRTC service (global initialization)
  Future<void> init() async {
    if (_isInitialized) {
      _log('⚠️ WEBRTC SERVICE ALREADY INITIALIZED, SKIPPING');
      return;
    }
    
    _log('🚀 INITIALIZING WEBRTC SERVICE');
    _isInitialized = true;
    _log('✅ WEBRTC SERVICE INITIALIZED');
  }

  // Initialize a peer connection for a specific peer
  Future<void> _initPeerConnection(String peerId) async {
    final peerState = _getPeerState(peerId);
    
    if (peerState.peerConnection != null) {
      _log('⚠️ PEER CONNECTION ALREADY EXISTS', peerId);
      return;
    }
    
    _log('🚀 INITIALIZING PEER CONNECTION', peerId);
    
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
      peerState.peerConnection = await Future.any([
        createPeerConnection(configuration),
        Future.delayed(Duration(seconds: 2)).then((_) => throw TimeoutException('PeerConnection creation timeout', Duration(seconds: 2))),
      ]);

      peerState.peerConnection?.onIceCandidate = (candidate) {
        _log('🧊 ICE CANDIDATE GENERATED', peerId);
        if (onSignalGenerated != null) {
          onSignalGenerated!(peerId, {
            'type': 'candidate',
            'candidate': candidate.candidate,
            'sdpMid': candidate.sdpMid,
            'sdpMLineIndex': candidate.sdpMLineIndex,
          });
        }
      };

      peerState.peerConnection?.onConnectionState = (state) {
        _log('🔗 CONNECTION STATE CHANGED', '$peerId: ${state.toString()}');
      };

      peerState.peerConnection?.onDataChannel = (channel) {
        _log('📡 DATA CHANNEL RECEIVED', peerId);
        _setupDataChannel(peerId, channel);
      };
      
      _log('✅ PEER CONNECTION INITIALIZED', peerId);
    } catch (e) {
      _log('❌ ERROR INITIALIZING PEER CONNECTION', '$peerId: ${e.toString()}');
      peerState.cleanup();
      _peers.remove(peerId);
      rethrow;
    }
  }

  void _setupDataChannel(String peerId, RTCDataChannel channel) {
    final peerState = _getPeerState(peerId);
    peerState.dataChannel = channel;
    
    _log('📡 SETTING UP DATA CHANNEL', {
      'peer': peerId,
      'label': channel.label,
      'state': channel.state.toString(),
      'hasPendingContent': peerState.pendingClipboardContent != null,
      'role': peerState.pendingClipboardContent != null ? 'SENDER' : 'RECEIVER'
    });
    
    // Check if channel is already open
    if (channel.state == RTCDataChannelState.RTCDataChannelOpen) {
      _log('📡 DATA CHANNEL IS ALREADY OPEN DURING SETUP', peerId);
      _handleDataChannelOpen(peerId);
    }
    
    // Backpressure: fire completer when buffered amount goes low
    peerState.dataChannel?.onBufferedAmountLow = (int amount) {
      _log('📉 DATA CHANNEL BUFFERED AMOUNT LOW', {'peer': peerId, 'amount': amount});
      peerState.bufferLowCompleter?.complete();
      peerState.bufferLowCompleter = null;
    };
    peerState.dataChannel?.bufferedAmountLowThreshold = _bufferedLowThreshold;

    peerState.dataChannel?.onDataChannelState = (state) {
      _log('📡 DATA CHANNEL STATE CHANGED', '$peerId: ${state.toString()}');
      if (state == RTCDataChannelState.RTCDataChannelOpen) {
        _handleDataChannelOpen(peerId);
      }
    };

    peerState.dataChannel?.onMessage = (message) {
      // Support: proto v2 streaming (files), proto v1 chunked JSON payloads, and legacy single payload
      final text = message.text;
      _log('📥 RECEIVED DATA MESSAGE (RECEIVER ROLE)', '$peerId: ${text.length} bytes');
      try {
        // Handle ACKs for flow control
        if (text == '{"__sc_proto":2,"kind":"ack"}') {
          _log('📬 ACK RECEIVED', peerId);
          if (peerState.ackCompleter != null && !peerState.ackCompleter!.isCompleted) {
            peerState.ackCompleter!.complete();
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
              _log('🔰 START FILE STREAM SESSION', {'peer': peerId, 'sessionId': sessionId, 'files': filesMeta.length});
              () async {
                final prepared = await _promptDirectoryAndPrepareFiles(peerId, sessionId, filesMeta);
                if (!prepared) {
                  // Inform sender we cancelled so it can abort immediately
                  final cancelEnv = jsonEncode({
                    '__sc_proto': 2,
                    'kind': 'files',
                    'mode': 'cancel',
                    'sessionId': sessionId,
                  });
                  peerState.dataChannel?.send(RTCDataChannelMessage(cancelEnv));
                  _log('🚫 RECEIVER CANCELLED BEFORE READY', '$peerId:$sessionId');
                  return;
                }
                // Notify sender we are ready to receive chunks
                final readyEnv = jsonEncode({
                  '__sc_proto': 2,
                  'kind': 'files',
                  'mode': 'ready',
                  'sessionId': sessionId,
                });
                peerState.dataChannel?.send(RTCDataChannelMessage(readyEnv));
                _log('📨 SENT RECEIVER READY', '$peerId:$sessionId');
              }();
              return;
            }
            if (mode == 'ready' && sessionId != null) {
              // Sender side receives readiness ack
              final c = peerState.sessionReadyCompleters.remove(sessionId);
              c?.complete();
              _log('📩 RECEIVED READY ACK', '$peerId:$sessionId');
              return;
            }
            if (mode == 'cancel' && sessionId != null) {
              // Sender side receives cancellation; abort stream immediately
              final c = peerState.sessionReadyCompleters.remove(sessionId);
              c?.completeError(StateError('Receiver cancelled'));
              _abortFileSession(peerId, sessionId);
              _log('🛑 RECEIVED CANCEL, ABORTING SESSION', '$peerId:$sessionId');
              return;
            }
            if (mode == 'file_chunk' && sessionId != null) {
              final idx = env['fileIndex'] as int? ?? 0;
              final dataB64 = env['data'] as String? ?? '';
              _handleFileChunk(peerId, sessionId, idx, dataB64);
              return;
            }
            if (mode == 'file_end' && sessionId != null) {
              final idx = env['fileIndex'] as int? ?? 0;
              _handleFileEnd(peerId, sessionId, idx);
              return;
            }
            if (mode == 'end' && sessionId != null) {
              _finalizeFileSession(peerId, sessionId);
              return;
            }
          }
          // Proto v1: chunked JSON clipboard payload
          if (env['__sc_proto'] == 1 && env['kind'] == 'clipboard') {
            final mode = env['mode'] as String?;
            final id = env['id'] as String?;
            if (mode == 'start' && id != null) {
              final total = (env['total'] as num?)?.toInt() ?? 0;
              peerState.rxBuffers[id] = StringBuffer();
              peerState.rxReceivedBytes[id] = 0;
              peerState.rxTotalBytes[id] = total;
              _log('🔰 START CLIPBOARD TRANSFER', {'peer': peerId, 'id': id, 'total': total});
              return;
            }
            if (mode == 'chunk' && id != null) {
              final data = env['data'] as String? ?? '';
              final buf = peerState.rxBuffers[id];
              if (buf != null) {
                buf.write(data);
                final rec = (peerState.rxReceivedBytes[id] ?? 0) + data.length;
                peerState.rxReceivedBytes[id] = rec;
                final total = peerState.rxTotalBytes[id] ?? 0;
                if (total > 0) {
                  _log('📦 RECEIVED CHUNK', {'peer': peerId, 'id': id, 'received': rec, 'total': total});
                } else {
                  _log('📦 RECEIVED CHUNK', {'peer': peerId, 'id': id, 'received': rec});
                }
              }
              return;
            }
            if (mode == 'end' && id != null) {
              final buf = peerState.rxBuffers.remove(id);
              peerState.rxTotalBytes.remove(id);
              peerState.rxReceivedBytes.remove(id);
              if (buf != null) {
                final payload = buf.toString();
                _log('🏁 END CLIPBOARD TRANSFER', {'peer': peerId, 'id': id, 'size': payload.length});
                _handleClipboardPayload(peerId, payload);
              }
              return;
            }
          }
        }
        // Legacy single-message payload
        _handleClipboardPayload(peerId, text);
      } catch (e) {
        _log('❌ ERROR PROCESSING RECEIVED DATA', e.toString());
      }
    };
  }

  void _handleDataChannelOpen(String peerId) {
    final peerState = _getPeerState(peerId);
    _log('✅ DATA CHANNEL IS NOW OPEN', peerId);
    
    // Only send content if we have pending content (i.e., we're the sender)
    if (peerState.pendingClipboardContent != null) {
      final content = peerState.pendingClipboardContent!;
      if (content.isFiles) {
        _log('📤 SENDING FILES VIA STREAMING PROTOCOL', {'peer': peerId, 'count': content.files.length});
        _sendFilesStreaming(peerId, content).then((_) {
          _log('✅ FILES STREAMED SUCCESSFULLY', peerId);
          peerState.pendingClipboardContent = null;
        }).catchError((e) {
          _log('❌ ERROR STREAMING FILES', '$peerId: ${e.toString()}');
        });
      } else {
        final payload = _fileTransferService.serializeClipboardContent(content);
        _log('📤 SENDING TEXT/JSON VIA CHUNKING', {'peer': peerId, 'bytes': payload.length});
        _sendLargeMessage(peerId, payload).then((_) {
          _log('✅ CLIPBOARD CONTENT SENT SUCCESSFULLY', peerId);
          peerState.pendingClipboardContent = null;
        }).catchError((e) {
          _log('❌ ERROR SENDING CLIPBOARD CONTENT', '$peerId: ${e.toString()}');
        });
      }
    } else {
      _log('⚠️ NO PENDING CLIPBOARD CONTENT TO SEND', peerId);
    }
  }

  // Send message with chunking and backpressure-safe logic - now peer-specific
  Future<void> _sendLargeMessage(String peerId, String text) async {
    final peerState = _getPeerState(peerId);
    if (peerState.dataChannel == null) throw StateError('DataChannel not ready for peer $peerId');
    
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
    peerState.dataChannel!.send(RTCDataChannelMessage(startEnv));
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
      peerState.dataChannel!.send(RTCDataChannelMessage(chunkEnv));
      offset = end;

      // Backpressure: wait if buffered amount is high
      while ((peerState.dataChannel!.bufferedAmount ?? 0) > _bufferedLowThreshold) {
        _log('⏳ WAITING BUFFER TO DRAIN (LARGE MESSAGE)', {'peer': peerId, 'buffered': peerState.dataChannel!.bufferedAmount});
        peerState.bufferLowCompleter = Completer<void>();
        try {
          // Wait for buffer to drain - no timeout to prevent data loss
          await peerState.bufferLowCompleter!.future;
          _log('✅ BUFFER DRAINED, CONTINUING LARGE MESSAGE', peerId);
        } catch (e) {
          _log('❌ BUFFER DRAIN ERROR (LARGE MESSAGE)', '$peerId: ${e.toString()}');
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
    peerState.dataChannel!.send(RTCDataChannelMessage(endEnv));
  }

  void _handleClipboardPayload(String peerId, String payload) {
    try {
      final clipboardContent = _fileTransferService.deserializeClipboardContent(payload);
      if (clipboardContent.isFiles) {
        _log('📁 RECEIVED FILES (JSON PAYLOAD)', '${clipboardContent.files.length} files');
        _fileTransferService.setClipboardContent(clipboardContent);
        _log('✅ FILES HANDLED VIA EXISTING FLOW');
        
        // Show clipboard receive success notification for files
        _notificationService.showClipboardReceiveSuccess(peerId, isFile: true);
      } else {
        _log('📝 RECEIVED TEXT', clipboardContent.text);
        Clipboard.setData(ClipboardData(text: clipboardContent.text));
        _log('📋 TEXT CLIPBOARD UPDATED SUCCESSFULLY');
        
        // Show clipboard receive success notification for text
        _notificationService.showClipboardReceiveSuccess('Unknown Device', isFile: false);
      }
    } catch (e) {
      _log('❌ ERROR PROCESSING RECEIVED DATA', e.toString());
    }
  }

  // Reset a specific peer connection (peer-specific reset)
  Future<void> _resetPeerConnection(String peerId) async {
    final peerState = _getPeerState(peerId);
    
    // Prevent multiple simultaneous resets for this peer
    if (peerState.isResetting) {
      _log('⚠️ RESET ALREADY IN PROGRESS FOR PEER, SKIPPING', peerId);
      return;
    }
    
    peerState.isResetting = true;
    _log('🔄 RESETTING PEER CONNECTION FOR NEW SHARE', peerId);
    
    // Reset candidate queue and remote description flag for this peer
    _log('🔍 BEFORE RESET - Remote desc set: ${peerState.remoteDescriptionSet}, Queue size: ${peerState.pendingCandidates.length}', peerId);
    peerState.pendingCandidates.clear();
    peerState.remoteDescriptionSet = false;
    _log('🔍 AFTER RESET - Remote desc set: ${peerState.remoteDescriptionSet}, Queue size: ${peerState.pendingCandidates.length}', peerId);
    
    try {
      // Close connections with individual try-catch blocks
      if (peerState.dataChannel != null) {
        _log('📡 CLOSING EXISTING DATA CHANNEL', peerId);
        try {
          peerState.dataChannel?.close();
        } catch (e) {
          _log('⚠️ ERROR CLOSING DATA CHANNEL (IGNORING)', '$peerId: ${e.toString()}');
        }
        peerState.dataChannel = null;
      }
      
      if (peerState.peerConnection != null) {
        _log('🔗 CLOSING EXISTING PEER CONNECTION', peerId);
        try {
          peerState.peerConnection?.close();
        } catch (e) {
          _log('⚠️ ERROR CLOSING PEER CONNECTION (IGNORING)', '$peerId: ${e.toString()}');
        }
        peerState.peerConnection = null;
      }
      
      // Reinitialize with timeout protection
      await _initPeerConnection(peerId);
      _log('✅ PEER CONNECTION RESET COMPLETE', peerId);
    } catch (e) {
      _log('❌ ERROR DURING RESET (FORCING CLEANUP)', '$peerId: ${e.toString()}');
      peerState.cleanup();
      
      // Try to reinitialize anyway
      try {
        await _initPeerConnection(peerId);
        _log('✅ FORCED RESET RECOVERY SUCCESSFUL', peerId);
      } catch (recoveryError) {
        _log('❌ FORCED RESET RECOVERY FAILED', '$peerId: ${recoveryError.toString()}');
      }
    } finally {
      peerState.isResetting = false;
    }
  }

  // Clean up all peer connections
  void _cleanupAllPeers() {
    for (final entry in _peers.entries) {
      final peerId = entry.key;
      final peerState = entry.value;
      _log('🧽 CLEANING UP PEER', peerId);
      peerState.cleanup();
    }
    _peers.clear();
  }

  // Remove a specific peer
  void _removePeer(String peerId) {
    final peerState = _peers[peerId];
    if (peerState != null) {
      _log('🗑️ REMOVING PEER', peerId);
      peerState.cleanup();
      _peers.remove(peerId);
    }
  }

  Future<void> createOffer(String? peerId) async {
    if (peerId == null) {
      _log('❌ ERROR: peerId is required for createOffer');
      return;
    }
    
    try {
      _log('🎯 createOffer CALLED', peerId);
      
      // Initialize peer connection for this specific peer
      await _initPeerConnection(peerId);
      final peerState = _getPeerState(peerId);
      
      if (peerState.peerConnection == null) {
        _log('❌ ERROR: PeerConnection is null after init, cannot create offer', peerId);
        return;
      }
      _log('🎯 CREATING OFFER FOR PEER', peerId);
      
      // Read current clipboard content (text or files)
      try {
        _log('📋 READING CLIPBOARD FOR OFFER', peerId);
        final clipboardContent = await _fileTransferService.getClipboardContent();
        
        if (clipboardContent.isFiles) {
          _log('📁 FOUND FILES IN CLIPBOARD', '$peerId: ${clipboardContent.files.length} files');
          peerState.pendingClipboardContent = clipboardContent; // we'll stream them
          _log('📦 FILES READY FOR STREAMING', {'peer': peerId, 'count': clipboardContent.files.length});
        } else if (clipboardContent.text.isNotEmpty) {
          _log('📝 FOUND TEXT IN CLIPBOARD', '$peerId: ${clipboardContent.text}');
          peerState.pendingClipboardContent = clipboardContent; // will serialize at send
        } else {
          _log('❌ NO CLIPBOARD CONTENT TO SHARE', peerId);
        }
      } catch (e) {
        _log('❌ ERROR READING CLIPBOARD', '$peerId: ${e.toString()}');
      }
      
      // Create data channel with proper configuration for large file transfers
      _log('📡 CREATING DATA CHANNEL', peerId);
      final dataChannelInit = RTCDataChannelInit()
        ..ordered = true  // Ensure ordered delivery for file integrity
        ..protocol = 'file-transfer'  // Custom protocol identifier
        ..negotiated = false;  // Let WebRTC handle negotiation
      
      peerState.dataChannel = await peerState.peerConnection?.createDataChannel('clipboard', dataChannelInit);
      if (peerState.dataChannel != null) {
        _log('✅ DATA CHANNEL CREATED', {
          'peer': peerId,
          'label': peerState.dataChannel!.label,
          'state': peerState.dataChannel!.state.toString()
        });
        _log('📡 SETTING UP DATA CHANNEL MANUALLY (SENDER SIDE)', peerId);
        _setupDataChannel(peerId, peerState.dataChannel!);
      } else {
        _log('❌ FAILED TO CREATE DATA CHANNEL', peerId);
      }
      
      // Create and send offer
      _log('📡 CREATING OFFER', peerId);
      RTCSessionDescription description = await peerState.peerConnection!.createOffer();
      await peerState.peerConnection!.setLocalDescription(description);
      
      if (onSignalGenerated != null) {
        _log('📤 SENDING OFFER TO PEER', peerId);
        _log('🔍 OFFER DETAILS', {
          'peer': peerId,
          'type': 'offer',
          'sdp_length': description.sdp?.length ?? 0,
          'callback_exists': onSignalGenerated != null
        });
        onSignalGenerated!(peerId, {'type': 'offer', 'sdp': description.sdp});
        _log('✅ OFFER SIGNAL SENT SUCCESSFULLY', peerId);
      } else {
        _log('❌ ERROR: Cannot send offer signal', {
          'peerId': peerId,
          'callback_exists': onSignalGenerated != null
        });
      }
      
      _log('✅ createOffer COMPLETED SUCCESSFULLY', peerId);
    } catch (e) {
      _log('❌ CRITICAL ERROR in createOffer', '$peerId: ${e.toString()}');
      _log('❌ STACK TRACE', '$peerId: ${e.toString()}');
    }
  }

  Future<void> handleOffer(dynamic offer, String from) async {
    _log('📥 HANDLING OFFER FROM', from);
    
    // Initialize peer connection for this specific peer
    await _initPeerConnection(from);
    final peerState = _getPeerState(from);
    
    _log('🔍 CURRENT STATE - Remote desc set: ${peerState.remoteDescriptionSet}, Queue size: ${peerState.pendingCandidates.length}', from);
    
    try {
      if (peerState.peerConnection == null) {
        _log('❌ ERROR: PeerConnection is null after init, cannot handle offer', from);
        return;
      }
      
      final offerSdp = offer['sdp'] as String?;
      final offerType = offer['type'] as String? ?? 'offer';

      // Pre-add transceivers if remote offer includes media sections
      if (offerSdp != null) {
        await _ensureRecvTransceiversForOffer(from, offerSdp);
      }
      
      // Set remote description with error handling
      await peerState.peerConnection?.setRemoteDescription(RTCSessionDescription(offerSdp, offerType));

      // Wait until remote description is actually visible to the engine
      final rdReady = await _waitForRemoteDescription(from, timeoutMs: 1000);
      peerState.remoteDescriptionSet = rdReady;
      if (!peerState.remoteDescriptionSet) {
        _log('❌ REMOTE DESCRIPTION NOT READY AFTER TIMEOUT', from);
        return;
      }
      _log('✅ REMOTE DESCRIPTION SET AND READY', from);
      
      // Small delay to ensure the peer connection is fully ready
      await Future.delayed(Duration(milliseconds: 50));
      
      // Process any queued candidates for this peer
      await _processQueuedCandidates(from);
      
      // Create answer with error handling and retry logic
      _log('📡 CREATING ANSWER', from);
      RTCSessionDescription? description;
      int retryCount = 0;
      
      while (description == null && retryCount < 3) {
        try {
          // Small delay to ensure peer connection is fully ready
          if (retryCount > 0) {
            _log('🔄 RETRYING CREATE ANSWER - Attempt ${retryCount + 1}', from);
            await Future.delayed(Duration(milliseconds: 100 * retryCount));
          }
          
          description = await peerState.peerConnection!.createAnswer();
          _log('✅ ANSWER CREATED SUCCESSFULLY', from);
        } catch (e) {
          retryCount++;
          _log('❌ CREATE ANSWER FAILED - Attempt $retryCount', '$from: ${e.toString()}');
          
          if (retryCount >= 3) {
            _log('❌ FAILED TO CREATE ANSWER AFTER 3 ATTEMPTS', from);
            return;
          }
        }
      }
      
      if (description != null) {
        await peerState.peerConnection!.setLocalDescription(description);
        _log('📤 SENDING ANSWER', from);
        if (onSignalGenerated != null) {
          onSignalGenerated!(from, {'type': 'answer', 'sdp': description.sdp});
        }
      }
    } catch (e, stackTrace) {
      _log('❌ CRITICAL ERROR IN HANDLE OFFER', '$from: ${e.toString()}');
      _log('❌ STACK TRACE', '$from: ${stackTrace.toString()}');
      
      // Reset state on error for this peer
      peerState.remoteDescriptionSet = false;
      peerState.pendingCandidates.clear();
    }
  }

  Future<void> handleAnswer(dynamic answer, String from) async {
    if (!_isInitialized) {
      await init();
    }
    
    final peerState = _getPeerState(from);
    if (peerState.peerConnection == null) {
      _log('❌ ERROR: PeerConnection is null, cannot handle answer', from);
      return;
    }
    
    // Check signaling state to avoid calling setRemoteDescription in wrong state
    final state = peerState.peerConnection!.signalingState;
    _log('📥 HANDLING ANSWER - signalingState: $state, remoteSet: ${peerState.remoteDescriptionSet}', from);

    // If we're already stable and have a remote description, this is likely a duplicate answer; ignore
    if (state == RTCSignalingState.RTCSignalingStateStable &&
        peerState.peerConnection!.getRemoteDescription() != null) {
      _log('ℹ️ IGNORING DUPLICATE ANSWER: already stable with remote description set', from);
      return;
    }

    // Only set remote answer when we are in have-local-offer (we are the offerer)
    if (state != RTCSignalingState.RTCSignalingStateHaveLocalOffer) {
      _log('⚠️ UNEXPECTED STATE FOR REMOTE ANSWER: $state. Skipping setRemoteDescription to avoid error.', from);
      return;
    }

    try {
      await peerState.peerConnection!.setRemoteDescription(
        RTCSessionDescription(answer['sdp'], answer['type']),
      );
      // Wait until remote description is actually set in engine
      peerState.remoteDescriptionSet = await _waitForRemoteDescription(from, timeoutMs: 1000);
      
      // Process any queued candidates for this peer
      await _processQueuedCandidates(from);
    } catch (e, st) {
      _log('❌ FAILED TO SET REMOTE ANSWER (guarded)', '$from: ${e.toString()}');
      _log('❌ STACK TRACE', '$from: ${st.toString()}');
      // Do not rethrow; just log to prevent crashing the app
    }
  }

  Future<void> handleCandidate(dynamic candidate, String from) async {
    if (!_isInitialized) {
      await init();
    }
    
    final peerState = _getPeerState(from);
    if (peerState.peerConnection == null || peerState.isResetting) {
      _log('❌ ERROR: PeerConnection is null or resetting, queueing candidate', from);
      final iceCandidate = RTCIceCandidate(
        candidate['candidate'],
        candidate['sdpMid'],
        candidate['sdpMLineIndex'],
      );
      peerState.pendingCandidates.add(iceCandidate);
      return;
    }
    
    final iceCandidate = RTCIceCandidate(
      candidate['candidate'],
      candidate['sdpMid'],
      candidate['sdpMLineIndex'],
    );
    
    _log('🧊 HANDLING ICE CANDIDATE - Remote desc set: ${peerState.remoteDescriptionSet}, Queue size: ${peerState.pendingCandidates.length}', from);
    
    // Always queue until remote description is confirmed ready; processing is batched
    if (!peerState.remoteDescriptionSet || peerState.isResetting || peerState.peerConnection?.getRemoteDescription() == null) {
      _log('📦 QUEUEING ICE CANDIDATE (remote description not ready)', from);
      peerState.pendingCandidates.add(iceCandidate);
      return;
    }
    
    // If RD is ready, we'll still prefer processing through the queue to keep ordering
    peerState.pendingCandidates.add(iceCandidate);
    await _processQueuedCandidates(from);
  }

  Future<void> _processQueuedCandidates(String peerId) async {
    final peerState = _getPeerState(peerId);
    if (peerState.pendingCandidates.isEmpty) return;
    
    _log('📦 PROCESSING ${peerState.pendingCandidates.length} QUEUED ICE CANDIDATES', peerId);
    
    // Verify remote description is actually set before processing
    if (peerState.peerConnection?.getRemoteDescription() == null) {
      _log('⚠️ REMOTE DESCRIPTION STILL NULL, KEEPING CANDIDATES QUEUED', peerId);
      return;
    }
    
    final candidatesToProcess = List<RTCIceCandidate>.from(peerState.pendingCandidates);
    final failedCandidates = <RTCIceCandidate>[];
    peerState.pendingCandidates.clear();
    
    for (final candidate in candidatesToProcess) {
      try {
        await peerState.peerConnection?.addCandidate(candidate);
        _log('✅ QUEUED ICE CANDIDATE ADDED SUCCESSFULLY', peerId);
      } catch (e) {
        _log('❌ ERROR ADDING QUEUED ICE CANDIDATE', '$peerId: ${e.toString()}');
        // If it still fails, keep it for later
        failedCandidates.add(candidate);
      }
    }
    
    // Re-queue any candidates that still failed
    if (failedCandidates.isNotEmpty) {
      _log('📦 RE-QUEUEING ${failedCandidates.length} FAILED CANDIDATES', peerId);
      peerState.pendingCandidates.addAll(failedCandidates);
    } else {
      _log('📦 FINISHED PROCESSING ALL QUEUED CANDIDATES SUCCESSFULLY', peerId);
    }
  }

  // Polls until getRemoteDescription is non-null or timeout
  Future<bool> _waitForRemoteDescription(String peerId, {int timeoutMs = 1000, int intervalMs = 25}) async {
    final peerState = _getPeerState(peerId);
    final deadline = DateTime.now().add(Duration(milliseconds: timeoutMs));
    while (DateTime.now().isBefore(deadline)) {
      try {
        final rd = peerState.peerConnection?.getRemoteDescription();
        if (rd != null) {
          return true;
        }
      } catch (_) {}
      await Future.delayed(Duration(milliseconds: intervalMs));
    }
    return false;
  }

  // If the offer SDP includes audio/video m-lines, add recvonly transceivers
  Future<void> _ensureRecvTransceiversForOffer(String sdp, String peerId) async {
    final peerState = _getPeerState(peerId);
    try {
      final hasAudio = sdp.contains('\nm=audio');
      final hasVideo = sdp.contains('\nm=video');
      if (hasAudio) {
        _log('🎚️ ADDING RECVONLY AUDIO TRANSCEIVER', peerId);
        await peerState.peerConnection?.addTransceiver(
          kind: RTCRtpMediaType.RTCRtpMediaTypeAudio,
          init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
        );
      }
      if (hasVideo) {
        _log('🎚️ ADDING RECVONLY VIDEO TRANSCEIVER', peerId);
        await peerState.peerConnection?.addTransceiver(
          kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
          init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
        );
      }
    } catch (e) {
      _log('⚠️ ERROR ADDING RECV TRANSCEIVERS (IGNORING)', '$peerId: ${e.toString()}');
    }
  }

  // ===== Streaming file receiver helpers (proto v2) =====
  // Returns true if files were prepared and we're ready to receive.
  // Returns false if the user cancelled any save dialog; in that case, the caller should send a 'cancel' control.
  Future<bool> _promptDirectoryAndPrepareFiles(
      String peerId, String sessionId, List<Map<String, dynamic>> filesMeta) async {
    final incomingFiles = <_IncomingFile>[];
    try {
      if (filesMeta.isEmpty) {
        _log('⚠️ NO FILES META PROVIDED FOR SESSION', sessionId);
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
          _log('🚫 USER CANCELLED SAVE DIALOG');
          // Clean up any files that were already created for this session
          for (final created in incomingFiles) {
            await created.sink.close();
            await created.file.delete();
          }
          return false;
        }

        sessionDir ??= File(savePath).parent.path;
        await File(savePath).parent.create(recursive: true);
        final file = File(savePath);
        final sink = file.openWrite();
        incomingFiles.add(_IncomingFile(
          name: name,
          size: (meta['size'] as num?)?.toInt() ?? 0,
          checksum: (meta['checksum'] as String?) ?? '',
          file: file,
          sink: sink,
        ));
      }

      final session = _FileSession(sessionDir!, incomingFiles);
      final peerState = _getPeerState(peerId);
      peerState.fileSessions[sessionId] = session;
      _log('📂 FILE SESSION PREPARED', {
        'sessionId': sessionId,
        'dir': session.dirPath,
        'files': session.files.length
      });
      
      // Show 0% download notification for each file at the start
      for (final fileInfo in incomingFiles) {
        _notificationService.showFileDownloadProgress(0, fileInfo.name);
        // Don't set lastNotificationTime here - let the first progress notification show immediately
      }
      return true;
    } catch (e) {
      _log('❌ ERROR PREPARING FILE SESSION', e.toString());
      // Clean up any files that were created before the error
      for (final created in incomingFiles) {
        await created.sink.close();
        await created.file.delete();
      }
      return false;
    }
  }

  Future<void> _handleFileChunk(String peerId, String sessionId, int fileIndex, String dataB64) async {
    final peerState = _getPeerState(peerId);
    final session = peerState.fileSessions[sessionId];
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
        peerState.dataChannel?.send(RTCDataChannelMessage('{"__sc_proto":2,"kind":"ack"}'));
      }
    } catch (e) {
      _log('❌ ERROR WRITING FILE CHUNK', {'sessionId': sessionId, 'index': fileIndex, 'error': e.toString()});
    }
  }

  Future<void> _handleFileEnd(String peerId, String sessionId, int fileIndex) async {
    final peerState = _getPeerState(peerId);
    // Send final ACK to ensure sender can complete
    _log('📬 SENDING FINAL ACK');
    peerState.dataChannel?.send(RTCDataChannelMessage('{"__sc_proto":2,"kind":"ack"}'));

    final session = peerState.fileSessions[sessionId];
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

  Future<void> _finalizeFileSession(String peerId, String sessionId) async {
    final peerState = _getPeerState(peerId);
    final session = peerState.fileSessions.remove(sessionId);
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
        _notificationService.showFileDownloadComplete(f.name, peerId);
      }
    } catch (e) {
      _log('❌ ERROR FINALIZING FILE SESSION', e.toString());
    }
  }

  Future<void> _abortFileSession(String peerId, String sessionId) async {
    final peerState = _getPeerState(peerId);
    final session = peerState.fileSessions.remove(sessionId);
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
    // Close all peer connections
    for (final peerState in _peers.values) {
      peerState.dataChannel?.close();
      peerState.peerConnection?.close();
      peerState.cleanup();
    }
    _peers.clear();
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
