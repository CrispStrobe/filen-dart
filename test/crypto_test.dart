import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';
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
      final encrypted =
          await crypto.encryptMetadata002('secret', 'correct-key-0000000000000000');
      expect(
        () => crypto.decryptMetadata002(encrypted, 'wrong-key-00000000000000000'),
        throwsException,
      );
    });

    test('invalid version prefix throws', () async {
      expect(
        () => crypto.decryptMetadata002('001invalid-data', 'key'),
        throwsA(isA<Exception>()),
      );
    });
  });

  group('encryptData / decryptData', () {
    test('round-trip', () async {
      final key = Uint8List.fromList(utf8.encode('12345678901234567890123456789012'));
      final data = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);

      final encrypted = await crypto.encryptData(data, key);
      expect(encrypted.length, greaterThan(data.length + 12)); // IV + ciphertext + tag

      final decrypted = await crypto.decryptData(encrypted, key);
      expect(decrypted, equals(data));
    });

    test('wrong key fails', () async {
      final key1 = Uint8List.fromList(utf8.encode('12345678901234567890123456789012'));
      final key2 = Uint8List.fromList(utf8.encode('abcdefghijklmnopqrstuvwxyz123456'));
      final data = Uint8List.fromList([1, 2, 3]);

      final encrypted = await crypto.encryptData(data, key1);
      expect(
        () => crypto.decryptData(encrypted, key2),
        throwsException,
      );
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
  });

  group('tryDecrypt', () {
    test('tries multiple keys and succeeds', () async {
      final correctKey = 'correct-key-00000000000000000000';
      final wrongKey = 'wrong-key-000000000000000000000000';

      final encrypted = await crypto.encryptMetadata002('hello', correctKey);

      final result =
          await crypto.tryDecrypt(encrypted, [wrongKey, correctKey]);
      expect(result, equals('hello'));
    });

    test('throws when no key works', () async {
      final encrypted =
          await crypto.encryptMetadata002('hello', 'key-0000000000000000000000000');
      expect(
        () => crypto.tryDecrypt(encrypted, ['bad-key-00000000000000000000']),
        throwsA(isA<Exception>()),
      );
    });
  });

  group('pbkdf2', () {
    test('produces deterministic output', () {
      final key1 = crypto.pbkdf2(
          utf8.encode('password'), utf8.encode('salt'), 1, 64);
      final key2 = crypto.pbkdf2(
          utf8.encode('password'), utf8.encode('salt'), 1, 64);
      expect(key1, equals(key2));
    });

    test('different passwords produce different keys', () {
      final key1 = crypto.pbkdf2(
          utf8.encode('pass1'), utf8.encode('salt'), 1, 64);
      final key2 = crypto.pbkdf2(
          utf8.encode('pass2'), utf8.encode('salt'), 1, 64);
      expect(key1, isNot(equals(key2)));
    });

    test('different salts produce different keys', () {
      final key1 = crypto.pbkdf2(
          utf8.encode('pass'), utf8.encode('salt1'), 1, 64);
      final key2 = crypto.pbkdf2(
          utf8.encode('pass'), utf8.encode('salt2'), 1, 64);
      expect(key1, isNot(equals(key2)));
    });

    test('output length matches requested', () {
      final key = crypto.pbkdf2(
          utf8.encode('pass'), utf8.encode('salt'), 1, 32);
      expect(key.length, equals(32));

      final key2 = crypto.pbkdf2(
          utf8.encode('pass'), utf8.encode('salt'), 1, 128);
      expect(key2.length, equals(128));
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
