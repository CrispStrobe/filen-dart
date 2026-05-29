/// Upload pipeline: chunked uploads with resume, batch operations,
/// and progress tracking.
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto_pkg;
import 'package:glob/glob.dart';
import 'package:glob/list_local_fs.dart';
import 'package:hex/hex.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'package:filen_dart/api.dart';
import 'package:filen_dart/cache.dart';
import 'package:filen_dart/crypto.dart';
import 'package:filen_dart/drive.dart';
import 'package:filen_dart/memory_gate.dart';
import 'package:filen_dart/utils.dart';

/// Exception for chunk upload failures (carries resume state).
class ChunkUploadException implements Exception {
  final String message;
  final String fileUuid;
  final String uploadKey;
  final int lastSuccessfulChunk;
  final Object? originalError;

  ChunkUploadException(
    this.message, {
    required this.fileUuid,
    required this.uploadKey,
    required this.lastSuccessfulChunk,
    this.originalError,
  });

  @override
  String toString() => 'ChunkUploadException: $message '
      '(uuid: $fileUuid, uploadKey: $uploadKey, lastChunk: $lastSuccessfulChunk)';
}

class FilenUpload {
  final FilenApi api;
  final FilenCrypto crypto;
  final FilenCache cache;
  final FilenDrive drive;
  final MemoryGate memoryGate;

  FilenUpload({
    required this.api,
    required this.crypto,
    required this.cache,
    required this.drive,
    MemoryGate? memoryGate,
  }) : memoryGate = memoryGate ?? MemoryGate();

  List<String> get masterKeys => drive.masterKeys;
  String get email => drive.email;

