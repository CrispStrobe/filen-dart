
# Filen CLI (unofficial Dart Edition)

A basic (unofficial), open-source Command Line Interface for [Filen.io](https://filen.io), written in Dart. 

This CLI creates a simple bridge to the Filen API, allowing for basic file management, uploading, downloading, and directory organization directly from your terminal. It supports standard path resolution (e.g., `/Folder/File.txt`) rather than requiring raw UUIDs.

## License

This project is licensed under the **GNU Affero General Public License v3.0 (AGPL-3.0)**. 
See the [LICENSE](LICENSE) file for details.

## Features

* **Authentication:** Secure login.
* **Path Resolution:** Use standard file paths (`/MyDocs/Work/Project.pdf`) instead of UUIDs.
* **File Operations:**
    * `ls`: List files and folders.
    * `up` (Upload): Upload files with conflict detection.
    * `dl` (Download): Download files (supports overwriting).
    * `mv` (Move): Move files/folders or rename them.
    * `cp` (Copy): Copy files (download-upload loop).
    * `rm` (Trash): Move items to the trash.
    * `mkdir`: Create directories recursively.

## Prerequisites

* **Dart SDK:** Version 2.12 or higher. [Get Dart](https://dart.dev/get-dart).

## Installation

1.  **Clone the repository:**
    ```bash
    git clone <repository-url>
    cd <repository-directory>
    ```

2.  **Install dependencies:**
    ```bash
    dart pub get
    ```

3.  **(Optional) Compile to a standalone binary:**
    This allows you to run (e.g.) `filen-dart` instead of `dart filen.dart`.
    ```bash
    dart compile exe filen.dart -o filen-dart
    ```

## Usage

If running from source:
```bash
dart filen.dart <command> [arguments]
````

If compiled:

```bash
./filen-dart <command> [arguments]
```

### Commands

| Command | Alias | Usage | Description |
| :--- | :--- | :--- | :--- |
| **Login** | | `login` | Authenticate with email/password. |
| **List** | `ls` | `ls [path]` | List contents of root or specific folder. |
| **Upload** | `up` | `up <local_file> [remote_path]` | Upload a file to a specific folder. |
| **Download** | `dl` | `dl <remote_path> [local_path]` | Download a file to local disk. |
| **Make Dir** | `mkdir` | `mkdir <path/folder_name>` | Create a new folder. |
| **Move** | `mv` | `mv <source> <destination>` | Move or Rename a file/folder. |
| **Copy** | `cp` | `cp <source> <destination>` | Copy a file (via local temp storage). |
| **Remove** | `rm` | `rm <path>` | Move a file/folder to Trash. |
| **Whoami** | | `whoami` | Show current logged-in user and Root UUID. |

### Global Flags

  * `-v`, `--verbose`: Enable detailed debug logging (API responses, crypto details).
  * `-f`, `--force`: Force actions (overwrite files on download/upload).

## Examples

**1. Login:**

```bash
dart filen.dart login
```

**2. List the root directory:**

```bash
dart filen.dart ls
```

**3. Upload a file to a specific folder:**

```bash
dart filen.dart up ./report.pdf /Documents/Work/
```

**4. Move and Rename a file:**

```bash
# Renaming
dart filen.dart mv /Photos/img_001.jpg /Photos/vacation_start.jpg

# Moving to a new folder
dart filen.dart mv /vacation_start.jpg /Photos/2024/
```

**5. Copy a file:**

```bash
dart filen.dart cp /Templates/contract.docx /Clients/NewClient/contract_draft.docx
```

## Configuration

Credentials are stored locally in:

  * **macOS/Linux:** `~/.filen-cli/credentials.json`
  * **Windows:** `%USERPROFILE%\.filen-cli\credentials.json`

To logout and clear credentials, run:

```bash
dart filen.dart logout
```

## Disclaimer

This is an unofficial tool and is not affiliated with Filen.io. Use at your own risk. Always ensure you have backups of critical data before performing batch operations.
