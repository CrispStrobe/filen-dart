#!/usr/bin/env dart

/// ---------------------------------------------------------------------------
/// FILEN CLI - DART EDITION (v0.0.1)
/// ---------------------------------------------------------------------------

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:math';
import 'package:args/args.dart';
import 'package:http/http.dart' as http;
import 'package:crypto/crypto.dart' as crypto;

import 'package:convert/convert.dart';
import 'package:hex/hex.dart';
import 'package:path/path.dart' as p;
import 'package:pointycastle/export.dart' hide Digest, HMac, SHA512Digest;

void main(List<String> arguments) async {
  final cli = FilenCLI();
  await cli.run(arguments);
}

// Helper class to capture the hash result
class DigestSink implements Sink<crypto.Digest> {
  crypto.Digest? value;
  @override
  void add(crypto.Digest data) { value = data; }
  @override
  void close() {}
}

class FilenCLI {
  final ConfigService config;
  late final FilenClient client;
  bool debugMode = false;
  bool force = false;

  FilenCLI()
      : config = ConfigService(
            configPath: p.join(Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '.', '.filen-cli')) {
    client = FilenClient(config: config);
  }

  Future<void> run(List<String> arguments) async {
    final parser = ArgParser()
      ..addFlag('verbose', abbr: 'v', help: 'Enable verbose debug output')
      ..addFlag('force', abbr: 'f', help: 'Force overwrite / ignore conflicts');

    try {
      final argResults = parser.parse(arguments);
      debugMode = argResults['verbose'];
      force = argResults['force'];
      client.debugMode = debugMode;

      final commandArgs = argResults.rest;
      if (commandArgs.isEmpty) { printHelp(); return; }

      final command = commandArgs[0];

      switch (command) {
        case 'login':   await handleLogin(commandArgs.sublist(1)); break;
        case 'ls':      await handleList(argResults, commandArgs.sublist(1)); break;
        case 'list':    await handleList(argResults, commandArgs.sublist(1)); break;
        case 'mkdir':
          if (commandArgs.length < 2) _exit('Usage: mkdir <path>');
          await handleMkdir(commandArgs[1]);
          break;
        case 'upload':
        case 'up':
          if (commandArgs.length < 2) _exit('Usage: upload <local> [remote]');
          await handleUpload(commandArgs[1], commandArgs.length > 2 ? commandArgs[2] : '/');
          break;
        case 'download':
        case 'dl':
          if (commandArgs.length < 2) _exit('Usage: dl <remote> [local]');
          await handleDownload(commandArgs[1], commandArgs.length > 2 ? commandArgs[2] : null);
          break;
        case 'mv':
        case 'move':
          if (commandArgs.length < 3) _exit('Usage: mv <source> <dest>');
          await handleMove(commandArgs[1], commandArgs[2]);
          break;
        case 'cp':
        case 'copy':
          if (commandArgs.length < 3) _exit('Usage: cp <source> <dest>');
          await handleCopy(commandArgs[1], commandArgs[2]);
          break;
        case 'rm':
        case 'trash':
          if (commandArgs.length < 2) _exit('Usage: rm <path>');
          await handleTrash(commandArgs[1]);
          break;
        case 'rename':
          if (commandArgs.length < 3) _exit('Usage: rename <path> <new_name>');
          await handleRename(commandArgs[1], commandArgs[2]);
          break;
        case 'whoami':  await handleWhoami(); break;
        case 'logout':  await handleLogout(); break;
        case 'help':    printHelp(); break;
        default:        _exit('Unknown command: $command');
      }
    } catch (e, stackTrace) {
      stderr.writeln('❌ Error: $e');
      if (debugMode) stderr.writeln(stackTrace);
      exit(1);
    }
  }

  void printHelp() {
    print('╔═════════════════════════════════════════════╗');
    print('║    Filen CLI - v14.0 (Paths & Ops)          ║');
    print('╚═════════════════════════════════════════════╝');
    print('Flags: -v (verbose), -f (force/overwrite)');
    print('Commands:');
    print('  login');
    print('  ls [path]');
    print('  mkdir <path>');
    print('  up <local_file> [remote_folder]');
    print('  dl <remote_path> [local_path]');
    print('  mv <source> <dest_folder>');
    print('  rm <path> (moves to trash)');
    print('  rename <path> <new_name>');
    print('  whoami, logout');
  }

  // ---------------------------------------------------------------------------
  // HANDLERS
  // ---------------------------------------------------------------------------

