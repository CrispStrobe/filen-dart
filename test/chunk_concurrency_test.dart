// Unit tests for Step 1 (bounded chunk concurrency) on the upload + download
// paths. Hermetic: the pooled client is a MockClient and crypto runs for real
// (so the whole-file hash is a true SHA-512). They pin the three constraints:
//
//   1. in-order hashing  — a parallel multi-chunk upload yields the SAME
//      whole-file SHA-512 as the sequential path,
//   2. resume-as-a-set   — restart skips exactly the completed indices and
//      retries only the gaps (out-of-order completion safe),
//   3. bound by count + bytes — the pool never exceeds N concurrent chunks and
//      the MemoryGate blocks once the byte budget is full,
//
// plus: tiny files stay sequential (no MemoryGate touched), and a concurrent
// download reassembles byte-exactly.

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:crypto/crypto.dart' as crypto_pkg;
import 'package:hex/hex.dart';

import 'package:filen_client/api.dart';
import 'package:filen_client/cache.dart';
import 'package:filen_client/crypto.dart';
import 'package:filen_client/drive.dart';
import 'package:filen_client/download.dart';
import 'package:filen_client/memory_gate.dart';
import 'package:filen_client/upload.dart';

const int mb = 1048576;

int indexOf(Uri url) => int.parse(url.queryParameters['index']!);

FilenUpload makeUploader(MockClient client, {MemoryGate? gate}) {
  final api = FilenApi(client: client);
  api.apiKey = 'test-key';
  final crypto = FilenCrypto(random: Random(7));
  final cache = FilenCache();
  final drive = FilenDrive(api: api, crypto: crypto, cache: cache);
  drive.baseFolderUUID = 'root-uuid';
  drive.masterKeys = ['test-master-key-for-upload-tests0'];
  drive.email = 'test@example.com';
  return FilenUpload(
      api: api, crypto: crypto, cache: cache, drive: drive, memoryGate: gate);
}

Future<File> tmpFile(String name, int nbytes) async {
  final f = File('${Directory.systemTemp.path}/filen_conc_$name');
  final r = Random(nbytes);
  await f.writeAsBytes(
      Uint8List.fromList(List.generate(nbytes, (_) => r.nextInt(256))));
  return f;
}

/// A MockClient that answers /v3/upload chunk POSTs and the /v3/upload/done
/// finalize. [onChunkPost] can observe/alter behaviour per chunk index.
MockClient uploadMock({
  Future<void> Function(int index)? onChunkPost,
  Set<int>? failOn,
}) {
  return MockClient((request) async {
    final path = request.url.path;
    if (path.contains('/v3/upload/done') || path.contains('/v3/dir')) {
      return http.Response(json.encode({'status': true, 'data': {}}), 200);
    }
    if (path.contains('/v3/upload')) {
      final idx = indexOf(request.url);
      if (onChunkPost != null) await onChunkPost(idx);
      if (failOn != null && failOn.contains(idx)) {
        return http.Response('boom', 500);
      }
      return http.Response(json.encode({'status': true, 'data': {}}), 200);
    }
    return http.Response(json.encode({'status': true, 'data': {}}), 200);
  });
}

