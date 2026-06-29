@Tags(['live'])
@Timeout(Duration(minutes: 6)) // real multi-MB transfers exceed the 30s default
// Live integration tests for Step 1 (bounded chunk concurrency) against the
// real Filen backend. Authenticate via FILEN_EMAIL/PASSWORD or a saved CLI
// session (~/.filen-cli/credentials.json). All work is confined to a unique
// test folder and cleaned up.
//
// Covers the live half of the Step 1 matrix:
//   - round-trip a large multi-chunk file (10 MB): hash + byte-exact content,
//   - an interrupted upload resumes (resume-as-a-set) and completes,
//   - concurrent upload of a large file beats the sequential baseline,
//   - a directory of many small files round-trips through the batch path.
//
// Run with: dart test --tags live --run-skipped test/concurrency_live_test.dart

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:http/http.dart' as http;
import 'package:crypto/crypto.dart' as crypto_pkg;
import 'package:hex/hex.dart';
import 'package:path/path.dart' as p;

import 'package:filen_dart/filen_client.dart';

import 'live_support.dart';

const int mb = 1048576;

String sha512Hex(List<int> bytes) =>
    HEX.encode(crypto_pkg.sha512.convert(bytes).bytes).toLowerCase();

Future<File> randomFile(String path, int nbytes) async {
  final r = Random(nbytes);
  final f = File(path);
  await f.writeAsBytes(
      Uint8List.fromList(List.generate(nbytes, (_) => r.nextInt(256))));
  return f;
}

/// Delegates to a real client but throws once, on the [failAtPost]-th matching
/// ingest chunk POST — to simulate a mid-upload network failure.
class FlakyClient extends http.BaseClient {
  final http.Client _inner = http.Client();
  final int failAtPost;
  int _posts = 0;

  FlakyClient({required this.failAtPost});

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    final isChunk = request.method == 'POST' &&
        request.url.path.contains('/v3/upload') &&
        !request.url.path.contains('/v3/upload/done');
    if (isChunk) {
      _posts++;
      if (_posts == failAtPost) {
        throw const SocketException('simulated mid-upload failure');
      }
    }
    return _inner.send(request);
  }

  @override
  void close() => _inner.close();
}

/// Build a live client backed by [httpClient], reusing the saved CLI session
/// (apiKey + master keys, no password needed).
FilenClient liveClientWith(http.Client httpClient) {
  final tempDir = Directory.systemTemp.createTempSync('filen_live_conc_');
  final client = FilenClient(
      config: ConfigService(configPath: tempDir.path), httpClient: httpClient);
  final file = File(savedCredentialsPath());
  final creds = json.decode(file.readAsStringSync()) as Map<String, dynamic>;
  client.setAuth(creds);
  return client;
}