  Future<Map<String, String>> uploadFileChunked(
    File file,
    String parent, {
    String? fileUuid,
    String? creationTime,
    String? modificationTime,
    String? resumeUploadKey,
    int resumeFromChunk = 0,
    Function(int current, int total, int bytesUploaded, int totalBytes)?
        onProgress,
    Function(String uuid, String uploadKey)? onUploadStart,
  }) async {
    final name = p.basename(file.path);
    final size = await file.length();
    final uuid = fileUuid ?? crypto.uuid();
    final mk = masterKeys.last;
    if (mk.isEmpty) throw Exception('No master keys available');

    final fileKeyStr = crypto.randomString(32);
    final fileKeyBytes = Uint8List.fromList(utf8.encode(fileKeyStr));

    var lastMod = modificationTime;
    if (lastMod == null && creationTime == null) {
      try {
        final stat = await file.stat();
        lastMod = stat.modified.millisecondsSinceEpoch.toString();
      } catch (_) {}
    }

    // Handle empty files
    if (size == 0) {
      api.log('Uploading empty file via /v3/upload/empty');

      final metaJson = json.encode({
        'name': name,
        'size': size,
        'mime': 'application/octet-stream',
        'key': fileKeyStr,
        'hash': '',
        'lastModified': lastMod != null
            ? int.tryParse(lastMod) ?? DateTime.now().millisecondsSinceEpoch
            : DateTime.now().millisecondsSinceEpoch,
      });

      final nameEncrypted =
          await crypto.encryptMetadata002(name, fileKeyStr);
      final sizeEncrypted =
          await crypto.encryptMetadata002(size.toString(), fileKeyStr);
      final mimeEncrypted = await crypto.encryptMetadata002(
          'application/octet-stream', fileKeyStr);
      final metadataEncrypted =
          await crypto.encryptMetadata002(metaJson, mk);
      final nameHashed =
          await crypto.hashFileName(name, masterKeys, email);

      await api.post('/v3/upload/empty', {
        'uuid': uuid,
        'name': nameEncrypted,
        'nameHashed': nameHashed,
        'size': sizeEncrypted,
        'parent': parent,
        'mime': mimeEncrypted,
        'metadata': metadataEncrypted,
        'version': 2,
      });

      cache.invalidate(parent);
      if (onProgress != null) onProgress(1, 1, 0, 0);

      return {'uuid': uuid, 'hash': '', 'size': '0'};
    }

    // Regular chunked upload
    final uploadKey = resumeUploadKey ?? crypto.randomString(32);

    if (onUploadStart != null && resumeFromChunk == 0) {
      onUploadStart(uuid, uploadKey);
    }

    final rm = crypto.randomString(32);
    const chunkSz = 1048576;
    final totalChunks = (size / chunkSz).ceil();

    final ingest = 'https://ingest.filen.io';
    final raf = await file.open();
    int offset = resumeFromChunk * chunkSz;
    int index = resumeFromChunk;

    final digestSink = DigestSink();
    final byteSink = crypto_pkg.sha512.startChunkedConversion(digestSink);

    try {
      // If resuming, re-hash previous chunks
      if (resumeFromChunk > 0) {
        api.log('Re-hashing previous $resumeFromChunk chunks...');
        await raf.setPosition(0);
        for (var i = 0; i < resumeFromChunk; i++) {
          final len = min(chunkSz, size - (i * chunkSz));
          final bytes = await raf.read(len);
          byteSink.add(bytes);
        }
        await raf.setPosition(offset);
      }

      while (offset < size) {
        final len = min(chunkSz, size - offset);
        final bytes = await raf.read(len);
        byteSink.add(bytes);
        final encChunk = await crypto.encryptData(bytes, fileKeyBytes);

        final chunkHash = crypto_pkg.sha512.convert(encChunk);
        final hashHex = HEX.encode(chunkHash.bytes).toLowerCase();

        final url = Uri.parse(
            '$ingest/v3/upload?uuid=$uuid&index=$index&parent=$parent&uploadKey=$uploadKey&hash=$hashHex');

        if (onProgress != null) {
          onProgress(index + 1, totalChunks, offset + len, size);
        } else {
          final progress =
              ((index + 1) / totalChunks * 100).toStringAsFixed(1);
          stdout.write(
              '     Uploading... ${index + 1}/$totalChunks chunks ($progress%)  \r');
        }

        try {
          final r = await http.post(url, body: encChunk, headers: {
            'Authorization': 'Bearer ${api.apiKey}'
          }).timeout(Duration(seconds: 30));

          if (r.statusCode != 200) {
            throw Exception(
                'Chunk upload failed: ${r.statusCode} - ${r.body}');
          }
        } catch (e) {
          api.log('Chunk $index failed: $e');
          throw ChunkUploadException(
            'Chunk $index upload failed',
            fileUuid: uuid,
            uploadKey: uploadKey,
            lastSuccessfulChunk: index - 1,
            originalError: e,
          );
        }

        offset += len;
        index++;
      }

      print('');

      byteSink.close();
      final totalHash =
          HEX.encode(digestSink.value?.bytes ?? []).toLowerCase();

      final metaJsonWithHash = json.encode({
        'name': name,
        'size': size,
        'mime': 'application/octet-stream',
        'key': fileKeyStr,
        'hash': totalHash,
        'lastModified': lastMod != null
            ? int.tryParse(lastMod) ?? DateTime.now().millisecondsSinceEpoch
            : DateTime.now().millisecondsSinceEpoch,
      });

      final nameEncrypted =
          await crypto.encryptMetadata002(name, fileKeyStr);
      final sizeEncrypted =
          await crypto.encryptMetadata002(size.toString(), fileKeyStr);
      final mimeEncrypted = await crypto.encryptMetadata002(
          'application/octet-stream', fileKeyStr);
      final metadataEncryptedWithHash =
          await crypto.encryptMetadata002(metaJsonWithHash, mk);
      final nameHashed =
          await crypto.hashFileName(name, masterKeys, email);

      await api.post('/v3/upload/done', {
        'uuid': uuid,
        'name': nameEncrypted,
        'nameHashed': nameHashed,
        'size': sizeEncrypted,
        'chunks': index,
        'mime': mimeEncrypted,
        'rm': rm,
        'metadata': metadataEncryptedWithHash,
        'version': 2,
        'uploadKey': uploadKey,
      });

      cache.invalidate(parent);
      return {'uuid': uuid, 'hash': totalHash, 'size': size.toString()};
    } finally {
      await raf.close();
    }
  }

