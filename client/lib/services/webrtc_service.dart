import 'dart:io';
import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:shared_clipboard/services/file_transfer_service.dart';
import 'package:shared_clipboard/services/notification_service.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_clipboard/core/logger.dart';


class WebRTCService {
  RTCPeerConnection? _peerConnection;
  RTCDataChannel? _dataChannel;
  String? _peerId;
  bool _isInitialized = false;
  ClipboardContent? _pendingClipboardContent; // store structured content to allow streaming
  bool _isResetting = false; // Prevent multiple resets
  final FileTransferService _fileTransferService = FileTransferService();
  final NotificationService _notificationService = NotificationService();
  final AppLogger _logger = logTag('WEBRTC');
  
  // Queue for ICE candidates received before remote description is set
  final List<RTCIceCandidate> _pendingCandidates = [];
  bool _remoteDescriptionSet = false;

  // Chunking protocol settings and state - reduced for better reliability
  static const int _chunkSize = 8 * 1024; // 8 KB chunks for better SCTP compatibility
  static const int _bufferedLowThreshold = 32 * 1024; // 32 KB backpressure threshold
  final Map<String, StringBuffer> _rxBuffers = {};
  final Map<String, int> _rxReceivedBytes = {};
  final Map<String, int> _rxTotalBytes = {};
  Completer<void>? _bufferLowCompleter;

  // Streaming files state (proto v2)
  final Map<String, _FileSession> _fileSessions = {};
  final Map<String, Completer<void>> _sessionReadyCompleters = {};
  Completer<void>? _ackCompleter; // legacy chunk ACK (every 100 chunks) for current active send
  // Per-session ACK waiters for critical boundaries
  final Map<String, Completer<void>> _ackWaiters = {}; // key: "sessionId:ackType"

  // Sending state (simplified - no queue management on sender side)
  bool _isSending = false;
  ClipboardContent? _preparedOutgoingContent; // used by createOffer to skip re-reading clipboard
  ClipboardContent? _currentTransferContent; // track current transfer for notifications
  
  // Callback functions for UI state updates
  Function(String type, String content, String origin)? onClipboardReceived;
  Function(String fileName, double progress)? onDownloadProgress;
  Function()? onDownloadComplete;
  Function(String origin)? onNoContentAvailable;
  Function(String fileName)? onWaitingForUserLocation;
  Function(String reason)? onDownloadFailed;
  
  // Callback to send signals back to socket service
  Function(String to, dynamic signal)? onSignalGenerated;

  WebRTCService();

  // Helper function for timestamped logging
  void _log(String message, [dynamic data]) {
    if (data != null) {
      _logger.i(message, data);
    } else {
      _logger.i(message);
    }

  }

  // Helper method to send "no content available" signal to requester
  Future<void> _sendNoContentAvailableSignal(String? requesterId) async {
    if (requesterId == null || onSignalGenerated == null) return;
    
    try {
      // Send no content available message to requester via socket
      final noContentMessage = {
        'type': 'no-content-available',
        'message': 'No clipboard content available to share'
      };
      
      onSignalGenerated!(requesterId, noContentMessage);
      _log('📤 SENT NO CONTENT AVAILABLE SIGNAL TO REQUESTER', {
        'requesterId': requesterId
      });
    } catch (e) {
      _log('❌ ERROR SENDING NO CONTENT AVAILABLE SIGNAL', e.toString());
    }
  }

