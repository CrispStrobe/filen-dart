/// Download pipeline: single file, range, and batch downloads with
/// conflict handling and resume support.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'package:filen_dart/api.dart';
import 'package:filen_dart/cache.dart';
import 'package:filen_dart/crypto.dart';
import 'package:filen_dart/drive.dart';
import 'package:filen_dart/utils.dart';

class FilenDownload {
  final FilenApi api;
  final FilenCrypto crypto;
  final FilenCache cache;
  final FilenDrive drive;

  FilenDownload({
    required this.api,
    required this.crypto,
    required this.cache,
    required this.drive,
  });

  List<String> get masterKeys => drive.masterKeys;

  /// Download file with range support.
  Future<Uint8List> downloadFileRange(
    String uuid, {
    int? rangeStart,
    int? rangeEnd,
  }) async {
    api.log('Downloading file range: $uuid ($rangeStart-$rangeEnd)');

    final info = await api.post('/v3/file', {'uuid': uuid});
    final d = info['data'];
    final metaStr = await crypto.tryDecrypt(d['metadata'], masterKeys);
    final meta = json.decode(metaStr);
    final keyBytes = crypto.decodeUniversalKey(meta['key']);
    final chunks = int.parse(d['chunks'].toString());
    final host = 'https://egest.filen.io';

    const chunkSize = 1048576;
    final startChunk = rangeStart != null ? rangeStart ~/ chunkSize : 0;
    final endChunk = rangeEnd != null ? rangeEnd ~/ chunkSize : chunks - 1;

    final buffer = BytesBuilder();

    for (var i = startChunk; i <= endChunk && i < chunks; i++) {
      final r = await http
          .get(Uri.parse('$host/${d['region']}/${d['bucket']}/$uuid/$i'));
      if (r.statusCode != 200) throw Exception('Chunk download failed');

      final decrypted = await crypto.decryptData(r.bodyBytes, keyBytes);

      if (i == startChunk && rangeStart != null) {
        final offset = rangeStart % chunkSize;
        buffer.add(decrypted.sublist(offset));
      } else if (i == endChunk && rangeEnd != null) {
        final endOffset = rangeEnd % chunkSize + 1;
        buffer.add(decrypted.sublist(0, endOffset));
      } else {
        buffer.add(decrypted);
      }
    }

    return buffer.toBytes();
  }

  /// Download file content as bytes (no disk I/O — needed for Web platform).
  Future<Uint8List> downloadFileBytes(
    String uuid, {
    Function(int bytesDownloaded, int totalBytes)? onProgress,
  }) async {
    api.log('Downloading file bytes: $uuid');

    final info = await api.post('/v3/file', {'uuid': uuid});
    final d = info['data'];
    final metaStr = await crypto.tryDecrypt(d['metadata'], masterKeys);
    final meta = json.decode(metaStr);
    final keyBytes = crypto.decodeUniversalKey(meta['key']);
    final chunks = int.parse(d['chunks'].toString());
    final host = 'https://egest.filen.io';
    final fileSize = meta['size'] ?? 0;

    final buffer = BytesBuilder();
    int bytesDownloaded = 0;

    for (var i = 0; i < chunks; i++) {
      final r = await http
          .get(Uri.parse('$host/${d['region']}/${d['bucket']}/$uuid/$i'));
      if (r.statusCode != 200) throw Exception('Chunk download failed');

      final decrypted = await crypto.decryptData(r.bodyBytes, keyBytes);
      buffer.add(decrypted);

      bytesDownloaded += decrypted.length;
      if (onProgress != null) {
        onProgress(bytesDownloaded, fileSize);
      }
    }

    return buffer.toBytes();
  }

