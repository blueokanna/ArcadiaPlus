import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:arcadiaplus/src/utils/route_page_state.dart';

void main() {
  testWidgets(
    'page recycling preserves scroll offset without retaining the page',
    (tester) async {
      Widget page() => MaterialApp(
        home: PageStorage(
          bucket: RoutePageState.forPath('/scroll-fixture'),
          child: ListView.builder(
            key: const PageStorageKey('list'),
            itemExtent: 50,
            itemCount: 100,
            itemBuilder: (_, index) => Text('row $index'),
          ),
        ),
      );
      await tester.pumpWidget(page());
      await tester.drag(find.byType(ListView), const Offset(0, -600));
      await tester.pumpAndSettle();
      final before = tester
          .state<ScrollableState>(find.byType(Scrollable))
          .position
          .pixels;
      expect(before, greaterThan(0));
      await tester.pumpWidget(const MaterialApp(home: Text('another page')));
      await tester.pumpWidget(page());
      await tester.pumpAndSettle();
      expect(
        tester.state<ScrollableState>(find.byType(Scrollable)).position.pixels,
        before,
      );
    },
  );
  test(
    'route state is bounded and recently used destinations stay resident',
    () {
      final first = RoutePageState.forPath('/first');
      for (var index = 0; index < RoutePageState.capacity; index++) {
        RoutePageState.forPath('/other/$index');
      }
      expect(identical(first, RoutePageState.forPath('/first')), isFalse);
      final latest = RoutePageState.forPath('/latest');
      expect(identical(latest, RoutePageState.forPath('/latest')), isTrue);
    },
  );
}
