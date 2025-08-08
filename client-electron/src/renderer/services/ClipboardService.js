const { electronAPI } = window;

class ClipboardService {
    constructor() {
        this.isEnabled = true;
    }

    // Helper function for timestamped logging
    _log(message, data = null) {
        const timestamp = new Date().toISOString();
        if (data) {
            console.log(`[${timestamp}] CLIPBOARD: ${message}`, data);
        } else {
            console.log(`[${timestamp}] CLIPBOARD: ${message}`);
        }
    }

    async getClipboard() {
        try {
            if (!this.isEnabled) {
                this._log('⚠️ CLIPBOARD SERVICE DISABLED');
                return null;
            }

            this._log('📋 READING CLIPBOARD');
            const content = await electronAPI.clipboard.read();
            
            if (content && content.trim()) {
                this._log('✅ CLIPBOARD CONTENT READ', { length: content.length });
                return content;
            } else {
                this._log('📋 CLIPBOARD IS EMPTY');
                return null;
            }
        } catch (error) {
            this._log('❌ ERROR READING CLIPBOARD', error.toString());
            return null;
        }
    }

    async setClipboard(content) {
        try {
            if (!this.isEnabled) {
                this._log('⚠️ CLIPBOARD SERVICE DISABLED');
                return false;
            }

            if (!content) {
                this._log('⚠️ NO CONTENT TO SET');
                return false;
            }

            this._log('📝 WRITING TO CLIPBOARD', { length: content.length });
            await electronAPI.clipboard.write(content);
            this._log('✅ CLIPBOARD CONTENT SET');
            return true;
        } catch (error) {
            this._log('❌ ERROR WRITING TO CLIPBOARD', error.toString());
            return false;
        }
    }

    async hasFiles() {
        try {
            // Check if clipboard contains text that might be file paths
            const clipboardData = await this.getClipboard();
            if (clipboardData) {
                if (await this._looksLikeFilePaths(clipboardData)) {
                    this._log('📁 DETECTED POTENTIAL FILE PATHS IN CLIPBOARD');
                    return true;
                }
            }
            
            return false;
        } catch (error) {
            this._log('❌ ERROR CHECKING FOR FILES', error.toString());
            return false;
        }
    }

    async _looksLikeFilePaths(text) {
        const lines = text.split('\n').map(e => e.trim()).filter(e => e.length > 0);
        
        this._log('🔍 ANALYZING TEXT FOR FILE PATHS', {
            lineCount: lines.length,
            lines: lines.slice(0, 3) // Show first 3 lines for debugging
        });
        
        // Check if all lines look like file paths
        if (lines.length === 0) return false;
        if (lines.length > 10) return false; // Limit to 10 files
        
        let validFileCount = 0;
        let pathLikeCount = 0;
        
        for (const line of lines) {
            // Windows: C:\path\to\file or D:\folder\file.txt
            // macOS: /Users/username/file.txt or /Applications/app.app
            // Also handle quotes around paths: "C:\Program Files\file.txt"
            const cleanPath = line.replace(/"/g, '').trim();
            
            // Check if it looks like a path
            let looksLikePath = false;
            if (electronAPI.os.platform() === 'win32') {
                // Windows paths: C:\, D:\, \\server\share, etc.
                looksLikePath = /^([a-zA-Z]:\\|\\\\).*/.test(cleanPath);
            } else {
                // Unix-like paths: /path/to/file
                looksLikePath = /^\/.*/.test(cleanPath);
            }
            
            if (looksLikePath) {
                pathLikeCount++;
                
                // Check if file exists
                try {
                    const stats = await electronAPI.fs.stat(cleanPath);
                    if (stats) {
                        validFileCount++;
                        this._log('✅ VALID FILE FOUND', cleanPath);
                    }
                } catch (e) {
                    this._log('❌ FILE DOES NOT EXIST', cleanPath);
                }
            }
        }
        
        this._log('📊 FILE PATH ANALYSIS RESULTS', {
            totalLines: lines.length,
            pathLikeCount: pathLikeCount,
            validFileCount: validFileCount
        });
        
        // Consider it file paths if most lines look like paths and at least some files exist
        const pathLikeRatio = pathLikeCount / lines.length;
        const validFileRatio = validFileCount / lines.length;
        
        return pathLikeRatio >= 0.8 && validFileRatio >= 0.5;
    }

    async getFiles() {
        try {
            const clipboardData = await this.getClipboard();
            if (!clipboardData || !(await this._looksLikeFilePaths(clipboardData))) {
                return [];
            }

            const lines = clipboardData.split('\n').map(e => e.trim()).filter(e => e.length > 0);
            const files = [];

            for (const line of lines) {
                const cleanPath = line.replace(/"/g, '').trim();
                
                try {
                    const stats = await electronAPI.fs.stat(cleanPath);
                    if (stats.isFile()) {
                        files.push({
                            path: cleanPath,
                            name: electronAPI.path.basename(cleanPath),
                            size: stats.size,
                            type: 'file'
                        });
                    } else if (stats.isDirectory()) {
                        files.push({
                            path: cleanPath,
                            name: electronAPI.path.basename(cleanPath),
                            size: 0,
                            type: 'directory'
                        });
                    }
                } catch (error) {
                    this._log('❌ ERROR ACCESSING FILE', { path: cleanPath, error: error.message });
                }
            }

            this._log('📁 EXTRACTED FILES FROM CLIPBOARD', { count: files.length });
            return files;
        } catch (error) {
            this._log('❌ ERROR GETTING FILES', error.toString());
            return [];
        }
    }

    setEnabled(enabled) {
        this.isEnabled = enabled;
        this._log(`📋 CLIPBOARD SERVICE ${enabled ? 'ENABLED' : 'DISABLED'}`);
    }

    // Truncate long text for display
    truncateText(text, maxLength = 200) {
        if (!text || text.length <= maxLength) {
            return text;
        }
        return text.substring(0, maxLength) + '...';
    }
}

// Create singleton instance
const clipboardService = new ClipboardService();

// Export for use in renderer
window.ClipboardService = clipboardService;