  /// Download a single file by UUID.
  Future<Map<String, dynamic>> downloadFile(
    String uuid, {
    String? savePath,
    Function(int bytesDownloaded, int totalBytes)? onProgress,
  }) async {
    api.log('Downloading file: $uuid');

    final info = await api.post('/v3/file', {'uuid': uuid});
    final d = info['data'];
    final metaStr = await crypto.tryDecrypt(d['metadata'], masterKeys);
    final meta = json.decode(metaStr);
    final keyBytes = crypto.decodeUniversalKey(meta['key']);
    final chunks = int.parse(d['chunks'].toString());
    final host = 'https://egest.filen.io';

    final filename = meta['name'] ?? 'file';
    final fileSize = meta['size'] ?? 0;
    final modificationTime = meta['lastModified'];

    if (onProgress == null) {
      print('   📄 File: $filename (${formatSize(fileSize)})');
    }

    final targetPath = savePath ?? filename;
    final sink = File(targetPath).openWrite();

    int bytesDownloaded = 0;

    for (var i = 0; i < chunks; i++) {
      final r = await http
          .get(Uri.parse('$host/${d['region']}/${d['bucket']}/$uuid/$i'));
      if (r.statusCode != 200) throw Exception('Chunk fail');

      final decrypted = await crypto.decryptData(r.bodyBytes, keyBytes);
      sink.add(decrypted);

      bytesDownloaded += decrypted.length;
      if (onProgress != null) {
        onProgress(bytesDownloaded, fileSize);
      }
    }

    await sink.close();

    return {
      'data': await File(targetPath).readAsBytes(),
      'filename': filename,
      'modificationTime': modificationTime,
    };
  }

