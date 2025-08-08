class WebRTCService {
    constructor() {
        this.peerConnection = null;
        this.dataChannel = null;
        this.peerId = null;
        this.isInitialized = false;
        this.pendingClipboardContent = null;
        this.isResetting = false;
        this.fileTransferService = null;
        
        // Queue for ICE candidates received before remote description is set
        this.pendingCandidates = [];
        this.remoteDescriptionSet = false;
        
        // Callback to send signals back to socket service
        this.onSignalGenerated = null;
    }

    // Helper function for timestamped logging
    _log(message, data = null) {
        const timestamp = new Date().toISOString();
        if (data) {
            console.log(`[${timestamp}] WEBRTC: ${message}`, data);
        } else {
            console.log(`[${timestamp}] WEBRTC: ${message}`);
        }
    }

    async init() {
        if (this.isInitialized) {
            this._log('⚠️ ALREADY INITIALIZED, SKIPPING');
            return;
        }
        
        this._log('🚀 INITIALIZING WEBRTC SERVICE');
        
        try {
            const configuration = {
                iceServers: [
                    { urls: 'stun:stun.l.google.com:19302' },
                ]
            };
            
            // Create peer connection
            this.peerConnection = new RTCPeerConnection(configuration);
            this.isInitialized = true;

            this.peerConnection.onicecandidate = (event) => {
                if (event.candidate) {
                    this._log('🧊 ICE CANDIDATE GENERATED');
                    if (this.peerId && this.onSignalGenerated) {
                        this.onSignalGenerated(this.peerId, {
                            type: 'candidate',
                            candidate: event.candidate.candidate,
                            sdpMid: event.candidate.sdpMid,
                            sdpMLineIndex: event.candidate.sdpMLineIndex,
                        });
                    }
                }
            };

            this.peerConnection.onconnectionstatechange = () => {
                this._log('🔗 CONNECTION STATE CHANGED', this.peerConnection.connectionState);
            };

            this.peerConnection.ondatachannel = (event) => {
                this._log('📡 DATA CHANNEL RECEIVED');
                this._setupDataChannel(event.channel);
            };
            
            this._log('✅ WEBRTC SERVICE INITIALIZED');
        } catch (e) {
            this._log('❌ ERROR INITIALIZING WEBRTC SERVICE', e.toString());
            this.isInitialized = false;
            this.peerConnection = null;
            throw e;
        }
    }

    _setupDataChannel(channel) {
        this.dataChannel = channel;
        this._log('📡 SETTING UP DATA CHANNEL', {
            label: channel.label,
            readyState: channel.readyState,
            hasPendingContent: this.pendingClipboardContent !== null,
            role: this.pendingClipboardContent !== null ? 'SENDER' : 'RECEIVER'
        });
        
        // Check if channel is already open
        if (channel.readyState === 'open') {
            this._log('📡 DATA CHANNEL IS ALREADY OPEN DURING SETUP');
            this._handleDataChannelOpen();
        }
        
        channel.onopen = () => {
            this._log('📡 DATA CHANNEL OPENED');
            this._handleDataChannelOpen();
        };
        
        channel.onmessage = (event) => {
            this._log('📨 DATA CHANNEL MESSAGE RECEIVED');
            this._handleDataChannelMessage(event.data);
        };
        
        channel.onerror = (error) => {
            this._log('❌ DATA CHANNEL ERROR', error);
        };
        
        channel.onclose = () => {
            this._log('📡 DATA CHANNEL CLOSED');
        };
    }

    _handleDataChannelOpen() {
        if (this.pendingClipboardContent !== null) {
            this._log('📤 SENDING PENDING CLIPBOARD CONTENT');
            this._sendClipboardContent(this.pendingClipboardContent);
            this.pendingClipboardContent = null;
        }
    }

    async _handleDataChannelMessage(data) {
        try {
            this._log('📨 PROCESSING RECEIVED DATA');
            
            // Try to parse as JSON first (for metadata)
            let parsedData;
            try {
                parsedData = JSON.parse(data);
            } catch (e) {
                // If not JSON, treat as plain text
                parsedData = { type: 'text', content: data };
            }
            
            if (parsedData.type === 'text') {
                this._log('📝 RECEIVED TEXT CONTENT');
                await this._setClipboardContent(parsedData.content);
            } else if (parsedData.type === 'file') {
                this._log('📁 RECEIVED FILE METADATA');
                if (this.fileTransferService) {
                    await this.fileTransferService.handleReceivedFile(parsedData);
                }
            } else {
                this._log('❓ RECEIVED UNKNOWN DATA TYPE', parsedData.type);
            }
        } catch (error) {
            this._log('❌ ERROR PROCESSING RECEIVED DATA', error.toString());
        }
    }

    async _setClipboardContent(content) {
        try {
            if (window.ClipboardService) {
                await window.ClipboardService.setClipboard(content);
                this._log('✅ CLIPBOARD CONTENT SET');
            } else {
                // Fallback to basic clipboard API
                await navigator.clipboard.writeText(content);
                this._log('✅ CLIPBOARD CONTENT SET (FALLBACK)');
            }
        } catch (error) {
            this._log('❌ ERROR SETTING CLIPBOARD', error.toString());
        }
    }

    _sendClipboardContent(content) {
        if (this.dataChannel && this.dataChannel.readyState === 'open') {
            this._log('📤 SENDING CLIPBOARD CONTENT');
            const message = JSON.stringify({
                type: 'text',
                content: content,
                timestamp: Date.now()
            });
            this.dataChannel.send(message);
        } else {
            this._log('❌ CANNOT SEND - DATA CHANNEL NOT READY');
        }
    }

    async createOffer(clipboardContent) {
        if (!this.isInitialized) {
            this._log('❌ WEBRTC NOT INITIALIZED');
            return;
        }

        try {
            this._log('🎯 CREATING OFFER');
            this.pendingClipboardContent = clipboardContent;
            
            // Create data channel
            this.dataChannel = this.peerConnection.createDataChannel('clipboard', {
                ordered: true
            });
            this._setupDataChannel(this.dataChannel);
            
            // Create offer
            const offer = await this.peerConnection.createOffer();
            await this.peerConnection.setLocalDescription(offer);
            
            this._log('📤 OFFER CREATED AND SET AS LOCAL DESCRIPTION');
            
            // The onicecandidate event will handle sending the offer and ICE candidates
        } catch (error) {
            this._log('❌ ERROR CREATING OFFER', error.toString());
        }
    }

    async handleSignal(from, signal) {
        this._log('📡 HANDLING SIGNAL', { from: from.substring(0, 8) + '...', type: signal.type });
        this.peerId = from;
        
        try {
            if (signal.type === 'offer') {
                this._log('📨 PROCESSING OFFER');
                await this.peerConnection.setRemoteDescription(new RTCSessionDescription(signal));
                this.remoteDescriptionSet = true;
                
                // Process any pending ICE candidates
                await this._processPendingCandidates();
                
                // Create answer
                const answer = await this.peerConnection.createAnswer();
                await this.peerConnection.setLocalDescription(answer);
                
                if (this.onSignalGenerated) {
                    this.onSignalGenerated(from, answer);
                }
            } else if (signal.type === 'answer') {
                this._log('📨 PROCESSING ANSWER');
                await this.peerConnection.setRemoteDescription(new RTCSessionDescription(signal));
                this.remoteDescriptionSet = true;
                
                // Process any pending ICE candidates
                await this._processPendingCandidates();
            } else if (signal.type === 'candidate') {
                this._log('🧊 PROCESSING ICE CANDIDATE');
                const candidate = new RTCIceCandidate({
                    candidate: signal.candidate,
                    sdpMid: signal.sdpMid,
                    sdpMLineIndex: signal.sdpMLineIndex
                });
                
                if (this.remoteDescriptionSet) {
                    await this.peerConnection.addIceCandidate(candidate);
                } else {
                    this._log('⏳ QUEUING ICE CANDIDATE (REMOTE DESCRIPTION NOT SET)');
                    this.pendingCandidates.push(candidate);
                }
            }
        } catch (error) {
            this._log('❌ ERROR HANDLING SIGNAL', error.toString());
        }
    }

    async _processPendingCandidates() {
        this._log('🧊 PROCESSING PENDING ICE CANDIDATES', { count: this.pendingCandidates.length });
        for (const candidate of this.pendingCandidates) {
            try {
                await this.peerConnection.addIceCandidate(candidate);
            } catch (error) {
                this._log('❌ ERROR ADDING PENDING ICE CANDIDATE', error.toString());
            }
        }
        this.pendingCandidates = [];
    }

    async handleShareReady(from) {
        this._log('🎯 HANDLING SHARE READY FROM', from.substring(0, 8) + '...');
        this.peerId = from;
        
        // Get current clipboard content and create offer
        if (window.ClipboardService) {
            const clipboardContent = await window.ClipboardService.getClipboard();
            if (clipboardContent) {
                await this.createOffer(clipboardContent);
            }
        }
    }

    async handleRequestShare(from) {
        this._log('📋 HANDLING REQUEST SHARE FROM', from.substring(0, 8) + '...');
        this.peerId = from;
        // Wait for the requesting peer to create an offer
    }

    reset() {
        if (this.isResetting) return;
        this.isResetting = true;
        
        this._log('🔄 RESETTING WEBRTC CONNECTION');
        
        try {
            if (this.dataChannel) {
                this.dataChannel.close();
                this.dataChannel = null;
            }
            
            if (this.peerConnection) {
                this.peerConnection.close();
                this.peerConnection = null;
            }
            
            this.peerId = null;
            this.pendingClipboardContent = null;
            this.pendingCandidates = [];
            this.remoteDescriptionSet = false;
            this.isInitialized = false;
            
            // Reinitialize
            this.init();
        } catch (error) {
            this._log('❌ ERROR DURING RESET', error.toString());
        } finally {
            this.isResetting = false;
        }
    }
}

// Export for use in renderer
window.WebRTCService = WebRTCService;
