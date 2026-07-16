import 'package:test/test.dart';
import 'package:filen_client/memory_gate.dart';

void main() {
  group('MemoryGate', () {
    test('starts with zero bytes', () {
      final gate = MemoryGate(maxBytes: 100);
      expect(gate.currentBytes, equals(0));
      expect(gate.hasCapacity, isTrue);
    });

    test('acquire increases currentBytes', () async {
      final gate = MemoryGate(maxBytes: 100);
      await gate.acquire(50);
      expect(gate.currentBytes, equals(50));
    });

    test('release decreases currentBytes', () async {
      final gate = MemoryGate(maxBytes: 100);
      await gate.acquire(50);
      gate.release(30);
      expect(gate.currentBytes, equals(20));
    });

    test('release does not go below zero', () async {
      final gate = MemoryGate(maxBytes: 100);
      await gate.acquire(10);
      gate.release(50);
      expect(gate.currentBytes, equals(0));
    });

    test('acquire waits when over capacity', () async {
      final gate = MemoryGate(maxBytes: 100);
      await gate.acquire(80);

      // This should block because 80 + 30 > 100
      bool completed = false;
      final future = gate.acquire(30).then((_) => completed = true);

      // Give it a moment - should NOT complete
      await Future.delayed(Duration(milliseconds: 50));
      expect(completed, isFalse);

      // Release to make room
      gate.release(80);

      // Now should complete
      await future;
      expect(completed, isTrue);
      expect(gate.currentBytes, equals(30));
    });

    test('multiple waiters are served in order', () async {
      final gate = MemoryGate(maxBytes: 100);
      await gate.acquire(90);

      final order = <int>[];

      final f1 = gate.acquire(20).then((_) => order.add(1));
      final f2 = gate.acquire(20).then((_) => order.add(2));

      await Future.delayed(Duration(milliseconds: 10));
      expect(order, isEmpty);

      gate.release(90);
      await Future.wait([f1, f2]);

      expect(order, equals([1, 2]));
    });

    test('default maxBytes is 256MB', () {
      final gate = MemoryGate();
      expect(gate.maxBytes, equals(256 * 1024 * 1024));
    });
  });
}
