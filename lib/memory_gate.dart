/// Memory-gated concurrency for upload operations.
///
/// Limits the total bytes held in-flight during concurrent uploads
/// by checking available system memory and reserving slots.
/// Modeled after internxt-dart's MemoryGate.
import 'dart:async';
import 'dart:io';

class MemoryGate {
  /// Maximum bytes allowed in-flight at once.
  final int maxBytes;

  /// Safety margin: keep at least this many bytes free.
  final int safetyMarginBytes;

  int _currentBytes = 0;
  final _waiters = <_MemoryWaiter>[];

  MemoryGate({
    this.maxBytes = 256 * 1024 * 1024, // 256 MB default
    this.safetyMarginBytes = 1024 * 1024 * 1024, // 1 GB safety margin
  });

  /// Current bytes reserved.
  int get currentBytes => _currentBytes;

  /// Whether there's capacity for [bytes] more.
  bool get hasCapacity => _currentBytes < maxBytes;

  /// Acquire [bytes] worth of memory. Waits if capacity is exceeded.
  Future<void> acquire(int bytes) async {
    // System-memory probing is opt-in: with [safetyMarginBytes] == 0 the gate
    // is a pure fixed byte budget. That matters for PER-CHUNK gating (Step 1),
    // where polling system memory on every chunk would spawn a `vm_stat`
    // subprocess per 1 MB and serialise dispatch — defeating the concurrency.
    if (safetyMarginBytes > 0) {
      final availableMemory = await _getAvailableMemory();
      if (availableMemory != null &&
          availableMemory < safetyMarginBytes + bytes) {
        // Wait for memory to free up
        final completer = Completer<void>();
        _waiters.add(_MemoryWaiter(bytes: bytes, completer: completer));
        return completer.future;
      }
    }

    if (_currentBytes + bytes > maxBytes) {
      final completer = Completer<void>();
      _waiters.add(_MemoryWaiter(bytes: bytes, completer: completer));
      return completer.future;
    }

    _currentBytes += bytes;
  }

  /// Release [bytes] of previously acquired memory.
  void release(int bytes) {
    _currentBytes -= bytes;
    if (_currentBytes < 0) _currentBytes = 0;
    _processWaiters();
  }

  void _processWaiters() {
    while (_waiters.isNotEmpty) {
      final waiter = _waiters.first;
      if (_currentBytes + waiter.bytes <= maxBytes) {
        _waiters.removeAt(0);
        _currentBytes += waiter.bytes;
        waiter.completer.complete();
      } else {
        break;
      }
    }
  }

  /// Get available system memory in bytes.
  /// Returns null if detection fails.
  static Future<int?> _getAvailableMemory() async {
    try {
      if (Platform.isLinux) {
        return _getLinuxAvailableMemory();
      } else if (Platform.isMacOS) {
        return _getMacOSAvailableMemory();
      }
    } catch (_) {}
    return null;
  }

  static int? _getLinuxAvailableMemory() {
    try {
      final meminfo = File('/proc/meminfo').readAsStringSync();
      // Look for MemAvailable line
      for (final line in meminfo.split('\n')) {
        if (line.startsWith('MemAvailable:')) {
          final parts = line.split(RegExp(r'\s+'));
          if (parts.length >= 2) {
            final kb = int.tryParse(parts[1]);
            if (kb != null) return kb * 1024;
          }
        }
      }
    } catch (_) {}
    return null;
  }

  static Future<int?> _getMacOSAvailableMemory() async {
    try {
      final result = await Process.run('vm_stat', []);
      if (result.exitCode != 0) return null;

      final output = result.stdout.toString();
      int freePages = 0;

      for (final line in output.split('\n')) {
        if (line.contains('Pages free:') ||
            line.contains('Pages inactive:') ||
            line.contains('Pages purgeable:')) {
          final match =
              RegExp(r'(\d+)').firstMatch(line.substring(line.indexOf(':')));
          if (match != null) {
            freePages += int.tryParse(match.group(1)!) ?? 0;
          }
        }
      }

      // macOS page size is typically 16384 on ARM, 4096 on Intel
      final pageSize = Platform.version.contains('arm') ? 16384 : 4096;
      return freePages * pageSize;
    } catch (_) {}
    return null;
  }
}

class _MemoryWaiter {
  final int bytes;
  final Completer<void> completer;

  _MemoryWaiter({required this.bytes, required this.completer});
}

/// A counting semaphore that bounds the *number* of concurrent in-flight chunk
/// transfers. Paired with [MemoryGate] (which bounds the bytes in flight),
/// it caps chunk concurrency by both count and memory — the Step 1 model.
class ChunkSemaphore {
  int _permits;
  final _queue = <Completer<void>>[];

  ChunkSemaphore(this._permits) {
    if (_permits < 1) _permits = 1;
  }

  /// Permits currently available (for tests/diagnostics).
  int get availablePermits => _permits;

  /// Acquire one permit, waiting in FIFO order if none are free.
  Future<void> acquire() {
    if (_permits > 0) {
      _permits--;
      return Future.value();
    }
    final c = Completer<void>();
    _queue.add(c);
    return c.future;
  }

  /// Release one permit, handing it to the next waiter if any.
  void release() {
    if (_queue.isNotEmpty) {
      _queue.removeAt(0).complete();
    } else {
      _permits++;
    }
  }
}
