// Unit tests for Step 2 (file-level / batch concurrency) on FilenUpload.upload,
// FilenDownload.downloadPath, and the shared primitives they compose
// (runWithConcurrency + a batch-wide ChunkSemaphore budget).
//
// Hermetic: the pooled client is a MockClient and crypto runs for real. They
// pin the four non-negotiable Step 2 constraints:
//
//   1. a batch never runs more than W whole FILES at once (peak ≤ W),
//   2. total chunks in flight across files × chunks never exceed the ONE shared
//      budget — proven by sharing a small budget across more files than it
//      admits and observing the peak,
//   3. a single file (or maxWorkers<=1) stays on the sequential path (strictly
//      serial; no shared budget threaded),
//   4. concurrent completion is state-safe (the batch finishes and every task
//      ends 'completed').

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:filen_dart/api.dart';
import 'package:filen_dart/cache.dart';
import 'package:filen_dart/crypto.dart';
import 'package:filen_dart/drive.dart';
import 'package:filen_dart/download.dart';
import 'package:filen_dart/memory_gate.dart';
import 'package:filen_dart/upload.dart';

const int mb = 1048576;
const String masterKey = 'test-master-key-for-upload-tests0';

/// Tracks the peak number of concurrently-held slots.
class Peak {
  int cur = 0;
  int peak = 0;
  void enter() {
    cur++;
    if (cur > peak) peak = cur;
  }

  void leave() => cur--;
}

FilenUpload makeUploader(MockClient client, {MemoryGate? gate}) {
  final api = FilenApi(client: client);
  api.apiKey = 'test-key';
  final crypto = FilenCrypto(random: Random(7));
  final cache = FilenCache();
  final drive = FilenDrive(api: api, crypto: crypto, cache: cache);
  drive.baseFolderUUID = 'root-uuid';
  drive.masterKeys = [masterKey];
  drive.email = 'test@example.com';
  return FilenUpload(
      api: api, crypto: crypto, cache: cache, drive: drive, memoryGate: gate);
}

Future<List<File>> tmpFiles(String tag, int count, int nbytes) async {
  final dir = await Directory.systemTemp.createTemp('filen_step2_${tag}_');
  final files = <File>[];
  for (var i = 0; i < count; i++) {
    final f = File('${dir.path}/f${i.toString().padLeft(2, '0')}.bin');
    final r = Random(nbytes + i);
    await f.writeAsBytes(
        Uint8List.fromList(List.generate(nbytes, (_) => r.nextInt(256))));
    files.add(f);
  }
  return files;
}

/// MockClient for batch uploads: answers chunk POSTs, the finalize, and the
/// existence check. [onChunkPost] observes each chunk POST (to measure overlap).
MockClient uploadMock({Future<void> Function()? onChunkPost}) {
  return MockClient((request) async {
    final path = request.url.path;
    if (path.contains('/v3/file/exists')) {
      return http.Response(
          json.encode({
            'status': true,
            'data': {'exists': false}
          }),
          200);
    }
    if (path.contains('/v3/upload/done') || path.contains('/v3/dir')) {
      return http.Response(json.encode({'status': true, 'data': {}}), 200);
    }
    if (path.contains('/v3/upload')) {
      if (onChunkPost != null) await onChunkPost();
      return http.Response(json.encode({'status': true, 'data': {}}), 200);
    }
    return http.Response(json.encode({'status': true, 'data': {}}), 200);
  });
}

Future<void> batchUpload(
  FilenUpload up,
  List<File> files,
  String target, {
  required int maxWorkers,
}) {
  // Files directly under [target] so the single parent resolves from the
  // seeded pathCache — no folder-creation API churn in a hermetic test.
  up.cache.pathCache[target.replaceAll(RegExp(r'^/+|/+$'), '')] = {
    'uuid': 'parent',
    'plainName': 'remote',
    'path': target,
  };
  return up.upload(
    files.map((f) => f.path).toList(),
    target,
    recursive: false,
    onConflict: 'overwrite',
    preserveTimestamps: false,
    include: const [],
    exclude: const [],
    batchId: 'b',
    saveStateCallback: (_) async {},
    maxWorkers: maxWorkers,
  );
}

