# Filen CLI (Enhanced Dart Edition)

An, unofficial Command Line Interface for [Filen.io](https://filen.io), written in Dart.

This CLI provides file management capabilities with batch operations, resume support, recursive uploads/downloads, conflict handling, and more - all directly from your terminal.

Beware that this is early work in progress.

## ✨ Features

### Core Capabilities
* **🔐 Secure Authentication:** Login with email/password and optional 2FA support
* **📂 Path Resolution:** Use standard file paths (e.g., `/Documents/Report.pdf`) instead of raw UUIDs
* **💾 Caching System:** 10-minute cache for folder/file listings with automatic invalidation
* **🔄 Batch Operations:** Resume interrupted uploads/downloads with state persistence
* **⚡ Retry Logic:** Automatic retry with exponential backoff for network and server errors

### File Operations
* **List (`ls`)**: Browse folders with detailed or compact views
* **Upload (`up`)**: Recursive uploads with pattern matching and conflict handling
* **Download (`dl`, `download-path`)**: Single file or recursive folder downloads
* **Move (`mv`)**: Move files/folders or rename them
* **Copy (`cp`)**: Copy files (download-upload workflow)
* **Trash (`rm`, `trash-path`)**: Move items to trash
* **Delete (`delete-path`)**: Permanently delete items
* **Mkdir (`mkdir`)**: Create directories recursively
* **Rename (`rename-path`)**: Rename files or folders

### Advanced Features
* **🔍 Search (`search`)**: Search files across your entire drive
* **🔎 Find (`find`)**: Recursively find files matching glob patterns
* **🌳 Tree (`tree`)**: Visual folder hierarchy with configurable depth
* **♻️ Trash Management**: List, restore, and permanently delete trashed items
* **📊 Detailed Listings**: Show modification times, full UUIDs, and more
* **⏱️ Timestamp Preservation**: Maintain file modification times on upload/download

### Smart Conflict Handling
* **`--on-conflict skip`**: Skip existing files (default)
* **`--on-conflict overwrite`**: Always overwrite existing files
* **`--on-conflict newer`**: Only download/upload if remote/local file is newer

### Pattern Matching
* **`--include`**: Only process files matching patterns (e.g., `*.pdf`)
* **`--exclude`**: Skip files matching patterns (e.g., `*_temp*`)

## 📋 Prerequisites

* **Dart SDK:** Version 2.12 or higher - [Get Dart](https://dart.dev/get-dart)

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
   dart compile exe filen.dart -o filen-dart
   # Now you can run: ./filen <command>
```

## 📖 Usage

### Running from Source
```bash
dart filen.dart <command> [options] [arguments]
```

### Running Compiled Binary
```bash
./filen-dart <command> [options] [arguments]
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
| `up <sources...>` | Local files/folders + target path | Upload files or directories |
| `dl <uuid-or-path>` | File UUID or path | Download a single file |
| `download-path <path>` | Remote file or folder path | Download file/folder (supports recursion) |
| `mv <source> <dest>` | Source and destination paths | Move or rename items |
| `cp <source> <dest>` | Source and destination paths | Copy files |
| `rm <path>` | Path to trash | Move to trash |
| `rename <path> <new_name>` | Path and new name | Rename file or folder |

### Trash Operations
| Command | Arguments | Description |
|---------|-----------|-------------|
| `list-trash` | None | Show all trashed items |
| `restore-uuid <uuid>` | Item UUID + optional `-t <dest>` | Restore item by UUID |
| `restore-path <name>` | Item name + optional `-t <dest>` | Restore item by name |
| `delete-path <path>` | Path to delete | Permanently delete (requires confirmation) |

### Search & Discovery
| Command | Arguments | Description |
|---------|-----------|-------------|
| `search <query>` | Search term | Search files across drive |
| `find <path> <pattern>` | Start path + glob pattern | Recursively find matching files |
| `tree [path]` | Optional start path | Show folder structure as tree |
| `resolve <path>` | Path to resolve | Debug path resolution |

### System
| Command | Description |
|---------|-------------|
| `config` | Show configuration paths |
| `help` | Display help message |

## 🎛️ Global Options

| Flag | Short | Description |
|------|-------|-------------|
| `--verbose` | `-v` | Enable debug output |
| `--force` | `-f` | Skip confirmations |
| `--uuids` | | Show full UUIDs in listings |
| `--detailed` | `-d` | Show detailed file information |
| `--recursive` | `-r` | Recursive operations |
| `--preserve-timestamps` | `-p` | Preserve file modification times |
| `--target <path>` | `-t` | Specify destination path |
| `--on-conflict <mode>` | | Conflict resolution: `skip`, `overwrite`, `newer` |
| `--include <pattern>` | | Include only matching files |
| `--exclude <pattern>` | | Exclude matching files |
| `--depth <n>` | `-l` | Max depth for tree (default: 3) |
| `--maxdepth <n>` | | Max depth for find (default: -1 = infinite) |

## 💡 Examples

### Basic Operations

**Login with 2FA:**
```bash
dart filen.dart login
# Prompts for email, password, and 2FA code if enabled
```

**List files with details:**
```bash
dart filen.dart ls /Documents -d
```

**Show folder tree:**
```bash
dart filen.dart tree /Projects -l 2
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

**Upload only PDF files, excluding temps:**
```bash
dart filen.dart up ~/Documents/* /Backup -r \
  --include "*.pdf" --exclude "*_temp*"
```

**Upload with conflict handling:**
```bash
# Skip existing files
dart filen.dart up photos/ /Photos -r --on-conflict skip

# Overwrite all
dart filen.dart up photos/ /Photos -r --on-conflict overwrite

# Only upload newer files
dart filen.dart up photos/ /Photos -r --on-conflict newer -p
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

**Download folder recursively:**
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
# If download was interrupted, just run the same command again
# It will skip completed files and resume from where it stopped
dart filen.dart download-path /LargeBackup -r
```

### Search & Find

**Search across drive:**
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

### Move & Rename

**Rename a file:**
```bash
dart filen.dart rename /Photos/IMG_001.jpg vacation_start.jpg
```

**Move to different folder:**
```bash
dart filen.dart mv /vacation_start.jpg /Photos/2024/
```

**Move and rename:**
```bash
dart filen.dart mv /Photos/old_name.jpg /Archive/archived_photo.jpg
```

### Trash Operations

**Move to trash:**
```bash
dart filen.dart rm /OldFiles/temp.txt
```

**List trash contents:**
```bash
dart filen.dart list-trash --uuids
```

**Restore from trash:**
```bash
# By name
dart filen.dart restore-path "important.doc" -t /Recovered

# By UUID
dart filen.dart restore-uuid xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx -t /
```

**Permanently delete:**
```bash
dart filen.dart delete-path /trash/old_file.txt -f
```

### Advanced Workflows

**Backup with resume support:**
```bash
# Start backup
dart filen.dart up ~/Documents /Backup/Documents -r -p

# If interrupted, resume with same command
dart filen.dart up ~/Documents /Backup/Documents -r -p
# Completed files are skipped automatically
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

## 🗂️ Configuration

### Storage Locations

**Credentials:**
- macOS/Linux: `~/.filen-cli/credentials.json`
- Windows: `%USERPROFILE%\.filen-cli\credentials.json`

**Batch State Files:**
- macOS/Linux: `~/.filen-cli/batch_states/`
- Windows: `%USERPROFILE%\.filen-cli\batch_states\`

State files enable resume functionality. They're automatically deleted when operations complete successfully.

### Configuration File

View your configuration:
```bash
dart filen.dart config
```

## 🔧 Troubleshooting

### Resume Interrupted Operations

If an upload or download is interrupted, attempt to simply run the same command again. The CLI should:
1. Load the previous batch state
2. Skip already completed files
3. Continue from where it stopped

### Clear Batch States

If you want to force a fresh start:
```bash
rm -rf ~/.filen-cli/batch_states/
```

### Debug Mode

Enable verbose output to see detailed API calls and crypto operations:
```bash
dart filen.dart up file.pdf /Documents -v
```

## 🏗️ Architecture

### Key Components

- **FilenCLI**: Command-line interface and argument parsing
- **FilenClient**: API client with caching and retry logic
- **ConfigService**: Credential and batch state management

### Features

- **Caching**: 10-minute TTL for folder/file listings
- **Retry Logic**: Exponential backoff (1s, 2s, 4s) for network/5xx errors
- **Conflict Detection**: Handles 409 errors with automatic re-fetch
- **Batch Processing**: State-based resumable operations

## 📄 License

This project is licensed under the **GNU Affero General Public License v3.0 (AGPL-3.0)**.

See the [LICENSE](LICENSE) file for details.

## ⚠️ Disclaimer

This is an **unofficial** tool and is **not affiliated** with Filen.io.

- Use at your own risk
- Always maintain backups of critical data
- Test operations on non-critical files first
- The authors assume no liability for data loss