  Future<void> handleLogin(List<String> args) async {
    stdout.write('Email: ');
    final email = stdin.readLineSync()?.trim() ?? '';
    if (email.isEmpty) _exit('Email is required');

    stdout.write('Password: ');
    stdin.echoMode = false;
    final rawPassword = stdin.readLineSync() ?? '';
    stdin.echoMode = true;
    print(''); 
    
    final password = rawPassword.replaceAll(RegExp(r'[\r\n]+$'), '');
    if (password.isEmpty) _exit('Password is required');

    print('🔐 Logging in...');

    try {
      var credentials = await client.login(email, password);
      
      print('📂 Fetching root folder info...');
      client.setAuth(credentials);
      final rootUUID = await client.fetchBaseFolderUUID();
      credentials['baseFolderUUID'] = rootUUID;

      await config.saveCredentials(credentials);
      _printSuccess(credentials);

    } catch (e) {
      final errStr = e.toString();
      if (errStr.contains('enter_2fa') || errStr.contains('wrong_2fa')) {
        print('\n🔐 Two-factor authentication code required.');
        stdout.write('Enter 2FA code: ');
        final tfaCode = stdin.readLineSync()?.trim();
        if (tfaCode == null || tfaCode.isEmpty) _exit('Code is required.');
        try {
          var credentials = await client.login(email, password, twoFactorCode: tfaCode!);
          
          print('📂 Fetching root folder info...');
          client.setAuth(credentials);
          final rootUUID = await client.fetchBaseFolderUUID();
          credentials['baseFolderUUID'] = rootUUID;

          await config.saveCredentials(credentials);
          _printSuccess(credentials);
        } catch (e2) {
          _exit('Login failed: ${e2.toString().replaceAll('Exception: ', '')}');
        }
      } else {
        _exit('Login failed: ${errStr.replaceAll('Exception: ', '')}');
      }
    }
  }

  void _printSuccess(Map<String, dynamic> creds) {
    print('✅ Login successful!');
    print('   User: ${creds['email']}');
    print('   Root: ${creds['baseFolderUUID']}');
    final keys = (creds['masterKeys'] ?? '').toString().split('|');
    print('   Decrypted Keys Saved: ${keys.length}');
    if (keys.isNotEmpty) {
      print('   Verify Key 0 Start: ${keys[0].substring(0, min(5, keys[0].length))}... (Should NOT start with 002)');
    }
  }

  Future<void> handleList(ArgResults flags, List<String> pathArgs) async {
    await _prepareClient();
    final path = pathArgs.isNotEmpty ? pathArgs.join(' ') : '/';
    final res = await client.resolvePath(path);
    
    if (res['type'] == 'file') {
      print('📄 File: ${p.basename(path)} (${res['uuid']})');
      return;
    }
    
    final uuid = res['uuid'];
    print('📂 ${res['path']} (UUID: $uuid)\n');

    final folders = await client.listFoldersAsync(uuid);
    final files = await client.listFolderFiles(uuid);
    final items = [...folders, ...files];
    items.sort((a, b) => (a['type'] == 'folder' ? -1 : 1)); // Folders first

    if (items.isEmpty) { print('   (empty)'); return; }

    print('Type  Name                                     Size           UUID');
    print('────  ───────────────────────────────────────  ────────────── ────────────────────────────────────');
    for (var i in items) {
      final type = i['type'] == 'folder' ? 'DIR ' : 'FILE';
      var name = i['name'] ?? 'Unknown';
      if (name.length > 38) name = name.substring(0, 35) + '...';
      final size = i['type'] == 'folder' ? '-' : formatSize(i['size'] ?? 0);
      print('$type  ${name.padRight(40)} ${size.padRight(14)} ${i['uuid']}');
    }
    print('────\nTotal: ${items.length} items');
  }

  Future<void> handleMkdir(String arg) async {
    await _prepareClient();
    // Resolve parent
    String parentPath = '/';
    String name = arg;
    if (arg.contains('/')) {
        parentPath = p.dirname(arg);
        name = p.basename(arg);
    }
    
    final parentRes = await client.resolvePath(parentPath);
    if (parentRes['type'] != 'folder') _exit("Parent '$parentPath' is not a folder");

    print('📂 Creating "$name" in "$parentPath"...');
    try {
      await client.createDirectory(name, parentRes['uuid']);
      print('✅ Directory created.');
    } catch (e) {
      _exit('Mkdir failed: $e');
    }
  }

  Future<void> handleUpload(String localPath, String remoteTargetDir) async {
    await _prepareClient();
    final f = File(localPath);
    if (!f.existsSync()) _exit('Local file not found: $localPath');

    // Resolve Remote Directory
    final dirRes = await client.resolvePath(remoteTargetDir);
    if (dirRes['type'] != 'folder') _exit("Remote target '$remoteTargetDir' is not a folder");
    final parentUUID = dirRes['uuid'];

    final filename = p.basename(localPath);

    // Check conflict
    print('🔍 Checking for conflicts...');
    final exists = await client.checkFileExists(parentUUID, filename);
    if (exists) {
        if (force) {
            print('⚠️ File exists. Force flag set. Overwriting (conceptually - creating new version/file)...');
            // Filen allows duplicate names, but usually we'd want to trash old or version it. 
            // For this script, we just upload a new one. The UI handles duplicates by allowing them.
        } else {
            _exit("File '$filename' already exists in destination. Use -f to proceed.");
        }
    }

    print('🚀 Uploading $filename to ${dirRes['path']}...');
    try {
      final s = DateTime.now();
      await client.uploadFile(f, parentUUID);
      print('✅ Done in ${DateTime.now().difference(s).inSeconds}s');
    } catch (e) {
      _exit('Upload failed: $e');
    }
  }