  /// Batch upload with resume, conflict handling, and progress tracking.
  Future<void> upload(
    List<String> sources,
    String targetPath, {
    required bool recursive,
    required String onConflict,
    required bool preserveTimestamps,
    required List<String> include,
    required List<String> exclude,
    required String batchId,
    Map<String, dynamic>? initialBatchState,
    required Future<void> Function(Map<String, dynamic>) saveStateCallback,
    Function(String filename, int current, int total, int bytesUploaded,
            int totalBytes)?
        onFileProgress,
  }) async {
    api.log("Upload target path: $targetPath");

    Map<String, dynamic> batchState;
    List<dynamic> tasks;

    if (initialBatchState != null) {
      print("🔄 Resuming batch...");
      batchState = initialBatchState;
      tasks = batchState['tasks'] as List<dynamic>;
    } else {
      print("🔍 Building task list...");
      tasks = [];

      for (final sourceArg in sources) {
        if (sourceArg.contains('*') ||
            sourceArg.contains('?') ||
            sourceArg.contains('[')) {
          final glob = Glob(sourceArg.replaceAll('\\', '/'));
          await for (final entity in glob.list()) {
            await _processEntityForUpload(entity, sourceArg, targetPath,
                recursive, include, exclude, tasks, preserveTimestamps);
          }
        } else {
          final type = await FileSystemEntity.type(sourceArg);
          if (type == FileSystemEntityType.directory) {
            await _processEntityForUpload(
                Directory(sourceArg),
                sourceArg,
                targetPath,
                recursive,
                include,
                exclude,
                tasks,
                preserveTimestamps);
          } else if (type == FileSystemEntityType.file) {
            await _processEntityForUpload(File(sourceArg), sourceArg,
                targetPath, recursive, include, exclude, tasks, preserveTimestamps);
          } else {
            api.log("⚠️ Source not found: $sourceArg");
          }
        }
      }

      batchState = {
        'operationType': 'upload',
        'targetRemotePath': targetPath,
        'tasks': tasks,
      };
      await saveStateCallback(batchState);
      print("📝 Task list: ${tasks.length} files");
    }

    int successCount = 0;
    int skippedCount = 0;
    int errorCount = 0;
    int completedPreviously = 0;
    final totalTasks = tasks.length;

    for (int i = 0; i < totalTasks; i++) {
      final task = tasks[i] as Map<String, dynamic>;
      final localPath = task['localPath'] as String;
      final remotePath = task['remotePath'] as String;
      final status = task['status'] as String;
      final remoteName = p.basename(remotePath);

      final pct = totalTasks > 0
          ? ((i) / totalTasks * 100).toStringAsFixed(1)
          : '0.0';
      final width = 20;
      final filled =
          totalTasks > 0 ? ((i / totalTasks) * width).round() : 0;
      final bar = '█' * filled + '░' * (width - filled);

      if (!api.debugMode) {
        final shortName = remoteName.length > 20
            ? remoteName.substring(0, 17) + '...'
            : remoteName;
        stdout.write(
            '\rUp: ${shortName.padRight(20)} |$bar| ${i + 1}/$totalTasks ($pct%)  ');
      }

      if (status == 'completed') {
        completedPreviously++;
        if (i == totalTasks - 1 && !api.debugMode) stdout.write('\n');
        continue;
      }
      if (status.startsWith('skipped')) {
        skippedCount++;
        continue;
      }

      final localFile = File(localPath);
      if (!await localFile.exists()) {
        skippedCount++;
        task['status'] = 'skipped_missing';
        await saveStateCallback(batchState);
        continue;
      }

      final remoteParentPath =
          p.dirname(remotePath).replaceAll('\\', '/');
      Map<String, dynamic> parentInfo;
      try {
        parentInfo = await drive.createFolderRecursive(remoteParentPath);
      } catch (e) {
        errorCount++;
        task['status'] = 'error_parent';
        continue;
      }

      bool shouldUpload = true;
      if (task['fileUuid'] == null) {
        final cachedFiles = cache.fileCache[parentInfo['uuid']]?.items;
        bool exists = false;
        if (cachedFiles != null) {
          exists =
              (cachedFiles as List).any((f) => f['name'] == remoteName);
        } else {
          exists =
              await drive.checkFileExists(parentInfo['uuid'], remoteName);
        }

        if (exists && onConflict == 'skip') {
          skippedCount++;
          task['status'] = 'skipped_conflict';
          await saveStateCallback(batchState);
          shouldUpload = false;
        }
      }

      if (!shouldUpload) continue;

      final fileSize = await localFile.length();
      await memoryGate.acquire(fileSize);

      try {
        String? cTime, mTime;
        if (preserveTimestamps) {
          final stat = await localFile.stat();
          mTime = stat.modified.millisecondsSinceEpoch.toString();
          cTime = stat.changed.millisecondsSinceEpoch.toString();
        }

        task['status'] = 'uploading';
        await saveStateCallback(batchState);

        await uploadFileChunked(
          localFile,
          parentInfo['uuid'],
          fileUuid: task['fileUuid'],
          resumeUploadKey: task['uploadKey'],
          resumeFromChunk: (task['lastChunk'] ?? -1) + 1,
          creationTime: cTime,
          modificationTime: mTime,
          onUploadStart: (uuid, key) {
            task['fileUuid'] = uuid;
            task['uploadKey'] = key;
            task['lastChunk'] = -1;
            saveStateCallback(batchState);
          },
          onProgress: (cur, tot, bUp, bTot) {
            task['lastChunk'] = cur - 1;
          },
        );

        successCount++;
        task['status'] = 'completed';
        task['fileUuid'] = null;
        task['uploadKey'] = null;
        task['lastChunk'] = -1;
      } catch (e) {
        if (api.debugMode) print("\n❌ Upload error: $e");
        errorCount++;
        task['status'] = 'interrupted';
      } finally {
        memoryGate.release(fileSize);
      }

      await saveStateCallback(batchState);
    }

    if (!api.debugMode) stdout.write('\n');

    print('=' * 40);
    print('📊 Upload Summary:');
    if (completedPreviously > 0) print('  ✅ Previous: $completedPreviously');
    print('  ✅ Uploaded: $successCount');
    print('  ⏭️  Skipped: $skippedCount');
    print('  ❌ Errors: $errorCount');
    print('=' * 40);

    if (errorCount > 0) throw Exception("Upload finished with errors");
  }

