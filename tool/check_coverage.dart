#!/usr/bin/env dart
/// Per-file coverage gate checker.
///
/// Parses lcov.info and enforces minimum line-coverage thresholds per file.
/// Usage: dart tool/check_coverage.dart coverage/lcov.info
///
/// Modeled after internxt-dart's CI coverage gates.
import 'dart:io';

/// Per-file coverage thresholds (percentage).
/// Files not listed here get a default threshold.
const thresholds = <String, int>{
  'lib/crypto.dart': 90,
  'lib/utils.dart': 100,
  'lib/config.dart': 85,
  'lib/config_storage.dart': 90,
  'lib/cache.dart': 80,
  'lib/memory_gate.dart': 70,
  'lib/api.dart': 30,
  'lib/auth.dart': 30,
  'lib/drive.dart': 20,
  'lib/upload.dart': 15,
  'lib/download.dart': 15,
  'lib/filen_client.dart': 30,
  'lib/cli.dart': 5,
  'lib/paths.dart': 10,
  'lib/webdav_filesystem.dart': 5,
};

const defaultThreshold = 10;

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('Usage: dart tool/check_coverage.dart <lcov.info>');
    exit(1);
  }

  final lcovPath = args[0];
  final file = File(lcovPath);
  if (!file.existsSync()) {
    stderr.writeln('File not found: $lcovPath');
    exit(1);
  }

  final lines = file.readAsLinesSync();
  final coverage = <String, _FileCoverage>{};

  String? currentFile;

  for (final line in lines) {
    if (line.startsWith('SF:')) {
      currentFile = line.substring(3);
      coverage[currentFile!] = _FileCoverage();
    } else if (line.startsWith('DA:') && currentFile != null) {
      final parts = line.substring(3).split(',');
      if (parts.length >= 2) {
        final hits = int.tryParse(parts[1]) ?? 0;
        coverage[currentFile]!.totalLines++;
        if (hits > 0) coverage[currentFile]!.coveredLines++;
      }
    } else if (line == 'end_of_record') {
      currentFile = null;
    }
  }

  print('Per-file coverage report:');
  print('${'File'.padRight(40)} ${'Coverage'.padLeft(10)} ${'Threshold'.padLeft(10)} ${'Status'.padLeft(8)}');
  print('-' * 70);

  bool failed = false;

  for (final entry in coverage.entries) {
    final filePath = entry.key;
    final cov = entry.value;
    final pct = cov.percentage;

    // Normalize path for threshold lookup
    String? lookupPath;
    for (final key in thresholds.keys) {
      if (filePath.endsWith(key) || filePath.contains(key)) {
        lookupPath = key;
        break;
      }
    }

    final threshold = lookupPath != null
        ? thresholds[lookupPath]!
        : defaultThreshold;

    final status = pct >= threshold ? 'PASS' : 'FAIL';
    if (pct < threshold) failed = true;

    final displayPath = filePath.length > 38
        ? '...${filePath.substring(filePath.length - 35)}'
        : filePath;

    print(
        '${displayPath.padRight(40)} ${pct.toStringAsFixed(1).padLeft(8)}% ${threshold.toString().padLeft(8)}% ${status.padLeft(8)}');
  }

  print('');
  if (failed) {
    stderr.writeln('FAILED: Some files are below their coverage threshold.');
    exit(1);
  } else {
    print('PASSED: All files meet their coverage thresholds.');
  }
}

class _FileCoverage {
  int totalLines = 0;
  int coveredLines = 0;

  double get percentage =>
      totalLines == 0 ? 100.0 : (coveredLines / totalLines * 100);
}