  // Streaming files protocol (proto v2)
  Future<void> _sendFilesStreaming(ClipboardContent content) async {
    if (_dataChannel == null) throw StateError('DataChannel not ready');
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
    _dataChannel!.send(RTCDataChannelMessage(startEnv));

    // Wait for receiver to prepare and acknowledge readiness
    final ready = Completer<void>();
    _sessionReadyCompleters[sessionId] = ready;
    try {
      // Allow ample time for the receiver to choose save locations
      await ready.future.timeout(const Duration(minutes: 3));
      _log('✅ RECEIVER READY, STARTING STREAM', sessionId);
    } catch (e) {
      _log('⚠️ RECEIVER READY TIMEOUT, ABORTING STREAM', sessionId);
      _sessionReadyCompleters.remove(sessionId);
      return;
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
            _log('📤 SENDING PROGRESS', {
              'file': f.name,
              'chunk': chunkCount,
              'of': totalChunks,
              'progress': '$progress%',
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
          rethrow;
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
      
      // Note: Do not wait for an extra ACK here; the receiver sends ACKs every 100 chunks
      // and will ACK upon file_end. We proceed to file_end immediately to avoid timeouts.

      _log('✅ FINISHED SENDING FILE', {
        'file': f.name,
        'totalChunks': chunkCount,
        'totalBytes': bytes.length,
        'finalBufferedAmount': _dataChannel!.bufferedAmount
      });
      
      // Ensure buffered data is flushed before signaling file end
      while ((_dataChannel!.bufferedAmount ?? 0) > _bufferedLowThreshold) {
        _log('⏳ WAITING BUFFER TO DRAIN BEFORE FILE_END', {'buffered': _dataChannel!.bufferedAmount});
        _bufferLowCompleter = Completer<void>();
        try {
          await _bufferLowCompleter!.future;
        } catch (_) {
          await Future.delayed(const Duration(milliseconds: 100));
        }
      }

      // End of this file
      final fileEndAckKey = '$sessionId:file_end';
      _ackWaiters[fileEndAckKey] = Completer<void>();
      final fileEnd = jsonEncode({
        '__sc_proto': 2,
        'kind': 'files',
        'mode': 'file_end',
        'sessionId': sessionId,
        'fileIndex': i,
      });
      _dataChannel!.send(RTCDataChannelMessage(fileEnd));

      // Wait for ACK confirming receiver processed file end
      _log('⏳ WAITING FOR FILE_END ACK (scoped)');
      try {
        await _ackWaiters[fileEndAckKey]!.future.timeout(const Duration(seconds: 30));
        _log('✅ FILE_END ACK RECEIVED');
      } catch (e) {
        _log('❌ FILE_END ACK TIMEOUT', e.toString());
        throw Exception('File end ACK timeout');
      } finally {
        _ackWaiters.remove(fileEndAckKey);
      }
    }

    // Ensure buffer drains before session end
    while ((_dataChannel!.bufferedAmount ?? 0) > _bufferedLowThreshold) {
      _log('⏳ WAITING BUFFER TO DRAIN BEFORE SESSION END', {'buffered': _dataChannel!.bufferedAmount});
      _bufferLowCompleter = Completer<void>();
      try {
        await _bufferLowCompleter!.future;
      } catch (_) {
        await Future.delayed(const Duration(milliseconds: 100));
      }
    }

    // End session
    final endAckKey = '$sessionId:end';
    _ackWaiters[endAckKey] = Completer<void>();
    final endEnv = jsonEncode({
      '__sc_proto': 2,
      'kind': 'files',
      'mode': 'end',
      'sessionId': sessionId,
    });
    _dataChannel!.send(RTCDataChannelMessage(endEnv));

    // Wait for final ACK after receiver finalizes
    _log('⏳ WAITING FOR SESSION END ACK (scoped)');
    try {
      await _ackWaiters[endAckKey]!.future.timeout(const Duration(seconds: 30));
      _log('✅ SESSION END ACK RECEIVED');
    } catch (e) {
      _log('❌ SESSION END ACK TIMEOUT', e.toString());
      throw Exception('Session end ACK timeout');
    } finally {
      _ackWaiters.remove(endAckKey);
      // Current send session finished
      _isSending = false;
      _currentTransferContent = null; // Clear current transfer tracking
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
        Future.delayed(const Duration(seconds: 2)).then((_) => throw TimeoutException('PeerConnection creation timeout', const Duration(seconds: 2))),
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
      _log('📉 DATA CHANNEL BUFFERED AMOUNT LOW', {'amount': amount});
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
      // Support: proto v2 streaming (files), proto v1 chunked JSON payloads, and legacy single payload
      final text = message.text;
      _log('📥 RECEIVED DATA MESSAGE (RECEIVER ROLE)', '${text.length} bytes');
      try {
        // Handle ACKs
        if (text.startsWith('{') && text.contains('"kind":"ack"')) {
          try {
            final Map<String, dynamic> ack = jsonDecode(text);
            if (ack['__sc_proto'] == 2 && ack['kind'] == 'ack') {
              final sid = ack['sessionId'] as String?;
              final at = ack['ack'] as String?; // 'chunks' | 'file_end' | 'end'
              if (sid != null && at != null) {
                final key = '$sid:$at';
                final c = _ackWaiters[key];
                if (c != null && !c.isCompleted) {
                  _log('📬 ACK RECEIVED (scoped)', {'sessionId': sid, 'ack': at});
                  c.complete();
                  return;
                }
              }
              // Fallback: legacy chunk ACK without session scoping
              if (_ackCompleter != null && !_ackCompleter!.isCompleted) {
                _log('📬 ACK RECEIVED (legacy)');
                _ackCompleter!.complete();
                return;
              }
            }
          } catch (_) {
            // Not a JSON ack we recognize; continue parsing below
          }
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
              _log('🔰 START FILE STREAM SESSION', {'sessionId': sessionId, 'files': filesMeta.length});
              () async {
                final prepared = await _promptDirectoryAndPrepareFiles(sessionId, filesMeta);
                if (!prepared) {
                  // Inform sender we cancelled so it can abort immediately
                  final cancelEnv = jsonEncode({
                    '__sc_proto': 2,
                    'kind': 'files',
                    'mode': 'cancel',
                    'sessionId': sessionId,
                  });
                  _dataChannel?.send(RTCDataChannelMessage(cancelEnv));
                  _log('🚫 RECEIVER CANCELLED BEFORE READY', sessionId);
                  return;
                }
                // Notify sender we are ready to receive chunks
                final readyEnv = jsonEncode({
                  '__sc_proto': 2,
                  'kind': 'files',
                  'mode': 'ready',
                  'sessionId': sessionId,
                });
                _dataChannel?.send(RTCDataChannelMessage(readyEnv));
                _log('📨 SENT RECEIVER READY', sessionId);
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
              // Send scoped ACK for file_end
              final ack = jsonEncode({
                '__sc_proto': 2,
                'kind': 'ack',
                'sessionId': sessionId,
                'ack': 'file_end',
              });
              _dataChannel?.send(RTCDataChannelMessage(ack));
              return;
            }
            if (mode == 'end' && sessionId != null) {
              // Immediately ACK end to unblock sender, then finalize asynchronously
              final ack = jsonEncode({
                '__sc_proto': 2,
                'kind': 'ack',
                'sessionId': sessionId,
                'ack': 'end',
              });
              _dataChannel?.send(RTCDataChannelMessage(ack));
              () async {
                await _finalizeFileSession(sessionId);
              }();
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

  void _handleDataChannelOpen() {
    _log('✅ DATA CHANNEL IS NOW OPEN');
    
    // Only send content if we have pending content (i.e., we're the sender)
    if (_pendingClipboardContent != null) {
      final content = _pendingClipboardContent!;
      if (content.isFiles) {
        _log('📤 SENDING FILES VIA STREAMING PROTOCOL', {'count': content.files.length});
        _sendFilesStreaming(content).then((_) {
          _log('✅ FILES STREAMED SUCCESSFULLY');
          _pendingClipboardContent = null;
          _isSending = false;
          _currentTransferContent = null; // Clear current transfer tracking
        }).catchError((e) {
          _log('❌ ERROR STREAMING FILES', e.toString());
          _isSending = false;
          _currentTransferContent = null; // Clear current transfer tracking
        });
      } else {
        final payload = _fileTransferService.serializeClipboardContent(content);
        _log('📤 SENDING TEXT/JSON VIA CHUNKING', {'bytes': payload.length});
        _sendLargeMessage(payload).then((_) {
          _log('✅ CLIPBOARD CONTENT SENT SUCCESSFULLY');
          _pendingClipboardContent = null;
          _isSending = false;
          _currentTransferContent = null; // Clear current transfer tracking
        }).catchError((e) {
          _log('❌ ERROR SENDING CLIPBOARD CONTENT', e.toString());
          _isSending = false;
          _currentTransferContent = null; // Clear current transfer tracking
        });
      }
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
          await Future.delayed(const Duration(milliseconds: 100));
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
        
        // Notify UI about received files
        if (onClipboardReceived != null) {
          final fileName = clipboardContent.files.isNotEmpty ? clipboardContent.files.first.name : 'files';
          onClipboardReceived!('file', fileName, _peerId ?? 'Unknown Device');
        }
      } else {
        _log('📝 RECEIVED TEXT', clipboardContent.text);
        Clipboard.setData(ClipboardData(text: clipboardContent.text));
        _log('📋 TEXT CLIPBOARD UPDATED SUCCESSFULLY');
        
        // Show clipboard receive success notification for text
        _notificationService.showClipboardReceiveSuccess(_peerId ?? 'Unknown Device', isFile: false);
        
        // Notify UI about received text
        if (onClipboardReceived != null) {
          onClipboardReceived!('text', clipboardContent.text, _peerId ?? 'Unknown Device');
        }
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
      Future.delayed(const Duration(seconds: 3)).then((_) => throw TimeoutException('Init timeout', const Duration(seconds: 3))),
    ]);
  }

  void _forceCleanup() {
    _log('🧹 FORCE CLEANUP');
    
    // Check if we were in the middle of a download and notify UI
    if (_fileSessions.isNotEmpty && onDownloadFailed != null) {
      onDownloadFailed!('Connection interrupted during download');
    }
    
    _isSending = false;
    _pendingClipboardContent = null;
    _currentTransferContent = null;
    _preparedOutgoingContent = null;
    _fileSessions.clear();
    _dataChannel = null;
    _peerConnection = null;
    _peerId = null;
    _isInitialized = false;
    _pendingCandidates.clear();
    _remoteDescriptionSet = false;
  }

  Future<void> createOffer(String? peerId) async {
    try {
      _log('🎯 createOffer CALLED', peerId);
      
      // Note: Queue management is now handled by the requesting client
      // The sender always responds immediately if available

      // Reset connection state for clean start of this send
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
      
      // Determine content to send: either prepared dequeued content or read clipboard now
      try {
        if (_preparedOutgoingContent != null) {
          _pendingClipboardContent = _preparedOutgoingContent;
          _log('📦 USING PREPARED OUTGOING CONTENT', {
            'type': _pendingClipboardContent!.isFiles ? 'files' : 'text'
          });
        } else {
          _log('📋 READING CLIPBOARD FOR OFFER');
          final clipboardContent = await _fileTransferService.getClipboardContent();
          if (clipboardContent.isFiles) {
            _log('📁 FOUND FILES IN CLIPBOARD', '${clipboardContent.files.length} files');
            _pendingClipboardContent = clipboardContent; // we'll stream them
            _log('📦 FILES READY FOR STREAMING', {'count': clipboardContent.files.length});
          } else if (clipboardContent.text.isNotEmpty) {
            _log('📝 FOUND TEXT IN CLIPBOARD', clipboardContent.text);
            _pendingClipboardContent = clipboardContent; // will serialize at send
          } else {
            _log('❌ NO CLIPBOARD CONTENT TO SHARE');
            // Send "no content available" signal to requesting client
            await _sendNoContentAvailableSignal(peerId);
            return; // Don't proceed with WebRTC connection setup
          }
        }
      } catch (e) {
        _log('❌ ERROR READING CLIPBOARD', e.toString());
      } finally {
        // Mark sending started if we have content; clear prepared flags
        if (_pendingClipboardContent != null) {
          _isSending = true;
          _currentTransferContent = _pendingClipboardContent; // Track current transfer for notifications
        }
        _preparedOutgoingContent = null;
      }
      
      // Create data channel with proper configuration for large file transfers
      _log('📡 CREATING DATA CHANNEL');
      final dataChannelInit = RTCDataChannelInit()
        ..ordered = true  // Ensure ordered delivery for file integrity
        ..protocol = 'file-transfer'  // Custom protocol identifier
        ..negotiated = false;  // Let WebRTC handle negotiation
      
      _dataChannel = await _peerConnection?.createDataChannel('clipboard', dataChannelInit);
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
      await Future.delayed(const Duration(milliseconds: 50));
      
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
    if (state == RTCSignalingState.RTCSignalingStateStable && _remoteDescriptionSet) {
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
  Future<bool> _promptDirectoryAndPrepareFiles(
      String sessionId, List<Map<String, dynamic>> filesMeta) async {
    final incomingFiles = <_IncomingFile>[];
    try {
      if (filesMeta.isEmpty) {
        _log('⚠️ NO FILES META PROVIDED FOR SESSION', sessionId);
        return false;
      }

      String? sessionDir;
      for (final meta in filesMeta) {
        final name = (meta['name'] as String?) ?? 'file';
        
        // Notify UI that we're waiting for user to choose download location
        if (onWaitingForUserLocation != null) {
          onWaitingForUserLocation!(name);
        }
        
        String? savePath = await FilePicker.platform.saveFile(
          dialogTitle: 'Save incoming file',
          fileName: name,
        );

        if (savePath == null || savePath.isEmpty) {
          _log('🚫 USER CANCELLED SAVE DIALOG');
          
          // Notify UI about download failure due to user cancellation
          if (onDownloadFailed != null) {
            onDownloadFailed!('User cancelled save dialog');
          }
          
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
      _fileSessions[sessionId] = session;
      _log('📂 FILE SESSION PREPARED', {
        'sessionId': sessionId,
        'dir': session.dirPath,
        'files': session.files.length
      });
      
      // Show 0% download notification for each file at the start
      for (final fileInfo in incomingFiles) {
        _notificationService.showFileDownloadProgress(0, fileInfo.name);
        // Don't set lastNotificationTime here - let the first progress notification show immediately
        
        // Notify UI about download start
        if (onDownloadProgress != null) {
          onDownloadProgress!(fileInfo.name, 0.0);
        }
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
        
        // Always notify UI about progress updates (not throttled like notifications)
        if (onDownloadProgress != null) {
          onDownloadProgress!(incoming.name, progressInt.toDouble());
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
      
      // Notify UI about download failure due to file write error
      if (onDownloadFailed != null) {
        onDownloadFailed!('File write error: ${e.toString()}');
      }
    }
  }

  Future<void> _handleFileEnd(String sessionId, int fileIndex) async {
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
        const checksumOk = true;
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
        _notificationService.showFileDownloadComplete(f.name);
      }
      
      // Notify UI about download completion
      if (onDownloadComplete != null) {
        onDownloadComplete!();
      }

      // ACK for 'end' is sent immediately upon receiving 'end' mode to unblock sender
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


