import 'package:arcadiaplus/src/utils/applied_configuration.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'large configurations retain identity without retaining their source',
    () {
      final source =
          '{"rules":[${List.filled(10000, '"域名.example"').join(',')}]}';
      final applied = AppliedConfiguration(source);
      expect(applied.retainedSource, isNull);
      expect(applied.matches(source), isTrue);
      expect(applied.matches(source.replaceFirst('域名', '域明')), isFalse);
      expect(applied.matches('$source '), isFalse);
    },
  );

  test(
    'extension rollback keeps the exact previous document when requested',
    () {
      const previous = '{"profile":"旧配置"}';
      final saved = AppliedConfiguration(previous, retainSource: true);
      final replacement = AppliedConfiguration(
        '{"profile":"新配置"}',
        retainSource: true,
      );
      expect(saved.retainedSource, previous);
      expect(saved.matches(previous), isTrue);
      expect(replacement.matches(previous), isFalse);
    },
  );
}