void main() {
  if (!liveCredentialsAvailable()) {
    test('SKIPPED: no live credentials', () {},
        skip: 'Set FILEN_EMAIL/FILEN_PASSWORD or provide a saved CLI session');
    return;
  }

  late FilenClient client;
  late String folderPath;
  late String folderUuid;
  late Directory tmp;

  setUpAll(() async {
    client = await authenticateForLiveTest();
    folderPath =
        '/__test_filen_dart_concurrency__/${DateTime.now().millisecondsSinceEpoch}';
    final folder = await client.createFolderRecursive(folderPath);
    folderUuid = folder['uuid'];
    tmp = Directory.systemTemp.createTempSync('filen_conc_live_');
  });

  tearDownAll(() async {
    for (final path in [folderPath, '/__test_filen_dart_concurrency__']) {
      try {
        final resolved = await client.resolvePath(path);
        await client.trashItem(resolved['uuid'], 'folder');
        await client.deletePermanently(resolved['uuid'], 'folder');
      } catch (e) {
        print('cleanup warning for $path: $e');
      }
    }
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('large multi-chunk file round-trips byte-exactly', () async {
    final up = await randomFile('${tmp.path}/large.bin', 10 * mb + 4321);
    final originalHash = sha512Hex(await up.readAsBytes());

    final result =
        await client.uploadFileChunked(up, folderUuid, maxConcurrentChunks: 4);
    // The returned whole-file hash is the in-order plaintext SHA-512.
    expect(result['hash'], originalHash);

    final downPath = '${tmp.path}/large.down.bin';
    await client.downloadFile(result['uuid']!,
        savePath: downPath, maxConcurrentChunks: 4);
    expect(sha512Hex(await File(downPath).readAsBytes()), originalHash,
        reason: 'downloaded content must be byte-exact');
  });

  test('interrupted upload resumes (resume-as-a-set) and completes', () async {
    final up = await randomFile('${tmp.path}/resume.bin', 6 * mb + 50);
    final originalHash = sha512Hex(await up.readAsBytes());

    // A flaky client fails the 3rd chunk POST. Sequential (N=1) makes the
    // failure point deterministic: chunks 0,1 land, chunk 2 fails.
    final flaky = liveClientWith(FlakyClient(failAtPost: 3));
    late ChunkUploadException caught;
    try {
      await flaky.uploadFileChunked(up, folderUuid, maxConcurrentChunks: 1);
      fail('expected a ChunkUploadException');
    } on ChunkUploadException catch (e) {
      caught = e;
    }
    expect(caught.completedChunks, isNotEmpty);
    expect(caught.fileKey, isNotNull, reason: 'resume must carry the file key');

    // Resume on the healthy client: reuse uuid/key/fileKey, skip the completed
    // set, finish the rest concurrently.
    final result = await client.uploadFileChunked(
      up,
      folderUuid,
      fileUuid: caught.fileUuid,
      resumeUploadKey: caught.uploadKey,
      fileKey: caught.fileKey,
      completedChunks: caught.completedChunks,
      maxConcurrentChunks: 4,
    );
    expect(result['hash'], originalHash);

    final downPath = '${tmp.path}/resume.down.bin';
    await client.downloadFile(result['uuid']!, savePath: downPath);
    expect(sha512Hex(await File(downPath).readAsBytes()), originalHash,
        reason: 'resumed upload must reassemble byte-exactly');
  });

  test('concurrent upload beats the sequential baseline', () async {
    final up = await randomFile('${tmp.path}/speed.bin', 16 * mb);

    final t0 = DateTime.now();
    final seq =
        await client.uploadFileChunked(up, folderUuid, maxConcurrentChunks: 1);
    final seqMs = DateTime.now().difference(t0).inMilliseconds;

    final t1 = DateTime.now();
    final par =
        await client.uploadFileChunked(up, folderUuid, maxConcurrentChunks: 8);
    final parMs = DateTime.now().difference(t1).inMilliseconds;

    print('[throughput] sequential=${seqMs}ms  concurrent(8)=${parMs}ms  '
        'speedup=${(seqMs / parMs).toStringAsFixed(2)}x');
    expect(seq['hash'], par['hash']);
    expect(parMs, lessThan(seqMs),
        reason: 'concurrent upload should beat the sequential baseline');
  });

  test('directory of many small files round-trips', () async {
    final src = Directory('${tmp.path}/manyfiles')..createSync();
    final expected = <String, String>{};
    for (var i = 0; i < 12; i++) {
      final name = 'small_${i.toString().padLeft(2, '0')}.txt';
      final content = utf8.encode('file $i ' * (50 + i));
      File('${src.path}/$name').writeAsBytesSync(content);
      expected[name] = sha512Hex(content);
    }

    final remoteDir = '$folderPath/manyfiles_upload';
    Future<void> noop(Map<String, dynamic> _) async {}
    await client.upload(
      [src.path],
      remoteDir,
      recursive: true,
      onConflict: 'overwrite',
      preserveTimestamps: false,
      include: const [],
      exclude: const [],
      batchId: 'conc-live',
      saveStateCallback: noop,
    );

    final dest = Directory('${tmp.path}/manyfiles_down')..createSync();
    await client.downloadPath(
      '$remoteDir/manyfiles',
      localDestination: dest.path,
      recursive: true,
      onConflict: 'overwrite',
      preserveTimestamps: false,
      include: const [],
      exclude: const [],
      batchId: 'conc-live-down',
      saveStateCallback: noop,
    );

    final got = <String, String>{};
    for (final e in dest.listSync(recursive: true)) {
      if (e is File) got[p.basename(e.path)] = sha512Hex(e.readAsBytesSync());
    }
    for (final entry in expected.entries) {
      expect(got.containsKey(entry.key), isTrue,
          reason: '${entry.key} missing from download');
      expect(got[entry.key], entry.value,
          reason: '${entry.key} content mismatch');
    }
  });

  // --- Step 2: file-level (batch) concurrency ----------------------------

  test('batch concurrent upload beats the W=1 baseline', () async {
    // Many smallish files: per-file connection/finalize overhead dominates, so
    // overlapping whole files should clearly beat the sequential baseline.
    final src = Directory('${tmp.path}/speed_batch')..createSync();
    for (var i = 0; i < 16; i++) {
      await randomFile(
          '${src.path}/f${i.toString().padLeft(2, '0')}.bin', 256 * 1024);
    }
    Future<void> noop(Map<String, dynamic> _) async {}

    final t0 = DateTime.now();
    await client.upload([src.path], '$folderPath/batch_seq',
        recursive: true,
        onConflict: 'overwrite',
        preserveTimestamps: false,
        include: const [],
        exclude: const [],
        batchId: 'batch-seq',
        saveStateCallback: noop,
        maxWorkers: 1);
    final seqMs = DateTime.now().difference(t0).inMilliseconds;

    final t1 = DateTime.now();
    await client.upload([src.path], '$folderPath/batch_par',
        recursive: true,
        onConflict: 'overwrite',
        preserveTimestamps: false,
        include: const [],
        exclude: const [],
        batchId: 'batch-par',
        saveStateCallback: noop,
        maxWorkers: 6);
    final parMs = DateTime.now().difference(t1).inMilliseconds;

    print('[batch throughput] sequential=${seqMs}ms  concurrent(6)=${parMs}ms  '
        'speedup=${(seqMs / parMs).toStringAsFixed(2)}x');
    expect(parMs, lessThan(seqMs),
        reason: 'concurrent batch upload should beat the sequential baseline');
  });

  test('interrupted batch resumes with concurrent files in flight', () async {
    // A directory of multi-chunk files uploaded concurrently; one chunk POST
    // fails mid-flight, interrupting a file. Resuming the batch (several files
    // still in flight) must complete and round-trip byte-exact.
    final src = Directory('${tmp.path}/resume_batch')..createSync();
    final expected = <String, String>{};
    for (var i = 0; i < 5; i++) {
      final name = 'r${i.toString().padLeft(2, '0')}.bin';
      final f = await randomFile('${src.path}/$name', 3 * mb + 7); // 4 chunks
      expected[name] = sha512Hex(await f.readAsBytes());
    }
    final remoteDir = '$folderPath/resume_batch_up';

    Map<String, dynamic>? savedState;
    Future<void> capture(Map<String, dynamic> s) async {
      savedState = json.decode(json.encode(s)) as Map<String, dynamic>;
    }

    // Fail the 3rd chunk POST (mid-batch). The flaky client shares the saved
    // session, so the interrupted state is persisted via [capture].
    final flaky = liveClientWith(FlakyClient(failAtPost: 3));
    try {
      await flaky.upload([src.path], remoteDir,
          recursive: true,
          onConflict: 'overwrite',
          preserveTimestamps: false,
          include: const [],
          exclude: const [],
          batchId: 'resume-batch',
          saveStateCallback: capture,
          maxWorkers: 4);
      fail('expected the interrupted batch to throw');
    } catch (_) {
      // expected — at least one file was interrupted
    }

    expect(savedState, isNotNull, reason: 'state must have been persisted');
    final statuses = [
      for (final t in savedState!['tasks'] as List) t['status'] as String
    ];
    expect(
        statuses.any((s) => s == 'interrupted' || s == 'error_upload'), isTrue,
        reason: 'expected an interrupted task, got $statuses');

    // Resume the batch on the healthy client with concurrency.
    await client.upload([src.path], remoteDir,
        recursive: true,
        onConflict: 'skip',
        preserveTimestamps: false,
        include: const [],
        exclude: const [],
        batchId: 'resume-batch',
        initialBatchState: savedState,
        saveStateCallback: capture,
        maxWorkers: 4);

    // Download and verify every file is byte-exact.
    final dest = Directory('${tmp.path}/resume_batch_down')..createSync();
    Future<void> noop(Map<String, dynamic> _) async {}
    await client.downloadPath('$remoteDir/resume_batch',
        localDestination: dest.path,
        recursive: true,
        onConflict: 'overwrite',
        preserveTimestamps: false,
        include: const [],
        exclude: const [],
        batchId: 'resume-batch-down',
        saveStateCallback: noop,
        maxWorkers: 4);

    final got = <String, String>{};
    for (final e in dest.listSync(recursive: true)) {
      if (e is File) got[p.basename(e.path)] = sha512Hex(e.readAsBytesSync());
    }
    for (final entry in expected.entries) {
      expect(got.containsKey(entry.key), isTrue,
          reason: '${entry.key} missing after resume');
      expect(got[entry.key], entry.value,
          reason: '${entry.key} content mismatch after resume');
    }
  });
}
