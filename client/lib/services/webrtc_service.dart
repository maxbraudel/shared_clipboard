import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:shared_clipboard/services/file_transfer_service.dart';

class WebRTCService {
  RTCPeerConnection? _peerConnection;
  RTCDataChannel? _dataChannel;
  String? _peerId;
  bool _isInitialized = false;
  String? _pendingClipboardContent;
  bool _isResetting = false; // Prevent multiple resets
  final FileTransferService _fileTransferService = FileTransferService();
  
  // Queue for ICE candidates received before remote description is set
  final List<RTCIceCandidate> _pendingCandidates = [];
  bool _remoteDescriptionSet = false;

  // Chunking protocol settings and state
  static const int _chunkSize = 16 * 1024; // 16 KB safe default for data channels
  static const int _bufferedLowThreshold = 64 * 1024; // 64 KB backpressure threshold
  final Map<String, StringBuffer> _rxBuffers = {};
  final Map<String, int> _rxReceivedBytes = {};
  final Map<String, int> _rxTotalBytes = {};
  Completer<void>? _bufferLowCompleter;
  
  // Callback to send signals back to socket service
  Function(String to, dynamic signal)? onSignalGenerated;

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
        ]
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

  void _setupDataChannel(RTCDataChannel channel) {
    _dataChannel = channel;
    _log('📡 SETTING UP DATA CHANNEL', {
      'label': channel.label,
      'state': channel.state.toString(),
      'hasPendingContent': _pendingClipboardContent != null,
      'role': _pendingClipboardContent != null ? 'SENDER' : 'RECEIVER'
    });
    
    // Check if channel is already open
    if (channel.state == RTCDataChannelState.RTCDataChannelOpen) {
      _log('📡 DATA CHANNEL IS ALREADY OPEN DURING SETUP');
      _handleDataChannelOpen();
    }
    
    // Backpressure: fire completer when buffered amount goes low
    _dataChannel?.onBufferedAmountLow = (int amount) {
      _log('📉 DATA CHANNEL BUFFERED AMOUNT LOW');
      _bufferLowCompleter?.complete();
      _bufferLowCompleter = null;
    };
    _dataChannel?.bufferedAmountLowThreshold = _bufferedLowThreshold;

    _dataChannel?.onDataChannelState = (state) {
      _log('📡 DATA CHANNEL STATE CHANGED', state.toString());
      if (state == RTCDataChannelState.RTCDataChannelOpen) {
        _handleDataChannelOpen();
      }
    };

    _dataChannel?.onMessage = (message) {
      // We only send text messages; support both chunked and legacy single payloads
      final text = message.text;
      _log('📥 RECEIVED DATA MESSAGE (RECEIVER ROLE)', '${text.length} bytes');
      try {
        // Try to parse as protocol envelope
        final isJsonEnvelope = text.startsWith('{') && text.contains('"__sc_proto"');
        if (isJsonEnvelope) {
          final Map<String, dynamic> env = jsonDecode(text);
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

  void _handleDataChannelOpen() {
    _log('✅ DATA CHANNEL IS NOW OPEN');
    
    // Only send content if we have pending content (i.e., we're the sender)
    if (_pendingClipboardContent != null) {
      final payload = _pendingClipboardContent!;
      _log('📤 SENDING PENDING CLIPBOARD CONTENT (SENDER ROLE)', {'bytes': payload.length});
      _sendLargeMessage(payload).then((_) {
        _log('✅ CLIPBOARD CONTENT SENT SUCCESSFULLY');
        _pendingClipboardContent = null;
      }).catchError((e) {
        _log('❌ ERROR SENDING CLIPBOARD CONTENT', e.toString());
      });
    } else {
      _log('⚠️ NO PENDING CLIPBOARD CONTENT TO SEND');
    }
  }

  // Send message with chunking and backpressure-safe logic
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
      if ((_dataChannel!.bufferedAmount ?? 0) > _bufferedLowThreshold) {
        _log('⏳ WAITING BUFFER TO DRAIN', {'buffered': _dataChannel!.bufferedAmount});
        _bufferLowCompleter = Completer<void>();
        await _bufferLowCompleter!.future.timeout(Duration(seconds: 5), onTimeout: () {
          _log('⚠️ BUFFER LOW TIMEOUT, CONTINUING');
          _bufferLowCompleter = null;
        });
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
        _log('📁 RECEIVED FILES', '${clipboardContent.files.length} files');
        _fileTransferService.setClipboardContent(clipboardContent);
        _log('✅ FILES SET TO CLIPBOARD/TEMP FOLDER');
      } else {
        _log('📝 RECEIVED TEXT', clipboardContent.text);
        Clipboard.setData(ClipboardData(text: clipboardContent.text));
        _log('📋 TEXT CLIPBOARD UPDATED SUCCESSFULLY');
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

  Future<void> createOffer(String? peerId) async {
    try {
      _log('🎯 createOffer CALLED', peerId);
      
      // Reset connection state for clean start
      await _resetConnection();
      
      if (_peerConnection == null) {
        _log('❌ ERROR: PeerConnection is null after reset, cannot create offer');
        return;
      }
      
      // Set peer ID if provided
      if (peerId != null) {
        _peerId = peerId;
        _log('🎯 CREATING OFFER FOR PEER', peerId);
      }
      
      // Read current clipboard content (text or files)
      try {
        _log('📋 READING CLIPBOARD FOR OFFER');
        final clipboardContent = await _fileTransferService.getClipboardContent();
        
        if (clipboardContent.isFiles) {
          _log('📁 FOUND FILES IN CLIPBOARD', '${clipboardContent.files.length} files');
          _pendingClipboardContent = _fileTransferService.serializeClipboardContent(clipboardContent);
          _log('� FILES SERIALIZED FOR TRANSFER', '${_pendingClipboardContent!.length} bytes');
        } else if (clipboardContent.text.isNotEmpty) {
          _log('📝 FOUND TEXT IN CLIPBOARD', clipboardContent.text);
          _pendingClipboardContent = _fileTransferService.serializeClipboardContent(clipboardContent);
        } else {
          _log('❌ NO CLIPBOARD CONTENT TO SHARE');
        }
      } catch (e) {
        _log('❌ ERROR READING CLIPBOARD', e.toString());
      }
      
      // Create data channel
      _log('📡 CREATING DATA CHANNEL');
      _dataChannel = await _peerConnection?.createDataChannel('clipboard', RTCDataChannelInit());
      if (_dataChannel != null) {
        _log('✅ DATA CHANNEL CREATED', {
          'label': _dataChannel!.label,
          'state': _dataChannel!.state.toString()
        });
        _log('📡 SETTING UP DATA CHANNEL MANUALLY (SENDER SIDE)');
        _setupDataChannel(_dataChannel!);
      } else {
        _log('❌ FAILED TO CREATE DATA CHANNEL');
      }
      
      // Create and send offer
      _log('📡 CREATING OFFER');
      RTCSessionDescription description = await _peerConnection!.createOffer();
      await _peerConnection!.setLocalDescription(description);
      
      if (_peerId != null && onSignalGenerated != null) {
        _log('📤 SENDING OFFER TO PEER', _peerId);
        _log('🔍 OFFER DETAILS', {
          'type': 'offer',
          'sdp_length': description.sdp?.length ?? 0,
          'callback_exists': onSignalGenerated != null
        });
        onSignalGenerated!(_peerId!, {'type': 'offer', 'sdp': description.sdp});
        _log('✅ OFFER SIGNAL SENT SUCCESSFULLY');
      } else {
        _log('❌ ERROR: Cannot send offer signal', {
          'peerId': _peerId,
          'callback_exists': onSignalGenerated != null
        });
      }
      
      _log('✅ createOffer COMPLETED SUCCESSFULLY');
    } catch (e) {
      _log('❌ CRITICAL ERROR in createOffer', e.toString());
      _log('❌ STACK TRACE', e.toString());
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
    
    _log('📥 HANDLING ANSWER');
    await _peerConnection?.setRemoteDescription(RTCSessionDescription(answer['sdp'], answer['type']));
    // Wait until remote description is actually set in engine
    _remoteDescriptionSet = await _waitForRemoteDescription(timeoutMs: 1000);
    
    // Process any queued candidates
    await _processQueuedCandidates();
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

  void dispose() {
    _dataChannel?.close();
    _peerConnection?.close();
  }
}
