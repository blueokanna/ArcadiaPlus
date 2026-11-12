import 'package:arcadiaplus/src/providers/app_state_provider.dart';
import 'package:arcadiaplus/src/rust/types.dart';
import 'package:arcadiaplus/src/screens/connections_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

class ConnectionState extends ChangeNotifier implements AppStateProvider {
  @override
  bool get isServiceRunning => true;
  @override
  List<ActiveConnection> activeConnections = [connection('a'), connection('b')];
  @override
  BigInt totalUploadBytes = BigInt.zero;
  @override
  BigInt get totalDownloadBytes => BigInt.zero;
  @override
  String getFormattedTraffic(BigInt bytes) => bytes.toString();
  @override
  Future<void> refreshConnections() async {}
  @override
  Future<void> refreshStatus() async {}
  @override
  void discardConnectionSnapshot() => activeConnections = [];
  void update() => notifyListeners();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

ActiveConnection connection(String id) => ActiveConnection(
  id: id,
  inboundTag: 'SOCKS',
  outboundTag: 'DIRECT',
  host: '$id.example',
  destinationIp: '192.0.2.1',
  destinationPort: 443,
  protocol: 'SOCKS5',
  network: 'tcp',
  uploadBytes: BigInt.zero,
  downloadBytes: BigInt.zero,
  startTime: BigInt.zero,
  rule: 'DOMAIN-SUFFIX',
  rulePayload: 'example',
);

void main() {
  testWidgets(
    'traffic updates preserve rows and reordered rows preserve animation state',
    (tester) async {
      final state = ConnectionState();
      await tester.pumpWidget(
        ChangeNotifierProvider<AppStateProvider>.value(
          value: state,
          child: const MaterialApp(home: ConnectionsScreen()),
        ),
      );
      await tester.pumpAndSettle();
      final first = find.byKey(const ValueKey('a'));
      final row = tester.widget(first);
      final animationState = tester.state(first);
      state.totalUploadBytes = BigInt.from(99);
      state.update();
      await tester.pump();
      expect(identical(tester.widget(first), row), true);
      expect(find.text('99'), findsOneWidget);
      state.activeConnections = state.activeConnections.reversed.toList();
      state.update();
      await tester.pump();
      expect(identical(tester.state(first), animationState), true);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(state.activeConnections, isEmpty);
      state.dispose();
      expect(tester.takeException(), isNull);
    },
  );
}
