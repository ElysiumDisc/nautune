import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nautune/utils/debouncer.dart';

void main() {
  group('Debouncer', () {
    test('fires the action exactly once after the delay elapses', () {
      fakeAsync((async) {
        final d = Debouncer(delay: const Duration(milliseconds: 200));
        var calls = 0;

        d.run(() => calls++);
        async.elapse(const Duration(milliseconds: 199));
        expect(calls, 0);
        async.elapse(const Duration(milliseconds: 1));
        expect(calls, 1);
      });
    });

    test('cancels a pending action when run() is called again', () {
      fakeAsync((async) {
        final d = Debouncer(delay: const Duration(milliseconds: 200));
        var firstCalled = false;
        var secondCalled = false;

        d.run(() => firstCalled = true);
        async.elapse(const Duration(milliseconds: 100));
        d.run(() => secondCalled = true);
        async.elapse(const Duration(milliseconds: 199));
        expect(firstCalled, false);
        expect(secondCalled, false);
        async.elapse(const Duration(milliseconds: 1));
        expect(firstCalled, false);
        expect(secondCalled, true);
      });
    });

    test('isPending reports whether a timer is queued', () {
      fakeAsync((async) {
        final d = Debouncer(delay: const Duration(milliseconds: 100));
        expect(d.isPending, false);
        d.run(() {});
        expect(d.isPending, true);
        async.elapse(const Duration(milliseconds: 100));
        expect(d.isPending, false);
      });
    });

    test('cancel() drops the pending action', () {
      fakeAsync((async) {
        final d = Debouncer(delay: const Duration(milliseconds: 100));
        var called = false;
        d.run(() => called = true);
        d.cancel();
        async.elapse(const Duration(seconds: 1));
        expect(called, false);
        expect(d.isPending, false);
      });
    });
  });

  group('Throttler', () {
    test('runs the first action immediately', () {
      fakeAsync((async) {
        final t = Throttler(interval: const Duration(milliseconds: 100));
        var calls = 0;
        t.run(() => calls++);
        expect(calls, 1);
      });
    });

    test('queues a single trailing call during the cooldown window', () {
      fakeAsync((async) {
        final t = Throttler(interval: const Duration(milliseconds: 100));
        var results = <String>[];
        t.run(() => results.add('a'));      // immediate
        async.elapse(const Duration(milliseconds: 10));
        t.run(() => results.add('b'));      // queued
        async.elapse(const Duration(milliseconds: 10));
        t.run(() => results.add('c'));      // replaces 'b' (only latest queued)
        async.elapse(const Duration(milliseconds: 200));
        expect(results, ['a', 'c']);
      });
    });

    test('cancel() drops the queued trailing call', () {
      fakeAsync((async) {
        final t = Throttler(interval: const Duration(milliseconds: 100));
        var calls = 0;
        t.run(() => calls++);              // immediate -> 1
        t.run(() => calls++);              // queued
        t.cancel();
        async.elapse(const Duration(seconds: 1));
        expect(calls, 1);
      });
    });
  });
}
