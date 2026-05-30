import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:crypto/crypto.dart' as crypto_pkg;
import 'package:hex/hex.dart';
import 'package:filen_dart/crypto.dart';

void main() {
  late FilenCrypto crypto;

  setUp(() {
    // Use a seeded random for deterministic tests
    crypto = FilenCrypto(random: Random(42));
  });

  group('encryptMetadata002 / decryptMetadata002', () {
    test('round-trip with known key', () async {
      final key = 'test-key-for-encrypt-decrypt-0001';
      final plaintext = 'Hello, Filen!';

      final encrypted = await crypto.encryptMetadata002(plaintext, key);
      expect(encrypted.startsWith('002'), isTrue);
      expect(encrypted.length, greaterThan(15)); // 3 prefix + 12 IV + data

      final decrypted = await crypto.decryptMetadata002(encrypted, key);
      expect(decrypted, equals(plaintext));
    });

    test('different IVs produce different ciphertexts', () async {
      final key = 'test-key-for-encrypt-decrypt-0001';
      final plaintext = 'Same plaintext';

      // Use two different crypto instances with different random seeds
      final crypto1 = FilenCrypto(random: Random(1));
      final crypto2 = FilenCrypto(random: Random(2));

      final enc1 = await crypto1.encryptMetadata002(plaintext, key);
      final enc2 = await crypto2.encryptMetadata002(plaintext, key);

      expect(enc1, isNot(equals(enc2)));

      // Both should decrypt to the same value
      expect(await crypto1.decryptMetadata002(enc1, key), equals(plaintext));
      expect(await crypto2.decryptMetadata002(enc2, key), equals(plaintext));
    });

    test('wrong key fails', () async {
      final encrypted = await crypto.encryptMetadata002(
          'secret', 'correct-key-0000000000000000');
      expect(
        () =>
            crypto.decryptMetadata002(encrypted, 'wrong-key-00000000000000000'),
        throwsException,
      );
    });

    test('invalid version prefix throws', () async {
      expect(
        () => crypto.decryptMetadata002('001invalid-data', 'key'),
        throwsA(isA<Exception>()),
      );
    });

    test('empty string round-trips', () async {
      const key = 'test-key-for-encrypt-decrypt-0001';
      final enc = await crypto.encryptMetadata002('', key);
      expect(await crypto.decryptMetadata002(enc, key), equals(''));
    });

    test('round-trips unicode and control characters', () async {
      const key = 'test-key-for-encrypt-decrypt-0001';
      for (final text in ['unicode ✓ 中文 🚀', 'a\nb\r\tc', 'x' * 256]) {
        final enc = await crypto.encryptMetadata002(text, key);
        expect(await crypto.decryptMetadata002(enc, key), equals(text));
      }
    });

    test('output is 002 prefix + 12-char IV + tagged ciphertext', () async {
      const key = 'test-key-for-encrypt-decrypt-0001';
      final enc = await crypto.encryptMetadata002('hello', key);
      expect(enc.substring(0, 3), equals('002'));
      expect(enc.substring(3, 15), matches(RegExp(r'^[A-Za-z0-9\-_]{12}$')));
      final ct = base64.decode(enc.substring(15));
      expect(ct.length, equals(utf8.encode('hello').length + 16)); // + GCM tag
    });

    test('same instance generates a fresh IV per call', () async {
      const key = 'test-key-for-encrypt-decrypt-0001';
      final a = await crypto.encryptMetadata002('dup', key);
      final b = await crypto.encryptMetadata002('dup', key);
      expect(a, isNot(equals(b)));
    });
  });

  group('encryptData / decryptData', () {
    test('round-trip', () async {
      final key =
          Uint8List.fromList(utf8.encode('12345678901234567890123456789012'));
      final data = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);

      final encrypted = await crypto.encryptData(data, key);
      expect(encrypted.length,
          greaterThan(data.length + 12)); // IV + ciphertext + tag

      final decrypted = await crypto.decryptData(encrypted, key);
      expect(decrypted, equals(data));
    });

    test('wrong key fails', () async {
      final key1 =
          Uint8List.fromList(utf8.encode('12345678901234567890123456789012'));
      final key2 =
          Uint8List.fromList(utf8.encode('abcdefghijklmnopqrstuvwxyz123456'));
      final data = Uint8List.fromList([1, 2, 3]);

      final encrypted = await crypto.encryptData(data, key1);
      expect(
        () => crypto.decryptData(encrypted, key2),
        throwsException,
      );
    });

    test('round-trips a range of sizes including empty', () async {
      final key =
          Uint8List.fromList(utf8.encode('12345678901234567890123456789012'));
      for (final size in [0, 1, 16, 256, 1024, 65536]) {
        final data = Uint8List.fromList(List.generate(size, (i) => i % 256));
        final enc = await crypto.encryptData(data, key);
        // GCM layout: 12-byte IV + ciphertext(==plaintext len) + 16-byte tag.
        expect(enc.length, equals(size + 28));
        expect(await crypto.decryptData(enc, key), equals(data));
      }
    });

    test('rejects tampered ciphertext (GCM authentication)', () async {
      final key =
          Uint8List.fromList(utf8.encode('12345678901234567890123456789012'));
      final enc =
          await crypto.encryptData(Uint8List.fromList([1, 2, 3, 4, 5]), key);
      enc[enc.length - 1] ^= 0xFF; // flip a tag byte
      expect(() => crypto.decryptData(enc, key), throwsA(isA<Exception>()));
    });
  });

  group('decodeUniversalKey', () {
    test('decodes 32-char ASCII key', () {
      final key = 'abcdefghijklmnopqrstuvwxyz123456';
      final result = crypto.decodeUniversalKey(key);
      expect(result, equals(Uint8List.fromList(utf8.encode(key))));
    });

    test('decodes base64 key', () {
      final original = Uint8List.fromList(List.generate(32, (i) => i));
      final b64 = base64.encode(original);
      final result = crypto.decodeUniversalKey(b64);
      expect(result, equals(original));
    });

    test('decodes hex key', () {
      final original = Uint8List.fromList([0xab, 0xcd, 0xef]);
      final hexStr = HEX.encode(original);
      final result = crypto.decodeUniversalKey(hexStr);
      expect(result, equals(original));
    });

    test('throws on invalid key', () {
      expect(() => crypto.decodeUniversalKey('!!!'), throwsException);
    });

    test('32-char base64 outside the key alphabet is base64-decoded', () {
      // 24 bytes -> exactly 32 base64 chars. By including 0xFF bytes the
      // encoding contains '/', which is NOT in the raw-key alphabet, so it
      // must take the base64 branch (not be misread as a 32-char raw key).
      final original =
          Uint8List.fromList([...List.filled(21, 0), ...List.filled(3, 0xFF)]);
      final b64 = base64.encode(original);
      expect(b64.length, equals(32));
      expect(b64.contains('/'), isTrue);
      expect(crypto.decodeUniversalKey(b64), equals(original));
    });
  });

  group('tryDecrypt', () {
    test('tries multiple keys and succeeds', () async {
      final correctKey = 'correct-key-00000000000000000000';
      final wrongKey = 'wrong-key-000000000000000000000000';

      final encrypted = await crypto.encryptMetadata002('hello', correctKey);

      final result = await crypto.tryDecrypt(encrypted, [wrongKey, correctKey]);
      expect(result, equals('hello'));
    });

    test('throws when no key works', () async {
      final encrypted = await crypto.encryptMetadata002(
          'hello', 'key-0000000000000000000000000');
      expect(
        () => crypto.tryDecrypt(encrypted, ['bad-key-00000000000000000000']),
        throwsA(isA<Exception>()),
      );
    });
  });

  group('pbkdf2', () {
    test('produces deterministic output', () {
      final key1 =
          crypto.pbkdf2(utf8.encode('password'), utf8.encode('salt'), 1, 64);
      final key2 =
          crypto.pbkdf2(utf8.encode('password'), utf8.encode('salt'), 1, 64);
      expect(key1, equals(key2));
    });

    test('different passwords produce different keys', () {
      final key1 =
          crypto.pbkdf2(utf8.encode('pass1'), utf8.encode('salt'), 1, 64);
      final key2 =
          crypto.pbkdf2(utf8.encode('pass2'), utf8.encode('salt'), 1, 64);
      expect(key1, isNot(equals(key2)));
    });

    test('different salts produce different keys', () {
      final key1 =
          crypto.pbkdf2(utf8.encode('pass'), utf8.encode('salt1'), 1, 64);
      final key2 =
          crypto.pbkdf2(utf8.encode('pass'), utf8.encode('salt2'), 1, 64);
      expect(key1, isNot(equals(key2)));
    });

    test('output length matches requested', () {
      final key =
          crypto.pbkdf2(utf8.encode('pass'), utf8.encode('salt'), 1, 32);
      expect(key.length, equals(32));

      final key2 =
          crypto.pbkdf2(utf8.encode('pass'), utf8.encode('salt'), 1, 128);
      expect(key2.length, equals(128));
    });

    // Known-answer vectors computed independently with Python's
    // hashlib.pbkdf2_hmac('sha512', ...). These guard the hand-rolled HMAC
    // block/XOR loop against a vetted reference implementation.
    test('matches reference vector for a single block (64 bytes)', () {
      final out =
          crypto.pbkdf2(utf8.encode('password'), utf8.encode('salt'), 1, 64);
      expect(
          HEX.encode(out),
          equals('867f70cf1ade02cff3752599a3a53dc4af34c7a669815ae5d513554e1'
              'c8cf252c02d470a285a0501bad999bfe943c08f050235d7d68b1da55e63f73b'
              '60a57fce'));
    });

    test('matches reference vector across two blocks (128 bytes)', () {
      final out =
          crypto.pbkdf2(utf8.encode('password'), utf8.encode('salt'), 1, 128);
      expect(
          HEX.encode(out),
          equals('867f70cf1ade02cff3752599a3a53dc4af34c7a669815ae5d513554e1'
              'c8cf252c02d470a285a0501bad999bfe943c08f050235d7d68b1da55e63f73b'
              '60a57fce7b532e206c2967d4c7d2ffa460539fc4d4e5eec70125d74c6c7cf86'
              'd25284f297907fcea1ad214effdbea23e1312084eabb180ab72edbac45ea2a'
              '53f5f5b9fe1'));
    });

    test('first block of multi-block output equals single-block output', () {
      final single =
          crypto.pbkdf2(utf8.encode('password'), utf8.encode('salt'), 1, 64);
      final multi =
          crypto.pbkdf2(utf8.encode('password'), utf8.encode('salt'), 1, 128);
      expect(multi.sublist(0, 64), equals(single));
    });
  });

  group('deriveKeys', () {
    test('v2 returns separate masterKey and password', () async {
      final keys = await crypto.deriveKeys('password', 2, 'salt');
      expect(keys.containsKey('masterKey'), isTrue);
      expect(keys.containsKey('password'), isTrue);
      expect(keys['masterKey']!.length, equals(64)); // 32 bytes hex
      expect(keys['masterKey'], isNot(equals(keys['password'])));
    });

    test('v1 returns same masterKey and password', () async {
      final keys = await crypto.deriveKeys('password', 1, 'salt');
      expect(keys['masterKey'], equals(keys['password']));
    });

    // Known-answer vectors (PBKDF2-HMAC-SHA512, 200000 iterations) computed
    // independently with Python. Pins the exact auth derivation so a change
    // to iteration count / output split is caught.
    test('v2 matches reference vector', () async {
      final keys = await crypto.deriveKeys('password', 2, 'salt');
      expect(
          keys['masterKey'],
          equals(
              '01f8712941c86ffad39b79100696ea63b03b95b50d3aa121bfd265577fece6c4'));
      expect(
          keys['password'],
          equals('65773430407d1049af0d42763b5bc2bc8f60ab7f4143d98f7f57a877a951'
              '801d38054187db31989a02e83e7a0f5f1a9085a85197d2846b7df28053b46ae'
              'd4790'));
    });

    test('v1 matches reference vector', () async {
      final keys = await crypto.deriveKeys('password', 1, 'salt');
      expect(
          keys['masterKey'],
          equals('01f8712941c86ffad39b79100696ea63b03b95b50d3aa121bfd265577fec'
              'e6c402bbe0fcb432ea50b3e95b81c81aa2e9d82213cd3305c137b73ae1d2fec'
              '72bc5'));
    });
  });

  group('generateHMACKey / hashFileName', () {
    final masterKeys = ['0123456789abcdef0123456789abcdef'];

    test('generateHMACKey matches reference vector', () async {
      final hk = await crypto.generateHMACKey(masterKeys, 'User@Example.com');
      expect(
          hk,
          equals(
              '7a9d80da7c1fd5019df30f9f0ed9322413e8588ad1b5a8d5ccf062331a195a44'));
    });

    test('generateHMACKey lowercases the email', () async {
      final a = await crypto.generateHMACKey(masterKeys, 'User@Example.com');
      final b = await crypto.generateHMACKey(masterKeys, 'user@example.com');
      expect(a, equals(b));
    });

    test('generateHMACKey throws when the last master key is empty', () {
      expect(() => crypto.generateHMACKey([''], 'a@b.com'),
          throwsA(isA<Exception>()));
    });

    test('hashFileName matches reference vector', () async {
      final h = await crypto.hashFileName(
          'Hello.TXT', masterKeys, 'User@Example.com');
      expect(
          h,
          equals(
              '3d4ee4aba2520424aeaca45546cf87421090bc51847a4df5d7d439b8739bd507'));
    });

    test('hashFileName is case-insensitive on the name', () async {
      final a = await crypto.hashFileName('Hello.TXT', masterKeys, 'u@e.com');
      final b = await crypto.hashFileName('hello.txt', masterKeys, 'u@e.com');
      expect(a, equals(b));
    });
  });

  group('hashFile', () {
    test('hashes an empty file to the SHA-512 empty digest', () async {
      final dir = await Directory.systemTemp.createTemp('filen_hashfile_');
      try {
        final f = File('${dir.path}/empty.bin');
        await f.writeAsBytes([]);
        expect(
            await crypto.hashFile(f),
            equals('cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36'
                'ce9ce47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327a'
                'f927da3e'));
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('chunked read matches a single-shot hash over >1MB', () async {
      final dir = await Directory.systemTemp.createTemp('filen_hashfile_');
      try {
        final f = File('${dir.path}/big.bin');
        final data =
            Uint8List.fromList(List.generate(1048576 + 1234, (i) => i % 256));
        await f.writeAsBytes(data);
        final expected = HEX.encode(crypto_pkg.sha512.convert(data).bytes);
        expect(await crypto.hashFile(f), equals(expected));
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });

  group('uuid', () {
    test('generates valid UUID v4 format', () {
      final id = crypto.uuid();
      expect(
        id,
        matches(RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')),
      );
    });

    test('generates unique UUIDs', () {
      final ids = List.generate(100, (_) => crypto.uuid()).toSet();
      expect(ids.length, equals(100));
    });
  });

  group('randomString', () {
    test('generates correct length', () {
      expect(crypto.randomString(16).length, equals(16));
      expect(crypto.randomString(32).length, equals(32));
    });

    test('contains only valid characters', () {
      final s = crypto.randomString(100);
      expect(
        s,
        matches(RegExp(r'^[A-Za-z0-9\-_]+$')),
      );
    });
  });

  group('randomBytes', () {
    test('generates correct length', () {
      expect(crypto.randomBytes(16).length, equals(16));
      expect(crypto.randomBytes(32).length, equals(32));
    });
  });
}
