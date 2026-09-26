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
    'the OHOS toolchain archives are cached once, keyed by their digests',
    () {
      final setup = File('.github/actions/setup-ohos/action.yml')
          .readAsStringSync();
      final ci = File('.github/workflows/ci.yml').readAsStringSync();
      final release = File('.github/workflows/release.yml').readAsStringSync();

      // Restore and save live in the composite action both workflows already
      // call: one implementation, one place to keep honest.
      final steps =
          (((loadYaml(setup) as YamlMap)['runs'] as YamlMap)['steps']
                  as YamlList)
              .cast<YamlMap>();
      final uses = steps.map((step) => step['uses']).whereType<String>();
      expect(uses, contains('actions/cache/restore@v4'));
      expect(uses, contains('actions/cache/save@v4'));

      // The key is derived from the published digests, so a re-rolled
      // upstream archive misses the cache instead of being re-downloaded
      // against a stale entry on every run.
      expect(setup, contains('expected-clt-sha'));
      expect(setup, contains(r'ohos-toolchain-archives-${{ runner.os }}'));

      // The entry is saved as soon as the archives verify (a later failure
      // or cancellation must not lose it), and the runner drops each
      // archive once it has been unpacked.
      expect(setup, contains('steps.download.outputs.verified'));
      expect(setup, contains(r'rm -f "$CLT_ARCHIVE"'));
      expect(setup, contains(r'rm -f "$SDK_ARCHIVE"'));

      // Neither workflow carries a cache step of its own any more.
      expect(ci, isNot(contains('ohos-downloads-v1')));
      expect(release, isNot(contains('ohos-downloads-v1')));
    },
  );

  test(
    'the OHOS product keeps the fork-template SDK pair, never rewritten',
    () {
      final profile = File('ohos/build-profile.json5').readAsStringSync();
      final prepare = File('.github/actions/prepare-ohos-build/action.yml')
          .readAsStringSync();
      final setup = File('.github/actions/setup-ohos/action.yml')
          .readAsStringSync();

      // hvigor resolves compatibleSdkVersion against the SDK Manager and
      // aborts with 00303082 for anything the provisioned SDK does not
      // register; this pair is what the pinned fork template ships. The
      // values are checked in -- deriving them from SDK metadata at build
      // time produced exactly that failure.
      expect(profile, contains('"compatibleSdkVersion": "5.0.5(17)"'));
      expect(profile, contains('"targetSdkVersion": "26.0.0"'));
      expect(prepare, contains('OHOS SDK pair drifted'));
      expect(prepare, isNot(contains('OHOS_SDK_COMPATIBLE_VERSION')));
      expect(setup, isNot(contains('OHOS_SDK_COMPATIBLE_VERSION')));
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