  Future<void> _processEntityForUpload(
      FileSystemEntity entity,
      String sourceBase,
      String targetPath,
      bool recursive,
      List<String> include,
      List<String> exclude,
      List<dynamic> tasks,
      bool preserveTimestamps) async {
    if (entity is Directory) {
      if (!recursive) {
        api.log("Skipping directory: ${entity.path}");
        return;
      }

      final localDir = Directory(entity.path);
      String remoteBase;
      if (sourceBase.endsWith(Platform.pathSeparator) ||
          sourceBase == '.' ||
          sourceBase == './') {
        remoteBase = targetPath;
      } else {
        remoteBase = p
            .join(targetPath, p.basename(localDir.path))
            .replaceAll('\\', '/');
      }

      await drive.createFolderRecursive(remoteBase);

      await for (final fileEntity
          in localDir.list(recursive: true, followLinks: false)) {
        if (fileEntity is File) {
          final relPath =
              p.relative(fileEntity.path, from: localDir.path);
          final remotePath =
              p.join(remoteBase, relPath).replaceAll('\\', '/');

          if (shouldIncludeFile(
              p.basename(fileEntity.path), include, exclude)) {
            tasks.add({
              'localPath': fileEntity.path,
              'remotePath': remotePath,
              'status': 'pending',
              'fileUuid': null,
              'uploadKey': null,
              'lastChunk': -1,
            });
          }
        }
      }
    } else if (entity is File) {
      final remotePath =
          p.join(targetPath, p.basename(entity.path)).replaceAll('\\', '/');
      if (shouldIncludeFile(p.basename(entity.path), include, exclude)) {
        tasks.add({
          'localPath': entity.path,
          'remotePath': remotePath,
          'status': 'pending',
          'fileUuid': null,
          'uploadKey': null,
          'lastChunk': -1,
        });
      }
    }
  }

  /// Simple single-file upload (non-chunked, for small files / WebDAV).
  Future<void> uploadFile(File file, String parent,
      {String? creationTime, String? modificationTime}) async {
    await uploadFileChunked(file, parent,
        creationTime: creationTime, modificationTime: modificationTime);
  }