  Future<void> handleDownload(String remotePathOrUuid, String? localPath) async {
    await _prepareClient();
    
    String uuid;
    String name;
    
    // Check if it looks like a UUID (simple regex check)
    if (RegExp(r'^[a-f0-9]{8}-[a-f0-9]{4}-').hasMatch(remotePathOrUuid) && !remotePathOrUuid.contains('/')) {
        uuid = remotePathOrUuid;
        // Fetch metadata to get name
        final meta = await client.getFileMetadata(uuid);
        name = meta['name'];
    } else {
        // Resolve Path
        final res = await client.resolvePath(remotePathOrUuid);
        if (res['type'] != 'file') _exit("'$remotePathOrUuid' is not a file.");
        uuid = res['uuid'];
        name = p.basename(remotePathOrUuid);
    }

    final targetPath = localPath ?? name;
    
    if (File(targetPath).existsSync() && !force) {
        stdout.write('⚠️ File "$targetPath" exists. Overwrite? [y/N]: ');
        if (stdin.readLineSync()?.toLowerCase() != 'y') return;
    }

    print('📥 Downloading $name...');
    try {
      final s = DateTime.now();
      await client.downloadFile(uuid, targetPath);
      print('✅ Saved as "$targetPath" (${DateTime.now().difference(s).inSeconds}s)');
    } catch (e) {
      _exit('Download failed: $e');
    }
  }

  Future<void> handleMove(String srcPath, String destPath) async {
    await _prepareClient();
    
    // 1. Resolve Source
    final src = await client.resolvePath(srcPath);
    
    // 2. Analyze Destination
    Map<String, dynamic>? destParent;
    String? destName;
    bool isRename = false;

    try {
      // Try to see if dest exists (as a folder)
      final destObj = await client.resolvePath(destPath);
      if (destObj['type'] == 'folder') {
        // Destination is an existing folder -> Move inside it
        destParent = destObj;
        destName = p.basename(srcPath); // Keep original name
      } else {
        _exit('Destination "${destObj['path']}" already exists as a file.');
      }
    } catch (_) {
      // Destination does NOT exist -> Renaming or Moving to new filename
      final parentDir = p.dirname(destPath);
      destName = p.basename(destPath);
      
      try {
        destParent = await client.resolvePath(parentDir == '.' ? '/' : parentDir);
        if (destParent!['type'] != 'folder') throw Exception('Parent not dir');
      } catch (e) {
        _exit('Destination parent directory "$parentDir" not found.');
      }
      isRename = true;
    }

    if (destParent == null) {
        _exit('Could not resolve destination.');
        return; // specific return to satisfy compiler flow analysis
    }

    // 3. Execute Move/Rename
    // Note the usage of destParent! (with the exclamation mark) below
    print('🚚 Moving "${src['path']}" to "${destParent!['path']}/${destName}"...');
    
    // If we are moving to a different folder
    if (src['parent'] != destParent!['uuid']) {
        await client.moveItem(src['uuid'], destParent!['uuid'], src['type']);
    }

    // If the name is different, we must also rename
    final currentName = p.basename(src['path']!);
    if (isRename && destName != currentName && destName != null) {
        if (debugMode) print('   Running rename operation to "$destName"...');
        await client.renameItem(src['uuid'], destName, src['type']);
    }

    print('✅ Done.');
  }

  Future<void> handleCopy(String srcPath, String destPath) async {
    await _prepareClient();

    // 1. Resolve Source
    final src = await client.resolvePath(srcPath);
    if (src['type'] == 'folder') _exit('Recursive folder copy not yet supported.');

    // 2. Analyze Destination
    Map<String, dynamic>? destFolder;
    String targetName;

    try {
      final destObj = await client.resolvePath(destPath);
      if (destObj['type'] == 'folder') {
        // Copy into this folder
        destFolder = destObj;
        targetName = p.basename(srcPath);
      } else {
        if (!force) _exit('Destination file exists. Use -f to overwrite.');
        // If overwriting, resolve parent of the target
        final parentPath = p.dirname(destPath);
        destFolder = await client.resolvePath(parentPath == '.' ? '/' : parentPath);
        targetName = p.basename(destPath);
      }
    } catch (_) {
      // Dest doesn't exist -> Copy to new filename
      final parentPath = p.dirname(destPath);
      try {
        destFolder = await client.resolvePath(parentPath == '.' ? '/' : parentPath);
      } catch (e) { _exit('Destination parent directory not found.'); }
      targetName = p.basename(destPath);
    }

    if (destFolder == null) {
        _exit('Invalid destination.');
        return;
    }

    // 3. Perform Copy (Download -> Upload)
    print('📋 Copying "${src['path']}" to "${destFolder!['path']}/$targetName"...');
    
    final tempDir = Directory.systemTemp.createTempSync('filen_cli_cp_');
    final tempFile = File(p.join(tempDir.path, targetName));

    try {
      // A. Download to temp
      stdout.write('   1/2 Downloading to temp...       \r');
      await client.downloadFile(src['uuid'], tempFile.path);
      
      // B. Upload to dest
      stdout.write('   2/2 Uploading to destination...  \r');
      
      // Note: uploadFile takes a File object and a Parent UUID
      // We manually override the filename in the upload logic implicitly by the file object name,
      // but ensure your uploadFile method handles the parent correctly.
      await client.uploadFile(tempFile, destFolder!['uuid']);
      
      print('\n✅ Copy complete.');
    } catch (e) {
      print(''); // Newline to clear stdout
      _exit('Copy failed: $e');
    } finally {
      // Cleanup
      if (tempFile.existsSync()) tempFile.deleteSync();
      if (tempDir.existsSync()) tempDir.deleteSync();
    }
  }

