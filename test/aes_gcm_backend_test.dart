// AES-GCM backend correctness: the fast backends (OpenSSL/BCrypt FFI,
// package:cryptography) must be byte-interoperable with Filen's original
// pointycastle wire format [iv(12)|ct|tag], so existing encrypted chunks stay
// readable. The platform native-FFI binding is asserted per-OS (catches a broken
// Windows BCrypt / Linux OpenSSL binding in CI rather than silently degrading).

import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:filen_dart/aes_gcm_backend.dart';
import 'package:filen_dart/crypto.dart';
import 'package:filen_dart/openssl_aesgcm.dart';
import 'package:filen_dart/bcrypt_aesgcm.dart';

void main() {
  final key = Uint8List(32)
    ..setAll(0, List.generate(32, (i) => (i * 7 + 3) & 0xff));
  // Deterministic pointycastle backend = Filen's original wire format.
  final pc = PointycastleBackend(
      (n) => Uint8List(n)..setAll(0, List.generate(n, (_) => 7)));

  group('AES-GCM backends', () {
    test(
        'selected backend round-trips + interops with Filen pointycastle format',
        () async {
      final fast = chooseAesGcmBackend();
      for (final n in [0, 1, 15, 16, 17, 31, 32, 4096, 4097, 1 << 20]) {
        final d = Uint8List(n)
          ..setAll(0, List.generate(n, (i) => (i * 13 + 5) & 0xff));
        expect(await fast.decryptData(key, await fast.encryptData(key, d)),
            equals(d),
            reason: '${fast.name} $n-byte round-trip');
        // existing Filen chunk (pointycastle) decrypts under the fast backend
        expect(await fast.decryptData(key, await pc.encryptData(key, d)),
            equals(d),
            reason: '${fast.name} decrypts pointycastle chunk ($n B)');
        expect(await pc.decryptData(key, await fast.encryptData(key, d)),
            equals(d),
            reason: 'pointycastle decrypts ${fast.name} chunk ($n B)');
      }
    });

    test('cryptography backend interops with pointycastle', () async {
      final cgb = CryptographyBackend();
      final d = Uint8List(5000)
        ..setAll(0, List.generate(5000, (i) => i & 0xff));
      expect(
          await cgb.decryptData(key, await pc.encryptData(key, d)), equals(d));
      expect(
          await pc.decryptData(key, await cgb.encryptData(key, d)), equals(d));
    });

    test('tampered tag is rejected (GCM integrity)', () async {
      final fast = chooseAesGcmBackend();
      final ct = await fast.encryptData(
          key, Uint8List.fromList(List.generate(100, (i) => i)));
      ct[ct.length - 1] ^= 0xff;
      expect(() => fast.decryptData(key, ct), throwsA(anything));
    });

    test('FilenCrypto round-trips a real-ish 1 MB chunk', () async {
      final fc = FilenCrypto();
      final chunk = Uint8List(1 << 20)
        ..setAll(0, List.generate(1 << 20, (i) => (i * 131 + 7) & 0xff));
      final enc = await fc.encryptData(chunk, key);
      expect(await fc.decryptData(enc, key), equals(chunk));
    });
  });

  test(
      'platform native FFI binding loads + is byte-exact (Win->BCrypt, Linux->OpenSSL)',
      () async {
    final dynamic native;
    if (Platform.isWindows) {
      native = BCryptAesGcm.tryLoad();
      expect(native, isNotNull, reason: 'BCrypt FFI must load on Windows');
    } else if (Platform.isLinux) {
      native = OpenSslAesGcm.tryLoad();
      expect(native, isNotNull,
          reason: 'OpenSSL libcrypto FFI must load on Linux');
    } else {
      native = OpenSslAesGcm.tryLoad();
      if (native == null) {
        markTestSkipped('no system libcrypto here');
        return;
      }
    }
    final d = Uint8List(4096)
      ..setAll(0, List.generate(4096, (i) => (i * 13 + 5) & 0xff));
    expect(native.decrypt(key, native.encrypt(key, d)), equals(d));
    // interop with the Filen pointycastle wire format
    expect(native.decrypt(key, await pc.encryptData(key, d)), equals(d));
  });
}
