import 'package:test/test.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:filen_client/utils.dart';

void main() {
  group('formatSize', () {
    test('formats 0 bytes', () {
      expect(formatSize(0), '0 B');
    });

    test('formats negative bytes', () {
      expect(formatSize(-1), '0 B');
    });

    test('formats bytes', () {
      expect(formatSize(500), '500.0 B');
    });

    test('formats KB', () {
      expect(formatSize(1024), '1.0 KB');
      expect(formatSize(1536), '1.5 KB');
    });

    test('formats MB', () {
      expect(formatSize(1048576), '1.0 MB');
    });

    test('formats GB', () {
      expect(formatSize(1073741824), '1.0 GB');
    });

    test('handles string input', () {
      expect(formatSize('1024'), '1.0 KB');
    });

    test('handles invalid string input', () {
      expect(formatSize('abc'), '0 B');
    });

    test('handles int input', () {
      expect(formatSize(2048), '2.0 KB');
    });

    test('formats sub-KB boundary values', () {
      expect(formatSize(1), '1.0 B');
      expect(formatSize(1023), '1023.0 B');
    });

    test('rounds just-below-MB up to KB at one decimal', () {
      // 1048575 B = 1023.999... KB -> rounds to 1024.0 KB at one decimal.
      expect(formatSize(1048575), '1024.0 KB');
    });

    test('formats GB with fractional precision', () {
      expect(formatSize(1610612736), '1.5 GB'); // 1.5 * 1024^3
    });

    test('formats TB tier', () {
      expect(formatSize(1099511627776), '1.0 TB'); // 1024^4
    });

    test('clamps above TB to TB units', () {
      expect(formatSize(1125899906842624), '1024.0 TB'); // 1024^5
    });
  });

  group('formatDate', () {
    test('formats null', () {
      expect(formatDate(null), '');
    });

    test('formats int timestamp', () {
      // 2024-01-15 in milliseconds (approx)
      final result = formatDate(1705276800000);
      expect(result, matches(RegExp(r'^\d{4}-\d{2}-\d{2}$')));
    });

    test('formats string date', () {
      expect(formatDate('2024-01-15T12:00:00Z'), '2024-01-15');
    });

    test('formats short string', () {
      expect(formatDate('Hi'), 'Hi');
    });

    test('handles invalid input gracefully', () {
      // Should not throw
      final result = formatDate(Object());
      expect(result, isA<String>());
    });
  });

  group('DigestSink', () {
    test('captures digest value', () {
      final sink = DigestSink();
      final digest = crypto.sha256.convert([1, 2, 3]);
      sink.add(digest);
      expect(sink.value, equals(digest));
    });

    test('close does nothing', () {
      final sink = DigestSink();
      sink.close(); // Should not throw
      expect(sink.value, isNull);
    });
  });

  group('shouldIncludeFile', () {
    test('includes all when no patterns', () {
      expect(shouldIncludeFile('test.txt', [], []), isTrue);
    });

    test('includes matching pattern', () {
      expect(shouldIncludeFile('test.txt', ['*.txt'], []), isTrue);
    });

    test('excludes non-matching pattern', () {
      expect(shouldIncludeFile('test.pdf', ['*.txt'], []), isFalse);
    });

    test('excludes matching exclude pattern', () {
      expect(shouldIncludeFile('test.log', [], ['*.log']), isFalse);
    });

    test('exclude takes precedence', () {
      expect(shouldIncludeFile('test.txt', ['*.txt'], ['*.txt']), isFalse);
    });

    test('wildcard ? matches single character', () {
      expect(shouldIncludeFile('test1.txt', ['test?.txt'], []), isTrue);
      expect(shouldIncludeFile('test12.txt', ['test?.txt'], []), isFalse);
    });

    test('matches any of multiple include patterns', () {
      expect(shouldIncludeFile('a.jpg', ['*.txt', '*.jpg'], []), isTrue);
      expect(shouldIncludeFile('a.png', ['*.txt', '*.jpg'], []), isFalse);
    });

    test('excludes if any of multiple exclude patterns match', () {
      expect(shouldIncludeFile('a.tmp', [], ['*.log', '*.tmp']), isFalse);
      expect(shouldIncludeFile('a.txt', [], ['*.log', '*.tmp']), isTrue);
    });

    test('glob matching is case-insensitive', () {
      expect(shouldIncludeFile('README.MD', ['*.md'], []), isTrue);
      expect(shouldIncludeFile('Photo.JPG', [], ['*.jpg']), isFalse);
    });

    test('literal dot is not a wildcard', () {
      // '*.txt' must not match a name with no dot before "txt".
      expect(shouldIncludeFile('axtxt', ['*.txt'], []), isFalse);
    });

    test('regex metacharacters in pattern are matched literally', () {
      // These patterns contain regex specials (+, (), [], $) that must not be
      // interpreted — they should match only the literal characters.
      expect(shouldIncludeFile('a+b.txt', ['a+b.txt'], []), isTrue);
      expect(shouldIncludeFile('aaab.txt', ['a+b.txt'], []), isFalse);
      expect(shouldIncludeFile('file(1).log', ['file(1).*'], []), isTrue);
      expect(shouldIncludeFile('data[0].bin', ['data[0].bin'], []), isTrue);
      expect(shouldIncludeFile('price\$.csv', [r'price$.csv'], []), isTrue);
    });
  });
}