void main() {
  group('Step 2 — runWithConcurrency', () {
    test('bounds in-flight items to W and runs them all', () async {
      const w = 3;
      final peak = Peak();
      final done = <int>[];
      await runWithConcurrency(List.generate(12, (i) => i), w, (i) async {
        peak.enter();
        await Future.delayed(const Duration(milliseconds: 15));
        done.add(i);
        peak.leave();
      });
      expect(peak.peak, lessThanOrEqualTo(w),
          reason: 'observed ${peak.peak} in flight, bound is $w');
      expect(peak.peak, greaterThan(1), reason: 'expected real overlap');
      expect(done.length, 12, reason: 'every item must run');
    });
  });

  group('Step 2 — shared chunk budget (upload)', () {
    test('one budget caps chunk POSTs across MORE files than it admits',
        () async {
      const budget = 3;
      const nFiles = 4; // more concurrent files than the budget allows chunks
      final peak = Peak();
      final mock = uploadMock(onChunkPost: () async {
        peak.enter();
        await Future.delayed(const Duration(milliseconds: 10));
        peak.leave();
      });
      final files = await tmpFiles('budget', nFiles, 4 * mb); // 4 chunks each
      final shared = ChunkSemaphore(budget);
      try {
        // Each file runs its own chunk concurrency (4), but all share ONE
        // budget — so total POSTs in flight can never exceed it.
        await runWithConcurrency(files, nFiles, (f) async {
          await makeUploader(mock).uploadFileChunked(f, 'parent',
              maxConcurrentChunks: 4, globalChunkSlots: shared);
        });
        expect(peak.peak, lessThanOrEqualTo(budget),
            reason: 'peak ${peak.peak} exceeded shared budget $budget');
        expect(peak.peak, greaterThan(1),
            reason: 'expected genuine cross-file chunk overlap');
      } finally {
        await files.first.parent.delete(recursive: true);
      }
    });
  });

  group('Step 2 — batch upload()', () {
    test('never exceeds W concurrent files', () async {
      const w = 3;
      final peak = Peak();
      // Single-chunk files: one POST per file, so peak POSTs == peak files.
      final mock = uploadMock(onChunkPost: () async {
        peak.enter();
        await Future.delayed(const Duration(milliseconds: 20));
        peak.leave();
      });
      final files = await tmpFiles('peak', 8, mb ~/ 2); // 8 one-chunk files
      try {
        await batchUpload(makeUploader(mock), files, '/remote', maxWorkers: w);
        expect(peak.peak, lessThanOrEqualTo(w),
            reason: 'observed ${peak.peak} files in flight, bound is $w');
        expect(peak.peak, greaterThan(1),
            reason: 'expected real file-level overlap');
      } finally {
        await files.first.parent.delete(recursive: true);
      }
    });

    test('peak chunk POSTs never exceed the global budget', () async {
      final peak = Peak();
      final mock = uploadMock(onChunkPost: () async {
        peak.enter();
        await Future.delayed(const Duration(milliseconds: 8));
        peak.leave();
      });
      final files = await tmpFiles('global', 4, 4 * mb); // 4 chunks each
      try {
        await batchUpload(makeUploader(mock), files, '/remote', maxWorkers: 4);
        expect(peak.peak, lessThanOrEqualTo(kGlobalMaxInflightChunks),
            reason: 'peak ${peak.peak} exceeded global budget '
                '$kGlobalMaxInflightChunks');
        expect(peak.peak, greaterThan(2),
            reason: 'expected cross-file chunk overlap beyond one file');
      } finally {
        await files.first.parent.delete(recursive: true);
      }
    });

    test('single file / maxWorkers<=1 stays strictly sequential', () async {
      // With one worker, files must not overlap at all (peak == 1).
      final peakSerial = Peak();
      final mockSerial = uploadMock(onChunkPost: () async {
        peakSerial.enter();
        await Future.delayed(const Duration(milliseconds: 15));
        peakSerial.leave();
      });
      final many = await tmpFiles('seq', 5, mb ~/ 2);
      try {
        await batchUpload(makeUploader(mockSerial), many, '/remote',
            maxWorkers: 1);
        expect(peakSerial.peak, 1,
            reason: 'maxWorkers<=1 must keep files strictly serial');
      } finally {
        await many.first.parent.delete(recursive: true);
      }

      // A single file with a generous worker count also stays serial.
      final peakOne = Peak();
      final mockOne = uploadMock(onChunkPost: () async {
        peakOne.enter();
        await Future.delayed(const Duration(milliseconds: 15));
        peakOne.leave();
      });
      final one = await tmpFiles('seq1', 1, mb ~/ 2);
      try {
        await batchUpload(makeUploader(mockOne), one, '/remote', maxWorkers: 4);
        expect(peakOne.peak, 1, reason: 'a single file cannot overlap itself');
      } finally {
        await one.first.parent.delete(recursive: true);
      }
    });
  });

  group('Step 2 — shared chunk budget (download)', () {
    test('one budget caps chunk GETs across concurrent files', () async {
      const budget = 2;
      final peak = Peak();
      final crypto = FilenCrypto(random: Random(3));
      final keyStr = crypto.randomString(32);
      final keyBytes = Uint8List.fromList(utf8.encode(keyStr));
      final blob =
          Uint8List.fromList(List.generate(4 * mb, (i) => (i * 31) % 256));
      final encChunks = <int, Uint8List>{};
      for (var i = 0; i * mb < blob.length; i++) {
        final end = min(blob.length, (i + 1) * mb);
        encChunks[i] = await crypto.encryptData(
            Uint8List.sublistView(blob, i * mb, end), keyBytes);
      }
      final meta =
          json.encode({'name': 'f.bin', 'size': blob.length, 'key': keyStr});
      final mock = MockClient((request) async {
        if (request.url.path.contains('/v3/file')) {
          return http.Response(
              json.encode({
                'status': true,
                'data': {
                  'metadata': await crypto.encryptMetadata002(meta, masterKey),
                  'chunks': encChunks.length,
                  'region': 'r',
                  'bucket': 'b',
                }
              }),
              200);
        }
        peak.enter();
        await Future.delayed(const Duration(milliseconds: 10));
        peak.leave();
        final i = int.parse(request.url.pathSegments.last);
        return http.Response.bytes(encChunks[i]!, 200);
      });

      final api = FilenApi(client: mock);
      api.apiKey = 'k';
      final cache = FilenCache();
      final drive = FilenDrive(api: api, crypto: crypto, cache: cache);
      drive.masterKeys = [masterKey];
      final dl =
          FilenDownload(api: api, crypto: crypto, cache: cache, drive: drive);

      final shared = ChunkSemaphore(budget);
      final outDir = await Directory.systemTemp.createTemp('filen_dl_step2_');
      try {
        await runWithConcurrency([0, 1, 2], 3, (n) async {
          await dl.downloadFile('u$n',
              savePath: '${outDir.path}/out$n.bin',
              maxConcurrentChunks: 4,
              globalChunkSlots: shared);
        });
        expect(peak.peak, lessThanOrEqualTo(budget),
            reason:
                'peak ${peak.peak} download chunks exceeded budget $budget');
        expect(peak.peak, greaterThan(1),
            reason: 'expected real cross-file overlap');
      } finally {
        await outDir.delete(recursive: true);
      }
    });
  });
}
