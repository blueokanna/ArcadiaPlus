import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

void main() {
  test('stable release supports manual and tag triggers', () {
    final source = File('.github/workflows/release.yml').readAsStringSync();
    final workflow = loadYaml(source) as YamlMap;
    final triggers = workflow['on'] as YamlMap;

    expect(triggers.containsKey('push'), isTrue);
    expect(triggers.containsKey('workflow_dispatch'), isTrue);
    expect(source, contains(r'group: stable-release-${{ github.repository }}'));
    expect(source, isNot(contains('skip=true')));
    expect(source, contains("Release '\$tag' already exists"));
    expect(source, contains('flutter pub get --enforce-lockfile'));
    expect(
      source,
      contains('cargo test --manifest-path rust/Cargo.toml --workspace'),
    );
    expect(source, contains('flutter build apk --debug'));
    expect(source, contains('flutter build apk --release'));
    expect(source, contains('flutter build hap --release'));
    expect(source, contains('flutter build windows --release'));
    expect(source, contains('flutter build macos --release'));
    expect(source, contains('flutter build linux --release'));
    expect(source, contains('update-manifest.json'));
    expect(source, contains('SHA256SUMS'));
    expect(source, contains('ARCADIAPLUS_KEYSTORE_BASE64'));
    for (final secret in const [
      'ARCADIAPLUS_OHOS_KEYSTORE_BASE64',
      'ARCADIAPLUS_OHOS_KEYSTORE_PASSWORD',
      'ARCADIAPLUS_OHOS_KEY_ALIAS',
      'ARCADIAPLUS_OHOS_KEY_PASSWORD',
      'ARCADIAPLUS_OHOS_CERT_BASE64',
      'ARCADIAPLUS_OHOS_PROFILE_BASE64',
      'ARCADIAPLUS_OHOS_SIGN_ALG',
    ]) {
      expect(source, contains(secret));
    }
    expect(
      'secrets.ARCADIAPLUS_KEYSTORE_BASE64'.allMatches(source).length,
      1,
      reason: 'the Android and HarmonyOS signing identities stay separate',
    );
    expect(source, contains(r'ArcadiaPlus-${TAG}-ohos-arm64-'));
    expect(
      source,
      contains('needs: [validate, android, windows, macos, linux, ohos]'),
    );
    expect(source, contains('./gradlew :app:lintRelease'));
    expect(source, isNot(contains('run: ./gradlew lintRelease')));
    expect(source, contains(r'tag_name: ${{ steps.release.outputs.tag }}'));
    expect(source, contains('prerelease: false'));
    expect(source.toLowerCase(), isNot(contains('nightly')));
  });

  test(
    'continuous integration covers Flutter, Android, Rust, and HarmonyOS',
    () {
      final source = File('.github/workflows/ci.yml').readAsStringSync();
      final workflow = loadYaml(source) as YamlMap;
      final triggers = workflow['on'] as YamlMap;

      expect(triggers.containsKey('push'), isTrue);
      expect(triggers.containsKey('pull_request'), isTrue);
      expect(triggers.containsKey('workflow_dispatch'), isTrue);
      expect(source, contains('flutter pub get --enforce-lockfile'));
      expect(
        source,
        contains('dart format --output=none --set-exit-if-changed'),
      );
      expect(source, contains('flutter analyze'));
      expect(source, contains('flutter test'));
      expect(source, contains('flutter build apk --debug'));
      expect(source, contains('./gradlew :app:lintRelease'));
      expect(source, isNot(contains('run: ./gradlew lintRelease')));
      expect(source, contains('cargo fmt --all -- --check'));
      expect(source, contains('--all-targets --all-features --locked'));
      expect(source, contains('-D warnings'));
      expect(source, contains('name: HarmonyOS release HAP (unsigned)'));
      expect(source, contains('uses: ./.github/actions/setup-ohos'));
      expect(source, contains('uses: ./.github/actions/checkout-flutter-ohos'));
      expect(source, contains('flutter build hap --release --no-codesign'));
      expect(source, contains('bash ohos/scripts/build-rust-ohos.sh'));
    },
  );

  test(
    'the OHOS hvigorfile keeps the layout the Flutter toolchain detects',
    () {
      final source = File('ohos/hvigorfile.ts').readAsStringSync();
      expect(source, contains('flutter-hvigor-plugin'));
      expect(source, contains('flutterHvigorPlugin'));
    },
  );
}
