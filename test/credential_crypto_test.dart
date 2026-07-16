// Credential-at-rest envelope crypto: AES-256-GCM under a PBKDF2-derived key.
// This protects the local credentials file only (not the Filen wire protocol),
// so we just need: round-trip, wrong-key rejection, tamper rejection, and a
// fresh salt/iv per call (no deterministic ciphertext reuse).

import 'dart:convert';

import 'package:test/test.dart';
import 'package:filen_client/credential_crypto.dart';

void main() {
  const secret = 'a-wrapping-secret-key';
  const plaintext = '{"apiKey":"abc123","masterKeys":"k1|k2"}';

  test('round-trips under the same secret', () {
    final enc = encryptTextWithKey(plaintext, secret);
    expect(enc, isNot(contains('abc123'))); // not plaintext on disk
    expect(decryptTextWithKey(enc, secret), equals(plaintext));
  });

  test('wrong secret fails authentication', () {
    final enc = encryptTextWithKey(plaintext, secret);
    expect(() => decryptTextWithKey(enc, 'not-the-secret'), throwsA(anything));
  });

  test('tampered ciphertext is rejected (GCM integrity)', () {
    final enc = encryptTextWithKey(plaintext, secret);
    final bytes = enc.codeUnits.toList();
    bytes[bytes.length - 2] ^= 0x01; // flip a hex nibble near the tag
    expect(() => decryptTextWithKey(String.fromCharCodes(bytes), secret),
        throwsA(anything));
  });

  test('uses a fresh salt/iv each call (ciphertexts differ)', () {
    expect(encryptTextWithKey(plaintext, secret),
        isNot(equals(encryptTextWithKey(plaintext, secret))));
  });

  test('handles empty and unicode payloads', () {
    for (final s in [
      '',
      '🔐 ünîcødé',
      jsonEncode({'x': 'y' * 5000})
    ]) {
      expect(
          decryptTextWithKey(encryptTextWithKey(s, secret), secret), equals(s));
    }
  });

  test('rejects a too-short envelope', () {
    expect(() => decryptTextWithKey('00', secret), throwsA(anything));
  });
}
