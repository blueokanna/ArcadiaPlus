import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:arcadiaplus/src/utils/serial_task_queue.dart';

void main() {
  test(
    'mutations finish in order and a failed task does not block the next',
    () async {
      final queue = SerialTaskQueue();
      final gate = Completer<void>();
      final events = <int>[];
      final first = queue.run(() async {
        await gate.future;
        events.add(1);
      });
      final failed = queue.run(() async {
        events.add(2);
        throw StateError('refused');
      });
      final failure = expectLater(failed, throwsStateError);
      final last = queue.run(() async {
        events.add(3);
        return 3;
      });
      await Future<void>.delayed(Duration.zero);
      expect(events, isEmpty);
      gate.complete();
      await first;
      await failure;
      expect(await last, 3);
      expect(events, [1, 2, 3]);
    },
  );
}
