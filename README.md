# Filen CLI (Dart Edition)

An unofficial Command Line Interface for [Filen.io](https://filen.io), written in Dart.

This CLI provides comprehensive file management capabilities with batch operations, resume support, recursive uploads/downloads, conflict handling, integrity verification, WebDAV server, and more - all directly from your terminal.

⚠️ **Note:** This is early work in progress.

## ✨ Features

### Core Capabilities
* **🔐 Secure Authentication:** Login with email/password and optional 2FA support
* **📂 Path Resolution:** Use standard file paths (e.g., `/Documents/Report.pdf`) instead of raw UUIDs
* **💾 Intelligent Caching:** 10-minute cache for folder/file listings with automatic invalidation on mutations
* **🔄 Batch Operations:** Resume interrupted uploads/downloads with chunk-level state persistence
* **⚡ Retry Logic:** Automatic retry with exponential backoff for network and server errors (5xx)
* **✅ Integrity Verification:** SHA-512 hash verification without downloading files
* **🌐 WebDAV Server:** Mount your Filen drive as a local network drive

### File Operations
* **List (`ls`)**: Browse folders with detailed or compact views, full UUID display
* **Upload (`up`)**: Chunked uploads with resume from interrupted chunks, progress tracking
* **Download (`dl`, `download-path`)**: Single file or recursive folder downloads with resume
* **Move (`mv`)**: Move files/folders between directories or rename them
* **Copy (`cp`)**: Copy files using download-upload workflow
* **Trash (`rm`, `trash-path`)**: Move items to trash with confirmation
* **Delete (`delete-path`)**: Permanently delete items (requires confirmation)
* **Mkdir (`mkdir`)**: Create directories recursively with timestamp preservation
* **Rename (`rename-path`)**: Rename files or folders in place
* **Verify (`verify`)**: Verify uploaded files using SHA-512 metadata comparison

### Advanced Features
* **🔍 Search (`search`)**: Server-side search across your entire drive
* **🔎 Find (`find`)**: Recursively find files matching glob patterns with depth control
* **🌳 Tree (`tree`)**: Visual folder hierarchy with configurable depth
* **♻️ Trash Management**: List, restore by UUID or name, and permanently delete trashed items
* **📊 Detailed Listings**: Show modification times, full UUIDs, file sizes with `-d` flag
* **🎯 Pattern Matching**: Include/exclude files using glob patterns
* **📦 Chunk-Level Resume**: Resume uploads from exact chunk where interrupted

### WebDAV Server Features
* **🖥️ Virtual Filesystem:** Mount Filen as local drive (Windows/macOS/Linux)
* **📁 Full Read/Write Access:** Browse, upload, download, rename, delete via file explorer
* **🔒 Authentication:** Basic auth with configurable credentials
* **⚙️ Background Mode:** Run server as daemon process
* **🔄 Auto-sync:** Changes made via WebDAV instantly sync to Filen

### Smart Conflict Handling
* **`--on-conflict skip`**: Skip existing files (default, safe)
* **`--on-conflict overwrite`**: Always overwrite existing files
* **`--on-conflict newer`**: Only transfer if remote/local file is newer (requires `-p`)

### Upload Resume System
* **Automatic State Saving**: Progress saved every 10 chunks or 5 seconds
* **UUID Persistence**: Same file UUID and upload key across resume sessions
* **Hash Continuation**: SHA-512 hash calculated correctly across interrupted sessions
* **Error Recovery**: Graceful handling of network failures with saved state

## 📋 Prerequisites

* **Dart SDK:** Version 2.12 or higher - [Get Dart](https://dart.dev/get-dart)
* **For WebDAV (optional):**
  - macOS: Built-in WebDAV client
  - Windows: Built-in WebDAV client (or use WinSCP, Cyberduck)
  - Linux: `davfs2` package (`sudo apt install davfs2`)

## 🚀 Installation

1. **Clone the repository:**
   ```bash
   git clone <repository-url>
   cd filen-dart
   ```

2. **Install dependencies:**
   ```bash
   dart pub get
   ```

3. **(Optional) Compile to standalone binary:**
   ```bash
   dart compile exe filen.dart -o filen
   # Now you can run: ./filen <command>
   ```

## 📖 Usage

### Running from Source
```bash
dart filen.dart <command> [options] [arguments]
```

### Running Compiled Binary
```bash
./filen <command> [options] [arguments]
```

## 🎯 Commands

### Authentication
| Command | Description |
|---------|-------------|
| `login` | Authenticate with email/password (supports 2FA) |
| `logout` | Clear stored credentials |
| `whoami` | Show current user information |

### File Management
| Command | Arguments | Description |
|---------|-----------|-------------|
| `ls [path]` | Optional path (default: `/`) | List folder contents |
| `mkdir <path>` | Folder path to create | Create folder(s) recursively |
| `up <sources...>` | Local files/folders + optional target | Upload files or directories |
| `dl <uuid-or-path>` | File UUID or path | Download a single file |
| `download-path <path>` | Remote file or folder path | Download file/folder (supports recursion) |
| `mv <source> <dest>` | Source and destination paths | Move or rename items |
| `cp <source> <dest>` | Source and destination paths | Copy files |
| `rm <path>` | Path to trash | Move to trash |
| `rename <path> <new_name>` | Path and new name | Rename file or folder |
| `verify <uuid-or-path> <local-file>` | Remote UUID/path + local file | Verify upload integrity |

### Trash Operations
| Command | Arguments | Description |
|---------|-----------|-------------|
| `list-trash` | None | Show all trashed items with UUIDs |
| `restore-uuid <uuid>` | Item UUID + optional `-t <dest>` | Restore item by UUID |
| `restore-path <name>` | Item name + optional `-t <dest>` | Restore item by name |
| `delete-path <path>` | Path to delete | Permanently delete (requires confirmation) |

### Search & Discovery
| Command | Arguments | Description |
|---------|-----------|-------------|
| `search <query>` | Search term | Search files across entire drive |
| `find <path> <pattern>` | Start path + glob pattern | Recursively find matching files |
| `tree [path]` | Optional start path | Show folder structure as tree |
| `resolve <path>` | Path to resolve | Debug path resolution (shows UUID) |

### WebDAV Server
| Command | Arguments | Description |
|---------|-----------|-------------|
| `webdav-start` | Optional `--port` and `-b` | Start WebDAV server |
| `webdav-stop` | None | Stop background WebDAV server |
| `webdav-status` | None | Check if server is running |
| `webdav-test` | None | Test connection to server |
| `webdav-mount` | None | Show OS-specific mount instructions |
| `webdav-config` | None | Show server configuration |
| `mount` | Optional `--port` | Start WebDAV in foreground (deprecated, use webdav-start) |

### System
| Command | Description |
|---------|-------------|
| `config` | Show configuration paths and API endpoints |
| `help` | Display comprehensive help message |

## 🎛️ Global Options

| Flag | Short | Description |
|------|-------|-------------|
| `--verbose` | `-v` | Enable debug output (shows crypto operations, API calls) |
| `--force` | `-f` | Skip confirmations for destructive operations |
| `--uuids` | | Show full UUIDs in listings (default: truncated) |
| `--detailed` | `-d` | Show detailed file info (includes full UUIDs, timestamps) |
| `--recursive` | `-r` | Recursive operations for directories |
| `--preserve-timestamps` | `-p` | Preserve file modification times |
| `--target <path>` | `-t` | Specify destination path |
| `--on-conflict <mode>` | | Conflict resolution: `skip`, `overwrite`, `newer` |
| `--include <pattern>` | | Include only files matching pattern (can use multiple) |
| `--exclude <pattern>` | | Exclude files matching pattern (can use multiple) |
| `--depth <n>` | `-l` | Max depth for tree command (default: 3) |
| `--maxdepth <n>` | | Max depth for find command (default: -1 = infinite) |
| `--background` | `-b` | Run WebDAV server in background |
| `--port <n>` | | WebDAV server port (default: 8080) |
| `--webdav-debug` | | Enable WebDAV debug logging |

## 💡 Examples

### Basic Operations

**Login with 2FA:**
```bash
dart filen.dart login
# Prompts for email, password, and 2FA code if enabled
```

**List files with details and full UUIDs:**
```bash
dart filen.dart ls /Documents -d
```

**Show folder tree:**
```bash
dart filen.dart tree /Projects -l 2
```

**Check current user:**
```bash
dart filen.dart whoami
```

### Upload Examples

**Upload single file:**
```bash
dart filen.dart up report.pdf /Documents/Reports
```

**Upload directory recursively with timestamp preservation:**
```bash
dart filen.dart up ~/Projects/MyApp /Backups/MyApp -r -p
```

**Upload with progress and get UUID for verification:**
```bash
dart filen.dart up largefile.zip /Backups
# Output shows:
#   📤 Uploading: largefile.zip (173.1 MB)
#        Uploading... 174/174 chunks (100.0%)
#      ✅ Upload complete
#      🆔 UUID:    abc123-def456-ghi789-jkl012-mno345
#      📊 SHA-512: a1b2c3d4e5f6...
```

**Upload only PDF files, excluding temps:**
```bash
dart filen.dart up ~/Documents/* /Backup -r \
  --include "*.pdf" --exclude "*_temp*"
```

**Upload with conflict handling:**
```bash
# Skip existing files (default)
dart filen.dart up photos/ /Photos -r --on-conflict skip

# Overwrite all existing files
dart filen.dart up photos/ /Photos -r --on-conflict overwrite

# Only upload if local file is newer (requires -p)
dart filen.dart up photos/ /Photos -r --on-conflict newer -p
```

**Resume interrupted upload:**
```bash
# Start upload
dart filen.dart up hugefile.tar.gz /Backups
# (Press Ctrl+C to interrupt)

# Resume from exact chunk where it stopped
dart filen.dart up hugefile.tar.gz /Backups
# Output shows:
#   🔄 Resuming batch...
#   📤 Resuming: hugefile.tar.gz from chunk 12 (173.1 MB)
#        Uploading... 12/174 chunks (6.9%)
```

### Verification Examples

**Verify by path (easiest method):**
```bash
dart filen.dart verify /Documents/report.pdf report.pdf
```

**Verify by UUID (after upload):**
```bash
dart filen.dart verify abc123-def456-ghi789-jkl012-mno345 report.pdf
```

**Output:**
```
🔍 Verifying upload of: report.pdf
   Remote UUID: abc123-def456-ghi789-jkl012-mno345

   📊 Hashing local file...
   📋 Fetching metadata from server...
   ✅ Verification successful - hashes match!
```

### Download Examples

**Download by path:**
```bash
dart filen.dart dl /Documents/Report.pdf
```

**Download by UUID:**
```bash
dart filen.dart dl a8a8a36f-xxxx-xxxx-xxxx-xxxxxxxxxxxx
```

**Download folder recursively with timestamps:**
```bash
dart filen.dart download-path /Projects/MyApp -r -p
```

**Download only newer files:**
```bash
dart filen.dart download-path /Photos -r \
  --on-conflict newer -p -t ~/Downloads/Photos
```

**Resume interrupted download:**
```bash
# If download was interrupted, run the same command again
dart filen.dart download-path /LargeBackup -r
# Skips completed files, resumes from interruption point
```

### Search & Find

**Search across entire drive:**
```bash
dart filen.dart search "invoice"
```

**Find all PDFs in Documents:**
```bash
dart filen.dart find /Documents "*.pdf"
```

**Find images with depth limit:**
```bash
dart filen.dart find / "*.jpg" --maxdepth 3
```

**Find with verbose output:**
```bash
dart filen.dart find / "*.mp3" --maxdepth 2 -v
```

### Move & Rename

**Rename a file:**
```bash
dart filen.dart rename /Photos/IMG_001.jpg vacation_start.jpg
```

**Move to different folder:**
```bash
dart filen.dart mv /Photos/vacation_start.jpg /Photos/2024/
```

**Move and rename simultaneously:**
```bash
dart filen.dart mv /Photos/old_name.jpg /Archive/archived_photo.jpg
```

### Trash Operations

**Move to trash:**
```bash
dart filen.dart rm /OldFiles/temp.txt
```

**List trash with full UUIDs:**
```bash
dart filen.dart list-trash --uuids
```

**Restore from trash by name:**
```bash
dart filen.dart restore-path "important.doc" -t /Recovered
```

**Restore from trash by UUID:**
```bash
dart filen.dart restore-uuid abc123-def456-... -t /Documents
```

**Permanently delete (with confirmation):**
```bash
dart filen.dart delete-path /OldFiles/junk.txt
# Prompts: ⚠️ WARNING: This will PERMANENTLY delete...
```

**Force delete (skip confirmation):**
```bash
dart filen.dart delete-path /OldFiles/junk.txt -f
```

### WebDAV Server Examples

**Start WebDAV server in foreground:**
```bash
dart filen.dart webdav-start
# Server runs until Ctrl+C
```

**Start WebDAV server in background:**
```bash
dart filen.dart webdav-start -b
# Output:
#   ✅ WebDAV server started in background (PID: 12345)
#      URL: http://localhost:8080/
#      User: filen
#      Pass: filen-webdav
```

**Start on custom port:**
```bash
dart filen.dart webdav-start -b --port 9090
```

**Check server status:**
```bash
dart filen.dart webdav-status
# Output:
#   ✅ WebDAV server is running in background.
#      PID: 12345
#      URL: http://localhost:8080/
```

**Test server connection:**
```bash
dart filen.dart webdav-test
# Output:
#   ✅ Connection successful! (Received 207 Multi-Status)
```

**Show mount instructions:**
```bash
dart filen.dart webdav-mount
```

**Stop background server:**
```bash
dart filen.dart webdav-stop
```

### WebDAV Mounting

**macOS (Finder):**
```bash
# 1. Start server
dart filen.dart webdav-start -b

# 2. In Finder, press Cmd+K
# 3. Enter: http://localhost:8080
# 4. Username: filen
# 5. Password: filen-webdav
```

**Windows (File Explorer):**
```bash
# 1. Start server
dart filen.dart webdav-start -b

# 2. Open File Explorer
# 3. Right-click "This PC" → "Map network drive"
# 4. Enter: http://localhost:8080
# 5. Check "Connect using different credentials"
# 6. Username: filen
# 7. Password: filen-webdav
```

**Linux (davfs2):**
```bash
# 1. Install davfs2
sudo apt install davfs2

# 2. Start server
dart filen.dart webdav-start -b

# 3. Mount
sudo mkdir -p /mnt/filen
sudo mount -t davfs http://localhost:8080 /mnt/filen
# Enter username: filen
# Enter password: filen-webdav

# 4. Access your files
cd /mnt/filen
ls -la
```

### Advanced Workflows

**Large file upload with verification:**
```bash
# Upload large file
dart filen.dart up movie.mp4 /Videos

# Output shows UUID, copy it, then verify
dart filen.dart verify /Videos/movie.mp4 movie.mp4
```

**Backup with resume support:**
```bash
# Start backup
dart filen.dart up ~/Documents /Backup/Documents -r -p

# If interrupted by network failure, resume with same command
dart filen.dart up ~/Documents /Backup/Documents -r -p
# Completed files are skipped, interrupted file resumes from last chunk
```

**Selective sync with patterns:**
```bash
# Upload only source code, exclude builds
dart filen.dart up ~/Projects/MyApp /Code/MyApp -r \
  --include "*.dart" --include "*.yaml" \
  --exclude "build/*" --exclude ".dart_tool/*"
```

**Compare and sync only newer files:**
```bash
# Upload only files newer than remote
dart filen.dart up ~/Sync /Cloud/Sync -r -p --on-conflict newer

# Download only files newer than local
dart filen.dart download-path /Cloud/Sync -r -p --on-conflict newer
```

**WebDAV + CLI hybrid workflow:**
```bash
# 1. Start WebDAV for browsing
dart filen.dart webdav-start -b

# 2. Browse via file explorer (mounted at http://localhost:8080)
# 3. Use CLI for bulk operations
dart filen.dart up ~/LargeBackup /Backups -r -p

# 4. Verify critical files
dart filen.dart verify /Backups/important.zip ~/LargeBackup/important.zip

# 5. Stop WebDAV when done
dart filen.dart webdav-stop
```

**Debug path resolution:**
```bash
dart filen.dart resolve /Documents/SubFolder/file.pdf
# Shows full metadata and UUID
```

## 🗂️ Configuration

### Storage Locations

**Credentials:**
- macOS/Linux: `~/.filen-cli/credentials.json`
- Windows: `%USERPROFILE%\.filen-cli\credentials.json`

**Batch State Files:**
- macOS/Linux: `~/.filen-cli/batch_states/`
- Windows: `%USERPROFILE%\.filen-cli\batch_states\`

**WebDAV PID File:**
- macOS/Linux: `~/.filen-cli/webdav.pid`
- Windows: `%USERPROFILE%\.filen-cli\webdav.pid`

State files enable chunk-level resume functionality. They contain:
- File UUIDs and upload keys
- Last successfully uploaded chunk number
- Operation status (pending, uploading, interrupted, completed)
- Automatically deleted when operations complete successfully

### View Configuration

```bash
dart filen.dart config
```

Shows:
- Config directory path
- Credentials file location
- Batch state directory
- WebDAV PID file location
- API endpoints (gateway, ingest, egest)

### WebDAV Configuration

**Default settings:**
- Host: `localhost`
- Port: `8080`
- Username: `filen`
- Password: `filen-webdav`
- Protocol: HTTP (no SSL in current version)

View WebDAV config:
```bash
dart filen.dart webdav-config
```

## 🔧 Troubleshooting

### Resume Interrupted Operations

If an upload or download is interrupted (network failure, Ctrl+C, crash):

1. **Simply run the same command again**
2. The CLI will:
   - Load the previous batch state
   - Skip already completed files
   - Resume interrupted file from last successful chunk
   - Continue uploading remaining files

Example:
```bash
# Upload interrupted at chunk 50/200
dart filen.dart up bigfile.zip /Backups
^C  # Interrupted

# Resume - continues from chunk 51
dart filen.dart up bigfile.zip /Backups
# Output: 📤 Resuming: bigfile.zip from chunk 51 (...)
```

### WebDAV Troubleshooting

**Server won't start:**
```bash
# Check if already running
dart filen.dart webdav-status

# If stuck, stop it
dart filen.dart webdav-stop

# Clear stale PID file if needed
rm ~/.filen-cli/webdav.pid

# Try again
dart filen.dart webdav-start -b
```

**Can't connect to server:**
```bash
# Test connection
dart filen.dart webdav-test

# Check if server is running
dart filen.dart webdav-status

# Try different port if 8080 is busy
dart filen.dart webdav-start -b --port 9090
```

**Port already in use:**
```bash
# Use custom port
dart filen.dart webdav-start -b --port 9090
```

**Authentication fails on mount:**
- Username: `filen`
- Password: `filen-webdav`
- Make sure to enter exactly as shown (case-sensitive)

### Clear Batch States

If you want to force a fresh start (ignoring previous state):

```bash
# Remove all batch state files
rm -rf ~/.filen-cli/batch_states/

# Or remove specific batch
rm ~/.filen-cli/batch_states/batch_state_<batch-id>.json
```

### Verify Upload Integrity

After uploading important files, verify they arrived correctly:

```bash
# By path (easiest)
dart filen.dart verify /path/to/remote/file.pdf local/file.pdf

# By UUID (if you saved it from upload output)
dart filen.dart verify abc123-def456-... local/file.pdf
```

This compares SHA-512 hashes without downloading the file.

### Debug Mode

Enable verbose output to troubleshoot issues:

```bash
dart filen.dart up file.pdf /Documents -v
```

Shows:
- API requests and responses
- Crypto operations (encryption, hashing)
- Cache operations
- Chunk upload progress
- State save operations
- Error stack traces

### Common Issues

**"Not logged in" error:**
```bash
dart filen.dart login
```

**"Path not found" error:**
```bash
# Verify path exists
dart filen.dart ls /Documents

# Or resolve to see details
dart filen.dart resolve /Documents/file.pdf
```

**Stale cache issues:**
```bash
# Cache auto-invalidates, but you can force refresh by waiting 10 minutes
# Or trigger invalidation by modifying the folder (upload/delete/move)
```

**Upload shows wrong progress:**
```bash
# This happens if resuming - it re-hashes previous chunks first
# Progress bar starts from resume point, not from 0%
```

**WebDAV server process orphaned:**
```bash
# Find and kill manually
ps aux | grep filen.dart
kill <PID>

# Clear PID file
rm ~/.filen-cli/webdav.pid
```

## 🏗️ Architecture

### Key Components

- **FilenCLI**: Command-line interface and argument parsing
- **FilenClient**: API client with caching, retry logic, and crypto operations
- **ConfigService**: Credential and batch state management
- **DigestSink**: Helper for SHA-512 hash calculation
- **InternxtFileSystem**: Virtual filesystem implementation for WebDAV
- **ShelfDAV**: WebDAV protocol handler

### Technical Features

- **Caching**: 10-minute TTL for folder/file listings, invalidated on mutations
- **Retry Logic**: Exponential backoff (1s, 2s, 4s) for network/5xx errors
- **Conflict Detection**: Handles 409 errors with automatic re-fetch and delay
- **Batch Processing**: State-based resumable operations with chunk-level granularity
- **Hash Calculation**: Continuous SHA-512 hashing across upload sessions
- **Parent Cache Invalidation**: Automatic cache clearing on file/folder mutations
- **WebDAV Virtual FS**: FUSE-like filesystem layer for WebDAV access

### Upload Process

1. **File chunked** into 1MB pieces
2. **Each chunk encrypted** with random file key
3. **SHA-512 hash** calculated as chunks upload
4. **Progress saved** every 10 chunks or 5 seconds
5. **On interruption**: UUID, upload key, and last chunk saved
6. **On resume**: Same UUID/key used, continue from next chunk
7. **Hash recalculated** from beginning (fast read-only pass)
8. **Upload completed**: Hash stored in encrypted metadata

### WebDAV Architecture

1. **Virtual Filesystem**: Maps Filen paths to WebDAV resources
2. **On-Demand Loading**: Folders/files fetched as accessed
3. **Write-Through Caching**: Changes immediately sync to Filen
4. **Authentication**: Basic auth with hardcoded credentials
5. **Locking Support**: WebDAV locking for concurrent access

## 🔐 Security

- **End-to-End Encryption**: All files encrypted client-side before upload
- **Zero-Knowledge**: Master keys never leave your device
- **Secure Storage**: Credentials stored in user home directory (chmod 600 recommended)
- **2FA Support**: Optional two-factor authentication
- **No Password Storage**: Only encrypted credentials stored
- **WebDAV Security**: 
  - HTTP only (no SSL in current version) - use only on trusted networks
  - Basic authentication (credentials sent in headers)
  - Recommended for localhost access only

## 🚧 Known Limitations

### WebDAV
- **No SSL/TLS**: HTTP only, not recommended for remote access
- **Concurrent Access**: Limited locking support
- **Hardcoded Credentials**: Username/password cannot be customized (yet)

### General
- **File Size**: Very large files may encounter memory issues
- **Windows WebDAV**: May require registry tweaks for large files

## 📄 License

This project is licensed under the **GNU Affero General Public License v3.0 (AGPL-3.0)**.

See the [LICENSE](LICENSE) file for details.

## ⚠️ Disclaimer

This is an **unofficial** tool and is **not affiliated** with Filen.io.

- Use at your own risk
- Always maintain backups of critical data
- Test operations on non-critical files first
- Verify important uploads using the `verify` command
- WebDAV server is experimental - use with caution
- We assume no liability for data loss or corruption