void main() {
  group('Step 1 — in-order hashing', () {
    test('parallel upload yields the same SHA-512 as sequential', () async {
      final file = await tmpFile('hash.bin', 5 * mb + 321); // 6 chunks
      final bytes = await file.readAsBytes();
      final expected =
          HEX.encode(crypto_pkg.sha512.convert(bytes).bytes).toLowerCase();
      try {
        final seq = await makeUploader(uploadMock())
            .uploadFileChunked(file, 'parent', maxConcurrentChunks: 1);
        final par = await makeUploader(uploadMock())
            .uploadFileChunked(file, 'parent', maxConcurrentChunks: 4);
        expect(seq['hash'], expected);
        expect(par['hash'], expected,
            reason: 'parallel hash must equal the sequential whole-file hash');
      } finally {
        await file.delete();
      }
    });
  });

  group('Step 1 — bounded pool', () {
    test('never exceeds N concurrent chunks in flight', () async {
      const n = 3;
      var cur = 0, peak = 0;
      final mock = uploadMock(onChunkPost: (_) async {
        cur++;
        peak = max(peak, cur);
        await Future.delayed(const Duration(milliseconds: 15));
        cur--;
      });
      final file = await tmpFile('peak.bin', 10 * mb); // 10 chunks
      try {
        await makeUploader(mock)
            .uploadFileChunked(file, 'parent', maxConcurrentChunks: n);
        expect(peak, lessThanOrEqualTo(n),
            reason: 'observed peak $peak exceeded the bound $n');
        expect(peak, greaterThan(1), reason: 'expected real overlap');
      } finally {
        await file.delete();
      }
    });
  });

  group('Step 1 — memory ceiling', () {
    test('MemoryGate blocks once the byte budget is full', () async {
      // Each chunk costs plaintext + encrypted ≈ 2 MB. A 5 MB budget admits
      // exactly 2 chunks (4.2 MB) but blocks the 3rd (6.3 MB), so no more than
      // 2 chunk POSTs can ever be in flight — regardless of the count limit.
      final gate = MemoryGate(maxBytes: 5 * mb, safetyMarginBytes: 0);
      var cur = 0, peak = 0;
      final mock = uploadMock(onChunkPost: (_) async {
        cur++;
        peak = max(peak, cur);
        await Future.delayed(const Duration(milliseconds: 15));
        cur--;
      });
      final file = await tmpFile('mem.bin', 8 * mb); // 8 chunks
      try {
        // Count semaphore is generous (8); the GATE is the binding constraint.
        await makeUploader(mock, gate: gate)
            .uploadFileChunked(file, 'parent', maxConcurrentChunks: 8);
        expect(peak, lessThanOrEqualTo(2),
            reason: 'MemoryGate should cap in-flight chunks to its budget');
        expect(peak, greaterThan(1),
            reason: 'the gate should still admit up to its budget (2 chunks)');
      } finally {
        await file.delete();
      }
    });
  });

  group('Step 1 — resume as a set', () {
    test('restart retries exactly the missing indices (gap-safe)', () async {
      final posted = <int>[];
      final mock = uploadMock(onChunkPost: (i) async => posted.add(i));
      final file = await tmpFile('resume.bin', 6 * mb); // 6 chunks 0..5
      try {
        await makeUploader(mock).uploadFileChunked(
          file,
          'parent',
          completedChunks: {0, 1, 3}, // note the GAP at index 2
          maxConcurrentChunks: 4,
        );
        posted.sort();
        expect(posted, [2, 4, 5],
            reason: 'must upload only the missing indices, not a range');
      } finally {
        await file.delete();
      }
    });

    test('failure carries the completed set, file key and contiguous max',
        () async {
      // Sequential so the failure point is deterministic: 0..3 land, 4 fails.
      final mock = uploadMock(failOn: {4});
      final file = await tmpFile('fail.bin', 6 * mb); // 6 chunks
      try {
        await expectLater(
          () => makeUploader(mock)
              .uploadFileChunked(file, 'parent', maxConcurrentChunks: 1),
          throwsA(isA<ChunkUploadException>()
              .having((e) => e.completedChunks, 'completedChunks', {0, 1, 2, 3})
              .having((e) => e.lastSuccessfulChunk, 'lastSuccessfulChunk', 3)
              .having((e) => e.fileKey, 'fileKey', isNotNull)),
        );
      } finally {
        await file.delete();
      }
    });
  });

  group('Step 1 — tiny files stay sequential', () {
    test('a tiny file never touches the MemoryGate', () async {
      final gate = _SpyGate();
      final mock = uploadMock();
      final file = await tmpFile('tiny.bin', mb + 10); // 2 chunks == threshold
      try {
        await makeUploader(mock, gate: gate)
            .uploadFileChunked(file, 'parent', maxConcurrentChunks: 4);
        expect(gate.acquireCalls, 0,
            reason: 'tiny-file path must not engage per-chunk gating');
      } finally {
        await file.delete();
      }
    });
  });

  group('Step 1 — download reassembly', () {
    test('concurrent download writes chunks byte-exactly', () async {
      // 5 chunks, last partial. The mock serves chunk i of `blob` verbatim;
      // crypto.decryptData is identity here because we serve plaintext and use
      // a key-less identity crypto via a real FilenCrypto won't decrypt — so we
      // feed pre-"encrypted" bytes the real crypto can round-trip.
      final crypto = FilenCrypto(random: Random(3));
      final keyStr = crypto.randomString(32);
      final keyBytes = Uint8List.fromList(utf8.encode(keyStr));
      final blob = Uint8List.fromList(
          List.generate(4 * mb + 777, (i) => (i * 31) % 256));

      // Pre-encrypt each chunk so the real decryptData reproduces the blob.
      final encChunks = <int, Uint8List>{};
      for (var i = 0; i * mb < blob.length; i++) {
        final end = min(blob.length, (i + 1) * mb);
        encChunks[i] = await crypto.encryptData(
            Uint8List.sublistView(blob, i * mb, end), keyBytes);
      }
      final chunks = encChunks.length;

      final meta =
          json.encode({'name': 'f.bin', 'size': blob.length, 'key': keyStr});
      final mock = MockClient((request) async {
        if (request.url.path.contains('/v3/file')) {
          // Return metadata encrypted under the master key the drive holds.
          return http.Response(
              json.encode({
                'status': true,
                'data': {
                  'metadata': await crypto.encryptMetadata002(
                      meta, 'test-master-key-for-upload-tests0'),
                  'chunks': chunks,
                  'region': 'r',
                  'bucket': 'b',
                }
              }),
              200);
        }
        // egest chunk fetch: /r/b/<uuid>/<index>
        final i = int.parse(request.url.pathSegments.last);
        return http.Response.bytes(encChunks[i]!, 200);
      });

      final api = FilenApi(client: mock);
      api.apiKey = 'k';
      final cache = FilenCache();
      final drive = FilenDrive(api: api, crypto: crypto, cache: cache);
      drive.masterKeys = ['test-master-key-for-upload-tests0'];
      final downloader =
          FilenDownload(api: api, crypto: crypto, cache: cache, drive: drive);

      final out = '${Directory.systemTemp.path}/filen_conc_dl.bin';
      try {
        await downloader.downloadFile('file-uuid',
            savePath: out, maxConcurrentChunks: 4);
        final got = await File(out).readAsBytes();
        expect(got, equals(blob),
            reason: 'out-of-order writes must reassemble byte-exactly');
      } finally {
        final f = File(out);
        if (f.existsSync()) await f.delete();
      }
    });
  });
}

/// A MemoryGate that records how often acquire() is called.
class _SpyGate extends MemoryGate {
  int acquireCalls = 0;
  @override
  Future<void> acquire(int bytes) {
    acquireCalls++;
    return super.acquire(bytes);
  }
}