  /// Batch download by path with recursive support and resume.
  Future<void> downloadPath(
    String remotePath, {
    String? localDestination,
    required bool recursive,
    required String onConflict,
    required bool preserveTimestamps,
    required List<String> include,
    required List<String> exclude,
    required String batchId,
    Map<String, dynamic>? initialBatchState,
    required Future<void> Function(Map<String, dynamic>) saveStateCallback,
  }) async {
    final itemInfo = await drive.resolvePath(remotePath);

    // Handle single file
    if (itemInfo['type'] == 'file') {
      final filename = p.basename(remotePath);
      if (!shouldIncludeFile(filename, include, exclude)) return;

      final localPath = localDestination != null &&
              FileSystemEntity.isDirectorySync(localDestination)
          ? p.join(localDestination, filename)
          : (localDestination ?? filename);

      if (File(localPath).existsSync() && onConflict == 'skip') {
        print('⏭️  Skipping: $filename (exists)');
        return;
      }

      print('📥 Downloading: $filename');
      await downloadFile(itemInfo['uuid'], savePath: localPath);
      print('✅ Downloaded: $localPath');
      return;
    }

    // Handle folder
    if (itemInfo['type'] != 'folder') throw Exception("Unknown type");
    if (!recursive) throw Exception("Use -r for recursive download");

    final baseDestPath =
        localDestination ?? (itemInfo['metadata']?['name'] ?? 'download');
    await Directory(baseDestPath).create(recursive: true);

    Map<String, dynamic> batchState;
    List<dynamic> tasks;

    if (initialBatchState != null) {
      print("🔄 Resuming batch...");
      batchState = initialBatchState;
      tasks = batchState['tasks'];
    } else {
      print("🔍 Building task list (Fast)...");
      tasks = [];

      final treeData = await drive.getFlatFolderTree(itemInfo['uuid']);
      final rawFolders = treeData['folders'] as List? ?? [];
      final rawFiles = (treeData['files'] as List?) ??
          (treeData['uploads'] as List?) ??
          [];

      final folderMap = <String, Map<String, dynamic>>{};
      for (var f in rawFolders) {
        try {
          String uuid, encName, parent;
          if (f is List) {
            if (f.length < 3) continue;
            uuid = f[0]; encName = f[1]; parent = f[2];
          } else {
            if (f['deleted'] == true || f['trash'] == true) continue;
            uuid = f['uuid']; encName = f['name']; parent = f['parent'];
          }
          var decName = await crypto.tryDecrypt(encName, masterKeys);
          if (decName.startsWith('{')) {
            decName = json.decode(decName)['name'];
          }
          folderMap[uuid] = {'name': decName, 'parent': parent};
        } catch (_) {}
      }

      String? getRelPath(String? parentUuid) {
        var parts = <String>[];
        var curr = parentUuid;
        var seen = <String>{};
        while (curr != null && curr != itemInfo['uuid']) {
          if (seen.contains(curr)) return null;
          seen.add(curr);
          if (!folderMap.containsKey(curr)) return null;
          final f = folderMap[curr]!;
          parts.add(f['name']);
          curr = f['parent'];
        }
        if (curr == null && itemInfo['uuid'] != 'root') return null;
        return parts.reversed.join(Platform.pathSeparator);
      }

      for (var f in rawFiles) {
        try {
          String uuid, encMeta, parent;
          if (f is List) {
            if (f.length < 6) continue;
            uuid = f[0]; parent = f[4]; encMeta = f[5];
          } else {
            if (f['deleted'] == true || f['trash'] == true) continue;
            uuid = f['uuid']; parent = f['parent']; encMeta = f['metadata'];
          }

          final decMeta = await crypto.tryDecrypt(encMeta, masterKeys);
          final meta = json.decode(decMeta);
          final filename = meta['name'];
          final lastMod = meta['lastModified'] ?? 0;

          if (!shouldIncludeFile(filename, include, exclude)) continue;

          var relDir = getRelPath(parent);
          if (parent == itemInfo['uuid'])
            relDir = '';
          else if (relDir == null) continue;

          final localPath = p.join(baseDestPath, relDir!, filename);
          tasks.add({
            'remoteUuid': uuid,
            'localPath': localPath,
            'status': 'pending',
            'remoteModificationTime': lastMod,
          });
        } catch (e) {
          api.log("File parse error: $e");
        }
      }

      batchState = {
        'operationType': 'download',
        'remotePath': remotePath,
        'localDestination': baseDestPath,
        'tasks': tasks
      };
      await saveStateCallback(batchState);
      print("📝 Task list: ${tasks.length} files");
    }

    // Execution
    int successCount = 0;
    int skippedCount = 0;
    int errorCount = 0;
    int completedPreviously = 0;
    final totalTasks = tasks.length;

    for (int i = 0; i < totalTasks; i++) {
      final task = tasks[i] as Map<String, dynamic>;
      final localPath = task['localPath'] as String;
      final remoteUuid = task['remoteUuid'] as String;
      final status = task['status'] as String;
      final remoteModTime = task['remoteModificationTime'];
      final filename = p.basename(localPath);

      final pct = ((i) / totalTasks * 100).toStringAsFixed(1);
      final width = 20;
      final filled = ((i / totalTasks) * width).round();
      final bar = '█' * filled + '░' * (width - filled);
      if (!api.debugMode) {
        stdout.write(
            '\rDown: ${filename.padRight(20).substring(0, 20)} |$bar| ${i + 1}/$totalTasks ($pct%)  ');
      }

      if (status == 'completed') {
        completedPreviously++;
        continue;
      }
      if (status.startsWith('skipped')) {
        skippedCount++;
        continue;
      }

      await Directory(p.dirname(localPath)).create(recursive: true);
      final localFile = File(localPath);

      if (await localFile.exists()) {
        if (onConflict == 'skip') {
          skippedCount++;
          task['status'] = 'skipped_conflict';
          await saveStateCallback(batchState);
          continue;
        }
        if (onConflict == 'newer' && remoteModTime != null) {
          final stat = await localFile.stat();
          if (stat.modified.millisecondsSinceEpoch >=
              (remoteModTime is int
                  ? remoteModTime
                  : int.parse(remoteModTime.toString()))) {
            skippedCount++;
            task['status'] = 'skipped_newer';
            await saveStateCallback(batchState);
            continue;
          }
        }
      }

      try {
        final result =
            await downloadFile(remoteUuid, savePath: localPath);

        if (preserveTimestamps) {
          final mt = result['modificationTime'] ?? remoteModTime;
          if (mt != null) {
            try {
              final dt = mt is int
                  ? DateTime.fromMillisecondsSinceEpoch(mt)
                  : DateTime.parse(mt.toString());
              await localFile.setLastModified(dt);
            } catch (_) {}
          }
        }

        successCount++;
        task['status'] = 'completed';
      } catch (e) {
        if (api.debugMode) print("Error: $e");
        errorCount++;
        task['status'] = 'error_download';
      }

      await saveStateCallback(batchState);
    }

    print('\n' + '=' * 40);
    print('📊 Download Summary:');
    if (completedPreviously > 0) print('  ✅ Previous: $completedPreviously');
    print('  ✅ Downloaded: $successCount');
    print('  ⏭️  Skipped: $skippedCount');
    print('  ❌ Errors: $errorCount');
    print('=' * 40);
  }
}
