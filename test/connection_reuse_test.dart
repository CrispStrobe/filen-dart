// Regression tests for Step 0 (connection reuse).
//
// Chunk transfers used to call the top-level `http.post` / `http.get`, each of
// which spins up a throwaway one-shot client — so every 1 MB chunk paid a fresh
// TCP+TLS handshake AND bypassed the injectable `api.client` (making the chunk
// path untestable / non-hermetic). These tests pin the fix: all chunk traffic
// must flow through the single pooled `api.client`.

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:test/test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:filen_client/api.dart';
import 'package:filen_client/cache.dart';
import 'package:filen_client/crypto.dart';
import 'package:filen_client/drive.dart';
import 'package:filen_client/upload.dart';

void main() {
  group('connection reuse (Step 0)', () {
    test('non-empty chunk upload routes through injected api.client', () async {
      // Records every request the pooled client sees. If the chunk POST went
      // through the old global http.post, the mock would never observe the
      // ingest /v3/upload call (it would try the real network instead).
      final seen = <String>[];

      final mockClient = MockClient((request) async {
        seen.add('${request.method} ${request.url.path}');
        return http.Response(json.encode({'status': true, 'data': {}}), 200);
      });

      final api = FilenApi(client: mockClient);
      api.apiKey = 'test-key';
      final crypto = FilenCrypto(random: Random(42));
      final cache = FilenCache();
      final drive = FilenDrive(api: api, crypto: crypto, cache: cache);
      drive.baseFolderUUID = 'root-uuid';
      drive.masterKeys = ['test-master-key-for-upload-tests0'];
      drive.email = 'test@example.com';
      final uploader =
          FilenUpload(api: api, crypto: crypto, cache: cache, drive: drive);

      // Small but non-empty => exactly one real chunk (not the /empty path).
      final tempFile =
          File('${Directory.systemTemp.path}/filen_conn_reuse_up.txt');
      await tempFile.writeAsString('hello chunk');

      try {
        await uploader.uploadFileChunked(tempFile, 'parent-uuid',
            onProgress: (_, __, ___, ____) {});

        // The chunk upload endpoint must have been observed by the pooled
        // client — proof the chunk traffic no longer bypasses api.client.
        expect(
            seen.any((s) => s.startsWith('POST') && s.contains('/v3/upload')),
            isTrue,
            reason: 'chunk POST should flow through the pooled api.client');
        // And it must be the real chunk endpoint, not the empty-file shortcut.
        expect(seen.any((s) => s.contains('/v3/upload/empty')), isFalse,
            reason: 'non-empty file should not take the empty-file path');
      } finally {
        if (tempFile.existsSync()) tempFile.deleteSync();
      }
    });

    test('FilenApi exposes a single reused client instance', () {
      final mockClient =
          MockClient((request) async => http.Response('{}', 200));
      final api = FilenApi(client: mockClient);

      // The same client object every time — callers (chunk transfers) reuse it
      // rather than constructing their own per request.
      expect(identical(api.client, api.client), isTrue);
      expect(identical(api.client, mockClient), isTrue);
    });
  });
}