  /// Upload raw bytes from memory (needed for Web platform where File I/O
  /// is not available).
  Future<void> uploadBytes(
    Uint8List data,
    String fileName,
    String parentUuid, {
    Function(int bytesUploaded, int totalBytes)? onProgress,
  }) async {
    api.log('Starting memory upload for $fileName (${formatSize(data.length)})');

    final size = data.length;
    final uuid = crypto.uuid();
    final mk = masterKeys.last;
    if (mk.isEmpty) throw Exception('No master keys available');

    final fileKeyStr = crypto.randomString(32);
    final fileKeyBytes = Uint8List.fromList(utf8.encode(fileKeyStr));

    if (size == 0) {
      final metaJson = json.encode({
        'name': fileName,
        'size': 0,
        'mime': 'application/octet-stream',
        'key': fileKeyStr,
        'hash': '',
        'lastModified': DateTime.now().millisecondsSinceEpoch,
      });

      final nameEncrypted =
          await crypto.encryptMetadata002(fileName, fileKeyStr);
      final sizeEncrypted =
          await crypto.encryptMetadata002('0', fileKeyStr);
      final mimeEncrypted = await crypto.encryptMetadata002(
          'application/octet-stream', fileKeyStr);
      final metadataEncrypted =
          await crypto.encryptMetadata002(metaJson, mk);
      final nameHashed =
          await crypto.hashFileName(fileName, masterKeys, email);

      await api.post('/v3/upload/empty', {
        'uuid': uuid,
        'name': nameEncrypted,
        'nameHashed': nameHashed,
        'size': sizeEncrypted,
        'parent': parentUuid,
        'mime': mimeEncrypted,
        'metadata': metadataEncrypted,
        'version': 2,
      });

      if (onProgress != null) onProgress(0, 0);
      cache.invalidate(parentUuid);
      return;
    }

    final uploadKey = crypto.randomString(32);
    final rm = crypto.randomString(32);
    const chunkSz = 1048576;
    final totalChunks = (size / chunkSz).ceil();
    final ingest = 'https://ingest.filen.io';

    int offset = 0;
    int index = 0;

    final digestSink = DigestSink();
    final byteSink = crypto_pkg.sha512.startChunkedConversion(digestSink);

    while (offset < size) {
      final end = min(size, offset + chunkSz);
      final chunkBytes = data.sublist(offset, end);
      byteSink.add(chunkBytes);

      final encChunk = await crypto.encryptData(chunkBytes, fileKeyBytes);
      final chunkHash = crypto_pkg.sha512.convert(encChunk);
      final hashHex = HEX.encode(chunkHash.bytes).toLowerCase();

      final url = Uri.parse(
          '$ingest/v3/upload?uuid=$uuid&index=$index&parent=$parentUuid&uploadKey=$uploadKey&hash=$hashHex');

      int retry = 0;
      while (retry < 3) {
        try {
          final r = await http
              .post(url,
                  body: encChunk,
                  headers: {'Authorization': 'Bearer ${api.apiKey}'})
              .timeout(Duration(seconds: 45));
          if (r.statusCode != 200) {
            throw Exception('Status ${r.statusCode}: ${r.body}');
          }
          break;
        } catch (e) {
          retry++;
          api.log('Chunk failed (Attempt $retry): $e');
          if (retry >= 3) rethrow;
          await Future.delayed(Duration(seconds: 1));
        }
      }

      offset += chunkBytes.length;
      index++;
      if (onProgress != null) onProgress(offset, size);
    }

    byteSink.close();
    final totalHash =
        HEX.encode(digestSink.value?.bytes ?? []).toLowerCase();

    final metaJsonWithHash = json.encode({
      'name': fileName,
      'size': size,
      'mime': 'application/octet-stream',
      'key': fileKeyStr,
      'hash': totalHash,
      'lastModified': DateTime.now().millisecondsSinceEpoch,
    });

    final nameEncrypted =
        await crypto.encryptMetadata002(fileName, fileKeyStr);
    final sizeEncrypted =
        await crypto.encryptMetadata002(size.toString(), fileKeyStr);
    final mimeEncrypted = await crypto.encryptMetadata002(
        'application/octet-stream', fileKeyStr);
    final metadataEncryptedWithHash =
        await crypto.encryptMetadata002(metaJsonWithHash, mk);
    final nameHashed =
        await crypto.hashFileName(fileName, masterKeys, email);

    await api.post('/v3/upload/done', {
      'uuid': uuid,
      'name': nameEncrypted,
      'nameHashed': nameHashed,
      'size': sizeEncrypted,
      'chunks': index,
      'mime': mimeEncrypted,
      'rm': rm,
      'metadata': metadataEncryptedWithHash,
      'version': 2,
      'uploadKey': uploadKey,
    });

    cache.invalidate(parentUuid);
  }
}