  Future<void> handleRename(String path, String newName) async {
    await _prepareClient();
    final src = await client.resolvePath(path);
    
    print('✏️ Renaming "${src['path']}" to "$newName"...');
    try {
        await client.renameItem(src['uuid'], newName, src['type']);
        print('✅ Renamed.');
    } catch (e) {
        _exit('Rename failed: $e');
    }
  }

  Future<void> handleTrash(String path) async {
    await _prepareClient();
    final src = await client.resolvePath(path);
    
    print('🗑️ Moving "${src['path']}" to trash...');
    try {
        await client.trashItem(src['uuid'], src['type']);
        print('✅ Trashed.');
    } catch (e) {
        _exit('Trash failed: $e');
    }
  }

  Future<void> handleWhoami() async {
    final creds = await _requireAuth();
    print('📧 Email: ${creds['email']}');
    print('🆔 User ID: ${creds['userId']}');
    print('📁 Root Folder: ${creds['baseFolderUUID']}');
    final keys = (creds['masterKeys'] ?? '').toString().split('|');
    print('🔑 Keys Loaded: ${keys.length}');
    for(var i=0; i<keys.length; i++) {
        print('   Key [$i]: ${keys[i].substring(0, min(10, keys[i].length))}... (Len: ${keys[i].length})');
    }
  }

  Future<void> handleLogout() async {
    await config.clearCredentials();
    print('✅ Logged out');
  }

  Future<void> _prepareClient() async {
    final c = await config.readCredentials();
    if (c == null) _exit('Not logged in');
    client.setAuth(c!);
    if (client.baseFolderUUID.isEmpty) {
       try {
         client.baseFolderUUID = await client.fetchBaseFolderUUID();
         c['baseFolderUUID'] = client.baseFolderUUID;
         await config.saveCredentials(c);
       } catch (_) { _exit('Could not fetch root UUID'); }
    }
  }

  Future<Map<String, dynamic>> _requireAuth() async {
    final creds = await config.readCredentials();
    if (creds == null) _exit('Not logged in. Run "login" command first.');
    return creds!;
  }

  void _exit(String m) { stderr.writeln('❌ $m'); exit(1); }
}

// ============================================================================
// API CLIENT
// ============================================================================

class FilenClient {
  static const apiUrl = 'https://gateway.filen.io';
  final ConfigService config;
  bool debugMode = false;
  String apiKey = '';
  String baseFolderUUID = '';
  List<String> masterKeys = [];
  String email = '';

  FilenClient({required this.config});

  void setAuth(Map<String, dynamic> c) {
    apiKey = c['apiKey'] ?? '';
    baseFolderUUID = c['baseFolderUUID'] ?? '';
    masterKeys = (c['masterKeys'] ?? '').toString().split('|').where((k) => k.isNotEmpty).toList();
    email = c['email'] ?? '';
  }

