const { electronAPI } = window;

class FileTransferService {
    constructor() {
        this.MAX_FILE_SIZE = 50 * 1024 * 1024; // 50MB limit for safety
    }

    // Helper function for timestamped logging
    _log(message, data = null) {
        const timestamp = new Date().toISOString();
        if (data) {
            console.log(`[${timestamp}] FILE_TRANSFER: ${message}`, data);
        } else {
            console.log(`[${timestamp}] FILE_TRANSFER: ${message}`);
        }
    }

    async getClipboardContent() {
        try {
            this._log('📋 GETTING CLIPBOARD CONTENT FOR FILE TRANSFER');
            
            // Check if clipboard has files
            if (window.ClipboardService && await window.ClipboardService.hasFiles()) {
                this._log('📁 CLIPBOARD CONTAINS FILES');
                
                const files = await window.ClipboardService.getFiles();
                if (files && files.length > 0) {
                    this._log('📁 PROCESSING FILES', { count: files.length });
                    
                    // For now, handle single file transfers
                    const file = files[0];
                    if (file.type === 'file') {
                        return await this._processFile(file);
                    } else {
                        this._log('⚠️ DIRECTORY TRANSFER NOT IMPLEMENTED');
                        return null;
                    }
                }
            }
            
            // Fall back to text content
            if (window.ClipboardService) {
                const textContent = await window.ClipboardService.getClipboard();
                if (textContent) {
                    this._log('📝 RETURNING TEXT CONTENT');
                    return {
                        type: 'text',
                        content: textContent
                    };
                }
            }
            
            return null;
        } catch (error) {
            this._log('❌ ERROR GETTING CLIPBOARD CONTENT', error.toString());
            return null;
        }
    }

    async _processFile(file) {
        try {
            this._log('📁 PROCESSING FILE', { name: file.name, size: file.size });
            
            // Check file size
            if (file.size > this.MAX_FILE_SIZE) {
                this._log('❌ FILE TOO LARGE', { size: file.size, limit: this.MAX_FILE_SIZE });
                throw new Error(`File too large: ${file.size} bytes (limit: ${this.MAX_FILE_SIZE} bytes)`);
            }
            
            // Read file content
            const fileContent = await electronAPI.fs.readFile(file.path);
            
            // Calculate checksum
            const checksum = electronAPI.crypto.createHash('sha256').update(fileContent).digest('hex');
            
            // Get MIME type
            const mimeType = electronAPI.mime.lookup(file.path) || 'application/octet-stream';
            
            // Encode as base64
            const base64Content = fileContent.toString('base64');
            
            this._log('✅ FILE PROCESSED', {
                name: file.name,
                size: file.size,
                mimeType: mimeType,
                checksum: checksum.substring(0, 16) + '...'
            });
            
            return {
                type: 'file',
                name: file.name,
                size: file.size,
                mimeType: mimeType,
                checksum: checksum,
                content: base64Content
            };
        } catch (error) {
            this._log('❌ ERROR PROCESSING FILE', error.toString());
            throw error;
        }
    }

    async handleReceivedFile(fileData) {
        try {
            this._log('📥 HANDLING RECEIVED FILE', {
                name: fileData.name,
                size: fileData.size,
                mimeType: fileData.mimeType
            });
            
            if (!fileData.content) {
                throw new Error('File content is missing');
            }
            
            // Decode base64 content
            const fileContent = Buffer.from(fileData.content, 'base64');
            
            // Verify checksum
            const actualChecksum = electronAPI.crypto.createHash('sha256').update(fileContent).digest('hex');
            if (actualChecksum !== fileData.checksum) {
                throw new Error('File checksum mismatch');
            }
            
            // Get downloads directory
            const downloadsDir = electronAPI.path.join(electronAPI.os.homedir(), 'Downloads');
            
            // Create unique filename if file already exists
            let outputPath = electronAPI.path.join(downloadsDir, fileData.name);
            let counter = 1;
            while (await this._fileExists(outputPath)) {
                const ext = electronAPI.path.extname(fileData.name);
                const basename = electronAPI.path.basename(fileData.name, ext);
                outputPath = electronAPI.path.join(downloadsDir, `${basename} (${counter})${ext}`);
                counter++;
            }
            
            // Write file
            await electronAPI.fs.writeFile(outputPath, fileContent);
            
            this._log('✅ FILE SAVED', { path: outputPath });
            
            // Show notification or update UI
            if (window.Notification && Notification.permission === 'granted') {
                new Notification('File Received', {
                    body: `${fileData.name} has been saved to Downloads`,
                    icon: '../assets/icon.png'
                });
            }
            
            return outputPath;
        } catch (error) {
            this._log('❌ ERROR HANDLING RECEIVED FILE', error.toString());
            throw error;
        }
    }

    async _fileExists(filePath) {
        try {
            await electronAPI.fs.access(filePath);
            return true;
        } catch {
            return false;
        }
    }

    // Format file size for display
    formatFileSize(bytes) {
        if (bytes === 0) return '0 Bytes';
        
        const k = 1024;
        const sizes = ['Bytes', 'KB', 'MB', 'GB'];
        const i = Math.floor(Math.log(bytes) / Math.log(k));
        
        return parseFloat((bytes / Math.pow(k, i)).toFixed(2)) + ' ' + sizes[i];
    }

    // Get file icon based on extension
    getFileIcon(filename) {
        const ext = electronAPI.path.extname(filename).toLowerCase();
        
        const iconMap = {
            '.txt': '📄',
            '.doc': '📝',
            '.docx': '📝',
            '.pdf': '📕',
            '.jpg': '🖼️',
            '.jpeg': '🖼️',
            '.png': '🖼️',
            '.gif': '🖼️',
            '.mp4': '🎬',
            '.mp3': '🎵',
            '.zip': '📦',
            '.rar': '📦',
            '.js': '📄',
            '.html': '📄',
            '.css': '📄',
            '.json': '📄'
        };
        
        return iconMap[ext] || '📄';
    }
}

// Create singleton instance
const fileTransferService = new FileTransferService();

// Export for use in renderer
window.FileTransferService = fileTransferService;