  // --- AUTH & SETUP ---
  Future<Map<String, dynamic>> getAuthInfo(String email) async {
    final response = await http.post(
      Uri.parse('$apiUrl/v3/auth/info'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({'email': email}),
    );

    if (response.statusCode != 200) throw Exception('Auth info request failed');
    final data = json.decode(response.body);
    if (data['status'] != true) throw Exception(data['message']);

    return data['data'] ?? data;
  }

  Future<Map<String, dynamic>> login(String email, String password, {String twoFactorCode = "XXXXXX"}) async {
    final authInfo = await getAuthInfo(email);
    final authVersion = authInfo['authVersion'] ?? 2;
    final salt = authInfo['salt'] ?? '';

    // STEP 1: Derive BOTH the Login Password AND the Local Master Key
    print('🔍 Deriving keys...');
    final derived = await _deriveKeys(password, authVersion, salt);
    final derivedPassword = derived['password']!;
    final localMasterKey = derived['masterKey']!;

    if(debugMode) {
        print('   Local Master Key (for decrypting server keys): ${localMasterKey.substring(0, 10)}...');
    }

    // STEP 2: Authenticate
    final Map<String, dynamic> payload = {
      'email': email,
      'password': derivedPassword,
      'authVersion': authVersion,
      'twoFactorCode': twoFactorCode,
    };

    final response = await http.post(
      Uri.parse('$apiUrl/v3/login'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode(payload),
    );

    final data = json.decode(response.body);

    if (data['status'] == true && data['data'] != null) {
      final loginData = data['data'];
      
      // STEP 3: Decrypt the keys returned by the server
      // The server returns keys encrypted with the Local Master Key
      List<String> rawEncryptedKeys = [];
      if (loginData['masterKeys'] is String) {
        rawEncryptedKeys = [loginData['masterKeys']];
      } else if (loginData['masterKeys'] is List) {
        rawEncryptedKeys = (loginData['masterKeys'] as List).map((e) => e.toString()).toList();
      }

      print('🔍 Decrypting ${rawEncryptedKeys.length} master keys from server...');
      
      List<String> decryptedMasterKeys = [];
      for (var encryptedKey in rawEncryptedKeys) {
          try {
              // Try to decrypt using the Local Master Key we just derived
              final decrypted = await _decryptMetadata002(encryptedKey, localMasterKey);
              decryptedMasterKeys.add(decrypted);
              if(debugMode) print('   ✅ Key decrypted successfully.');
          } catch (e) {
              print('   ❌ Failed to decrypt a master key: $e');
              // If it's already a raw key (legacy?), use it as is? 
              // Usually safe to assume if it starts with 002 it must be decrypted.
          }
      }
      
      if (decryptedMasterKeys.isEmpty) {
          print('⚠️ Warning: No master keys could be decrypted. Creating new list with Local Master Key.');
          decryptedMasterKeys.add(localMasterKey);
      }

      return {
        'email': email,
        'apiKey': loginData['apiKey'],
        'masterKeys': decryptedMasterKeys.join('|'), // Save the DECRYPTED keys
        'baseFolderUUID': loginData['baseFolderUUID'] ?? '',
        'userId': (loginData['id'] ?? loginData['userId'] ?? '').toString(),
      };
    } else {
      final code = data['code'] ?? '';
      if (code == 'enter_2fa' || code == 'wrong_2fa') throw Exception(code);
      throw Exception(data['message'] ?? 'Login failed');
    }
  }

  Future<String> fetchBaseFolderUUID() async {
    if (apiKey.isEmpty) throw Exception('Cannot fetch base folder: No API Key');
    final response = await http.get(
      Uri.parse('$apiUrl/v3/user/baseFolder'),
      headers: {
        'Accept': 'application/json',
        'Authorization': 'Bearer $apiKey',
      },
    );
    if (response.statusCode != 200) throw Exception('Failed to fetch base folder');
    final data = json.decode(response.body);
    if (data['status'] == true && data['data'] != null) {
      return data['data']['uuid'] ?? '';
    }
    return data['uuid'] ?? ''; 
  }

  // --- HASHING ---
  Future<String> _generateHMACKey() async {
    final mk = masterKeys.last;
    final emailBytes = utf8.encode(email.toLowerCase());
    final mkBytes = utf8.encode(mk);
    final derived = _pbkdf2(mkBytes, emailBytes, 1, 32);
    return HEX.encode(derived).toLowerCase();
  }

  Future<String> _hashFileName(String name) async {
    final hmacKey = await _generateHMACKey();
    final hmacKeyBytes = HEX.decode(hmacKey);
    final hmac = crypto.Hmac(crypto.sha256, hmacKeyBytes);
    final digest = hmac.convert(utf8.encode(name.toLowerCase()));
    return HEX.encode(digest.bytes).toLowerCase();
  }

  // --- FILESYSTEM OPERATIONS ---

  // Check if file exists using API (more efficient than listing)
  Future<bool> checkFileExists(String parentUuid, String name) async {
    final hashed = await _hashFileName(name);
    try {
        final res = await _post('/v3/file/exists', {
            'parent': parentUuid,
            'nameHashed': hashed
        });
        return res['data']['exists'] == true;
    } catch (e) {
        return false;
    }
  }

  Future<void> createDirectory(String name, String parent) async {
    final uuid = _uuid();
    final mk = masterKeys.last;
    final encName = await _encryptMetadata002(json.encode({'name': name}), mk);
    final hashed = await _hashFileName(name);
    await _post('/v3/dir/create', {'uuid': uuid, 'name': encName, 'nameHashed': hashed, 'parent': parent});
  }

  Future<void> moveItem(String uuid, String destUuid, String type) async {
    final endpoint = type == 'folder' ? '/v3/dir/move' : '/v3/file/move';
    await _post(endpoint, {
        'uuid': uuid,
        'to': destUuid
    });
  }

  Future<void> trashItem(String uuid, String type) async {
    final endpoint = type == 'folder' ? '/v3/dir/trash' : '/v3/file/trash';
    await _post(endpoint, { 'uuid': uuid });
  }

  Future<void> renameItem(String uuid, String newName, String type) async {
    final mk = masterKeys.last;
    final nameHashed = await _hashFileName(newName);
    
    if (type == 'folder') {
        // Directory Rename: just name and nameHashed
        final encName = await _encryptMetadata002(json.encode({'name': newName}), mk);
        await _post('/v3/dir/rename', {
            'uuid': uuid,
            'name': encName,
            'nameHashed': nameHashed
        });
    } else {
        // File Rename: Must re-encrypt the full metadata
        final metaRaw = await getFileMetadata(uuid);
        
        // Update name in metadata
        metaRaw['name'] = newName;
        final metaJson = json.encode(metaRaw);
        
        // Encrypt new name and new metadata
        // Let's rely on the file key stored in metadata.
        final fileKey = metaRaw['key'];
        
        final nameEncrypted = await _encryptMetadata002(newName, fileKey);
        final metadataEncrypted = await _encryptMetadata002(metaJson, mk);
        
        await _post('/v3/file/rename', {
            'uuid': uuid,
            'name': nameEncrypted,
            'metadata': metadataEncrypted,
            'nameHashed': nameHashed
        });
    }
  }

  Future<void> uploadFile(File file, String parent) async {
    final name = p.basename(file.path);
    final size = await file.length();
    final uuid = _uuid();
    final mk = masterKeys.last;

    final fileKeyStr = _randomString(32);
    final fileKeyBytes = Uint8List.fromList(utf8.encode(fileKeyStr));
    final uploadKey = _randomString(32);
    final rm = _randomString(32);

    final ingest = 'https://ingest.filen.io';
    final raf = await file.open();
    int offset = 0;
    int index = 0;
    const chunkSz = 1048576; // 1MB

    final digestSink = DigestSink();
    final byteSink = crypto.sha512.startChunkedConversion(digestSink);

    while (offset < size) {
        final len = min(chunkSz, size - offset);
        final bytes = await raf.read(len);
        byteSink.add(bytes);
        final encChunk = await _encryptData(bytes, fileKeyBytes);
        
        final url = Uri.parse('$ingest/v3/upload?uuid=$uuid&index=$index&parent=$parent&uploadKey=$uploadKey');
        final r = await http.post(url, body: encChunk, headers: {'Authorization': 'Bearer $apiKey'});
        
        if (r.statusCode != 200) throw Exception('Chunk fail: ${r.statusCode}');
        offset += len;
        index++;
    }
    await raf.close();
    byteSink.close();
    
    final totalHash = HEX.encode(digestSink.value?.bytes ?? []).toLowerCase();

    final metaJson = json.encode({
        'name': name, 'size': size, 'mime': 'application/octet-stream',
        'key': fileKeyStr, 'hash': totalHash, 'lastModified': DateTime.now().millisecondsSinceEpoch,
    });

    final nameEncrypted = await _encryptMetadata002(name, fileKeyStr);
    final sizeEncrypted = await _encryptMetadata002(size.toString(), fileKeyStr);
    final mimeEncrypted = await _encryptMetadata002('application/octet-stream', fileKeyStr);
    final metadataEncrypted = await _encryptMetadata002(metaJson, mk);
    final nameHashed = await _hashFileName(name);

    await _post('/v3/upload/done', {
        'uuid': uuid, 'name': nameEncrypted, 'nameHashed': nameHashed,
        'size': sizeEncrypted, 'chunks': index, 'mime': mimeEncrypted,
        'rm': rm, 'metadata': metadataEncrypted, 'version': 2, 'uploadKey': uploadKey,
    });
  }

  Future<void> downloadFile(String uuid, String savePath) async {
    final info = await _post('/v3/file', {'uuid': uuid});
    final d = info['data'];
    final metaStr = await _tryDecrypt(d['metadata']);
    final meta = json.decode(metaStr);
    final keyBytes = _decodeUniversalKey(meta['key']);
    final chunks = int.parse(d['chunks'].toString());
    final host = 'https://egest.filen.io'; // or d['bucket'] specific subdomain if needed

    final sink = File(savePath).openWrite();
    for (var i = 0; i < chunks; i++) {
        final r = await http.get(Uri.parse('$host/${d['region']}/${d['bucket']}/$uuid/$i'));
        if (r.statusCode != 200) throw Exception('Chunk fail');
        sink.add(await _decryptData(r.bodyBytes, keyBytes));
    }
    await sink.close();
  }
  
  Future<Map<String, dynamic>> getFileMetadata(String uuid) async {
      final res = await _post('/v3/file', {'uuid': uuid});
      return json.decode(await _tryDecrypt(res['data']['metadata']));
  }

  // --- CRYPTO PRIMITIVES ---
  Future<String> _encryptMetadata002(String t, String k) async {
    final ivStr = _randomString(12);
    final dk = _pbkdf2(utf8.encode(k), utf8.encode(k), 1, 32);
    final c = GCMBlockCipher(AESEngine())..init(true, AEADParameters(KeyParameter(dk), 128, Uint8List.fromList(utf8.encode(ivStr)), Uint8List(0)));
    return '002$ivStr${base64.encode(c.process(Uint8List.fromList(utf8.encode(t))))}';
  }

  Future<String> _decryptMetadata002(String m, String k) async {
    if (!m.startsWith('002')) throw Exception('Ver');
    final iv = m.substring(3, 15);
    final dk = _pbkdf2(utf8.encode(k), utf8.encode(k), 1, 32);
    final c = GCMBlockCipher(AESEngine())..init(false, AEADParameters(KeyParameter(dk), 128, Uint8List.fromList(utf8.encode(iv)), Uint8List(0)));
    return utf8.decode(c.process(base64.decode(m.substring(15))));
  }

  Future<Uint8List> _encryptData(Uint8List d, Uint8List k) async {
    final iv = _randomBytes(12);
    final c = GCMBlockCipher(AESEngine())..init(true, AEADParameters(KeyParameter(k), 128, iv, Uint8List(0)));
    return Uint8List.fromList([...iv, ...c.process(d)]);
  }

  Future<Uint8List> _decryptData(Uint8List d, Uint8List k) async {
    final c = GCMBlockCipher(AESEngine())..init(false, AEADParameters(KeyParameter(k), 128, d.sublist(0, 12), Uint8List(0)));
    return c.process(d.sublist(12));
  }

  Uint8List _decodeUniversalKey(String k) {
      if (k.length == 32 && k.contains(RegExp(r'[a-zA-Z0-9\-_]'))) return Uint8List.fromList(utf8.encode(k));
      try { return base64Url.decode(base64Url.normalize(k)); } catch(_) {}
      try { return base64.decode(base64.normalize(k)); } catch(_) {}
      try { return Uint8List.fromList(HEX.decode(k)); } catch(_) {}
      throw Exception('Key decode failed');
  }

  Future<String> _tryDecrypt(String s) async {
    for (var k in masterKeys.reversed) { try { return await _decryptMetadata002(s, k); } catch (_) {} }
    throw Exception('Decrypt failed');
  }

  Uint8List _pbkdf2Sha512(List<int> password, List<int> salt, int iterations, int keyLen) {
    final mac = crypto.Hmac(crypto.sha512, password);
    final digestLen = 64; 
    final derivedKey = Uint8List(keyLen);
    final numBlocks = (keyLen / digestLen).ceil();

    for (var i = 1; i <= numBlocks; i++) {
      final blockIndex = Uint8List(4)..buffer.asByteData().setInt32(0, i, Endian.big);
      var u = mac.convert([...salt, ...blockIndex]).bytes;
      final block = Uint8List.fromList(u);

      for (var j = 1; j < iterations; j++) {
        u = mac.convert(u).bytes;
        for (var k = 0; k < block.length; k++) {
          block[k] ^= u[k];
        }
      }
      final offset = (i - 1) * digestLen;
      final copyLen = min(digestLen, keyLen - offset);
      derivedKey.setRange(offset, offset + copyLen, block.sublist(0, copyLen));
    }
    return derivedKey;
  }

  Future<String> _decryptString(String encryptedData, String keyHex) async {
    final parts = encryptedData.split(':');
    if (parts.length != 4) throw Exception('Invalid crypto format');

    final iv = Uint8List.fromList(HEX.decode(parts[1]));
    final authTag = Uint8List.fromList(HEX.decode(parts[2]));
    final ciphertext = Uint8List.fromList(HEX.decode(parts[3]));
    final key = Uint8List.fromList(HEX.decode(keyHex));

    final cipher = GCMBlockCipher(AESEngine());
    final params = AEADParameters(KeyParameter(key), 128, iv, Uint8List(0));
    cipher.init(false, params); 

    final input = Uint8List(ciphertext.length + authTag.length);
    input.setAll(0, ciphertext);
    input.setAll(ciphertext.length, authTag);

    final decrypted = cipher.process(input);
    return utf8.decode(decrypted);
  }

  // --- HELPERS ---
  
  // Recursively resolve a path string like "/Documents/Work" to a UUID
  Future<Map<String, dynamic>> resolvePath(String path) async {
    if (path == '/' || path == '' || path == '.') return {'type': 'folder', 'uuid': baseFolderUUID, 'path': '/'};
    
    // Normalize path
    final cleanPath = path.replaceAll(RegExp(r'^/|/$'), '');
    final parts = cleanPath.split('/');
    
    var currUUID = baseFolderUUID;
    var currPath = '';

    for (var i = 0; i < parts.length; i++) {
       final targetName = parts[i];
       if (targetName.isEmpty) continue;

       // 1. List content of current folder
       final c = await _post('/v3/dir/content', {'uuid': currUUID});
       bool found = false;

       // 2. Check Folders
       for (var f in c['data']['folders']) {
         try { 
             var rawDec = await _tryDecrypt(f['name']);
             // Handle JSON names (new format) vs String names (legacy)
             var name = rawDec.startsWith('{') ? json.decode(rawDec)['name'] : rawDec;
             
             if (name == targetName) {
                 currUUID = f['uuid'];
                 currPath += '/$targetName';
                 found = true;
                 if (i == parts.length - 1) return {'type': 'folder', 'uuid': currUUID, 'path': currPath};
                 break;
             }
         } catch (_) {}
       }
       if (found) continue;

       // 3. Check Files (Only valid if it's the last part of the path)
       if (i == parts.length - 1) {
          for (var f in c['data']['uploads']) {
             try { 
               final m = json.decode(await _tryDecrypt(f['metadata']));
               if (m['name'] == targetName) {
                   // note: 'parent': currUUID is included
                   return {'type': 'file', 'uuid': f['uuid'], 'path': '$currPath/$targetName', 'parent': currUUID};
               }
             } catch (_) {}
          }
       }
       
       throw Exception('Path not found: $targetName in $currPath');
    }
    return {'type': 'folder', 'uuid': currUUID, 'path': currPath};
  }

  Future<List<Map<String, dynamic>>> listFoldersAsync(String u) async {
      final d = (await _post('/v3/dir/content', {'uuid': u}))['data']['folders'];
      List<Map<String, dynamic>> res = [];
      for (var f in d) {
          try {
              var dec = await _tryDecrypt(f['name']);
              var name = dec.startsWith('{') ? json.decode(dec)['name'] : dec;
              res.add({'type': 'folder', 'name': name, 'uuid': f['uuid'], 'size': 0});
          } catch (_) { res.add({'type': 'folder', 'name': '[Enc]', 'uuid': f['uuid'], 'size': 0}); }
      }
      return res;
  }

  Future<List<Map<String, dynamic>>> listFolderFiles(String u) async {
    final d = (await _post('/v3/dir/content', {'uuid': u}))['data']['uploads'];
    return Future.wait((d as List).map((f) async {
        try {
           final m = json.decode(await _tryDecrypt(f['metadata']));
           return {'type': 'file', 'name': m['name'], 'uuid': f['uuid'], 'size': m['size']};
        } catch (_) { return {'type': 'file', 'name': '[Enc]', 'uuid': f['uuid'], 'size': 0}; }
    }).toList().cast<Future<Map<String,dynamic>>>());
  }

  Future<Map<String, dynamic>> _post(String ep, dynamic b, {bool auth = true}) async {
    final r = await http.post(Uri.parse('$apiUrl$ep'), headers: _h(auth: auth), body: json.encode(b));
    final bodyStr = utf8.decode(r.bodyBytes, allowMalformed: true);
    if (r.statusCode != 200) throw Exception('API $ep: ${r.statusCode} - $bodyStr');
    final d = json.decode(bodyStr);
    if (d['status'] != true) throw Exception(d['message']);
    return d;
  }

  Map<String, String> _h({bool auth = true}) => 
    {'Content-Type': 'application/json', 'Accept': 'application/json', if (auth && apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey'};

  Future<Map<String, String>> _deriveKeys(String p, int v, String s) async {
    final k = HEX.encode(_pbkdf2(utf8.encode(p), utf8.encode(s), 200000, 64)).toLowerCase();
    return (v == 2) 
      ? {'masterKey': k.substring(0, 64), 'password': HEX.encode(crypto.sha512.convert(utf8.encode(k.substring(64))).bytes).toLowerCase()}
      : {'masterKey': k, 'password': k};
  }

  Uint8List _pbkdf2(List<int> p, List<int> s, int iter, int len) {
    final mac = crypto.Hmac(crypto.sha512, p);
    final out = Uint8List(len);
    final blocks = (len / 64).ceil();
    for (var i = 1; i <= blocks; i++) {
      var u = mac.convert([...s, ...Uint8List(4)..buffer.asByteData().setInt32(0, i, Endian.big)]).bytes;
      var t = Uint8List.fromList(u);
      for (var j = 1; j < iter; j++) { u = mac.convert(u).bytes; for (var k=0; k<t.length; k++) t[k] ^= u[k]; }
      final off = (i - 1) * 64;
      out.setRange(off, off + min(64, len - off), t);
    }
    return out;
  }

  Future<String> _derivePassword(String password, int authVersion, String salt) async {
    final passwordBytes = utf8.encode(password);
    
    if (authVersion == 2) {
        // TS: const derivedKey = await deriveKeyFromPassword({ ... returnHex: true })
        final saltBytes = utf8.encode(salt);
        final derivedKeyBytes = _pbkdf2Sha512(passwordBytes, saltBytes, 200000, 64);
        final derivedKeyHex = HEX.encode(derivedKeyBytes).toLowerCase();

        // TS: let derivedPassword = derivedKey.substring(derivedKey.length / 2, derivedKey.length)
        // Length of Hex String = 128. Length/2 = 64.
        // We take the SECOND half (index 64 to 128)
        final passwordPartHex = derivedKeyHex.substring(64);
        
        // TS: derivedPassword = nodeCrypto.createHash("sha512").update(textEncoder.encode(derivedPassword)).digest("hex")
        // We hash the UTF8 BYTES of the HEX STRING (not the raw bytes of the key)
        final passwordPartBytes = utf8.encode(passwordPartHex);
        final finalPasswordHash = crypto.sha512.convert(passwordPartBytes);
        
        return HEX.encode(finalPasswordHash.bytes).toLowerCase();
    } else {
        // AuthVersion 1 (Legacy)
        final saltBytes = utf8.encode(salt);
        final derivedKey = _pbkdf2Sha512(passwordBytes, saltBytes, 200000, 64);
        return HEX.encode(derivedKey).toLowerCase();
    }
  }
  
  Uint8List _randomBytes(int l) => Uint8List.fromList(List.generate(l, (_) => Random.secure().nextInt(256)));
  String _uuid() {
    final b = _randomBytes(16); b[6] = (b[6]&0x0f)|0x40; b[8] = (b[8]&0x3f)|0x80;
    final h = HEX.encode(b);
    return '${h.substring(0,8)}-${h.substring(8,12)}-${h.substring(12,16)}-${h.substring(16,20)}-${h.substring(20)}';
  }
  String _randomString(int l) => List.generate(l, (_) => 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_'[Random.secure().nextInt(64)]).join();
}

class ConfigService {
  final File f;
  ConfigService({required String configPath}) : f = File(p.join(configPath, 'credentials.json')) {
    if (!f.parent.existsSync()) f.parent.createSync(recursive: true);
  }
  Future<void> saveCredentials(Map<String, dynamic> d) async { await f.writeAsString(json.encode(d)); }
  Future<Map<String, dynamic>?> readCredentials() async {
    if (await f.exists()) return json.decode(await f.readAsString());
    return null;
  }
  Future<void> clearCredentials() async { if (await f.exists()) await f.delete(); }
}

String formatSize(dynamic b) {
  int bytes = (b is int) ? b : int.tryParse(b.toString()) ?? 0;
  if (bytes <= 0) return '0 B';
  const s = ['B', 'KB', 'MB', 'GB', 'TB'];
  var i = 0; double v = bytes.toDouble();
  while (v >= 1024 && i < s.length - 1) { v /= 1024; i++; }
  return '${v.toStringAsFixed(1)} ${s[i]}';
}