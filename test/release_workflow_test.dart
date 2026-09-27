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

  test('the OHOS toolchain archive is cached once, keyed by its digest', () {
    final setup = File('.github/actions/setup-ohos/action.yml')
        .readAsStringSync();
    final ci = File('.github/workflows/ci.yml').readAsStringSync();
    final release = File('.github/workflows/release.yml').readAsStringSync();

    // Restore and save live in the composite action both workflows already
    // call: one implementation, one place to keep honest.
    final steps =
        (((loadYaml(setup) as YamlMap)['runs'] as YamlMap)['steps'] as YamlList)
            .cast<YamlMap>();
    final uses = steps.map((step) => step['uses']).whereType<String>();
    expect(uses, contains('actions/cache/restore@v4'));
    expect(uses, contains('actions/cache/save@v4'));

    // The key is derived from the published digest, so a re-rolled
    // upstream archive misses the cache instead of being re-downloaded
    // against a stale entry on every run. The older prefixes stay as
    // fallbacks so the retired two-archive entries are still reusable.
    expect(setup, contains('expected-clt-sha'));
    expect(setup, contains(r'ohos-clt-${{ runner.os }}'));
    expect(setup, contains(r'ohos-toolchain-archives-${{ runner.os }}'));

    // The entry is saved as soon as the archive verifies (a later failure
    // or cancellation must not lose it), and the runner drops it once it
    // has been unpacked.
    expect(setup, contains('steps.download.outputs.verified'));
    expect(setup, contains(r'rm -f "$CLT_ARCHIVE"'));

    // The SDK travels inside the command-line tools archive -- the action
    // must not download the retired OpenHarmony test payload again (its
    // 26.0.0 half broke `CompileResource` with 11201001), and the unpack
    // step checks the bundled SDK's halves by name.
    expect(setup, isNot(contains('openharmony-sdk')));
    expect(setup, isNot(contains('SDK_ARCHIVE')));
    expect(setup, isNot(contains('SDK_URL')));
    expect(setup, contains('sdk/default/openharmony/toolchains/restool'));
    expect(
      setup,
      contains('sdk/default/hms/toolchains/lib/libimage_transcoder_shared.so'),
    );

    // Neither workflow carries a cache step of its own any more.
    expect(ci, isNot(contains('ohos-downloads-v1')));
    expect(release, isNot(contains('ohos-downloads-v1')));
  });

  test(
    'the OHOS product keeps the fork-template SDK versions, never rewritten',
    () {
      final profile = File('ohos/build-profile.json5').readAsStringSync();
      final prepare = File('.github/actions/prepare-ohos-build/action.yml')
          .readAsStringSync();
      final setup = File('.github/actions/setup-ohos/action.yml')
          .readAsStringSync();

      // hvigor validates the product versions before the build starts:
      // anything the provisioned SDK cannot resolve aborts with 00303082,
      // and in HarmonyOS mode the bare `M.S.F` a revision here once pinned
      // as targetSdkVersion aborts with 00306042. The profile therefore
      // carries exactly what the pinned fork template ships -- an
      // `M.S.F(api)` compatibleSdkVersion and no targetSdkVersion -- and
      // the values stay checked in rather than derived at build time.
      expect(profile, contains('"compatibleSdkVersion": "5.1.0(18)"'));
      expect(profile, isNot(contains('"targetSdkVersion"')));
      expect(prepare, contains('OHOS compatibleSdkVersion drifted'));
      expect(prepare, contains('OHOS targetSdkVersion reappeared'));
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

  test('the OHOS bridge compiles its native entry points', () {
    final lib = File('rust/src/lib.rs').readAsStringSync();
    final ffi = File('rust/src/ohos_ffi.rs').readAsStringSync();
    final sh = File('ohos/scripts/build-rust-ohos.sh').readAsStringSync();
    final ps = File('ohos/scripts/build-rust-ohos.ps1').readAsStringSync();

    // The OHOS target is `target_os = "linux"` with `target_env = "ohos"`;
    // a module lib.rs never declares exports nothing, and the CMake link
    // of libarcadia_core.so dies on undefined arcadia_ohos_* symbols.
    expect(lib, contains('mod ohos_ffi'));
    expect(lib, contains('target_env = "ohos"'));
    for (final symbol in [
      'arcadia_ohos_start',
      'arcadia_ohos_stop',
      'arcadia_ohos_set_proxy_mode',
      'arcadia_ohos_set_protect_callback',
    ]) {
      expect(ffi, contains('fn $symbol('));
      // Both build scripts assert the symbol in the built static library.
      expect(sh, contains(symbol));
      expect(ps, contains(symbol));
    }
  });

  test('the OHOS ArkTS surface keeps the toolchain contracts', () {
    final entryPkg = File('ohos/entry/oh-package.json5').readAsStringSync();
    final vpn = File(
      'ohos/entry/src/main/ets/vpnextension/ArcadiaPlusVpnAbility.ets',
    ).readAsStringSync();
    final plugin = File('ohos/entry/src/main/ets/plugins/ArcadiaPlusPlugin.ets')
        .readAsStringSync();

    // `import arcadiaCore from 'libarcadia_core.so'` resolves its types
    // through this dependency; without it the module is `any` and
    // CompileArkTS fails on `arkts-no-any-unknown`.
    expect(entryPkg, contains('libarcadia_core.so'));
    expect(entryPkg, contains('src/main/cpp/types/libarcadia_core'));

    // `CommonEventSubscriber` has no `on` member; subscribers are wired
    // through `commonEventManager.subscribe`.
    expect(vpn, contains('commonEventManager.subscribe('));
    expect(plugin, contains('commonEventManager.subscribe('));
    expect(vpn, isNot(contains('subscriber.on(')));
    expect(plugin, isNot(contains('subscriber.on(')));

    // `RouteInfo.gateway` is a `NetAddress` (`address` is the string),
    // not a `LinkAddress`, and `ESObject` trips `arkts-no-any-unknown`.
    expect(vpn, contains('gateway: { address: TUN_ADDRESS, family: 1 }'));
    expect(vpn, contains('gateway: { address: TUN_V6_ADDRESS, family: 2 }'));
    expect(vpn, isNot(contains('as ESObject')));

    // The plugin follows the fork's own plugin template, and no result
    // object is a `Record`-cast literal.
    expect(plugin, contains('FlutterPluginBinding'));
    expect(plugin, contains('MethodCallHandler'));
    expect(plugin, contains('getUniqueClassName'));
    expect(plugin, isNot(contains('result.success({')));
  });

  test('the HAP jobs bring the hvigor log forward when the build fails', () {
    for (final path in [
      '.github/workflows/ci.yml',
      '.github/workflows/release.yml',
    ]) {
      final source = File(path).readAsStringSync();
      // `flutter build hap`'s own output dies with its step; the on-disk
      // hvigor log and the stage products are what survives, so a failure
      // report has to surface them explicitly.
      expect(source, contains('Report why the HAP build failed'));
      expect(source, contains('if: failure()'));
      expect(source, contains('.hvigor/outputs/build-logs'));
      // The tee'd copy of `flutter build hap`'s output is what the failure
      // report reads when the tool dies before hvigor ever runs.
      expect(source, contains('hap-build.log'));
      // The annotations are the one failure channel a reader without access
      // to the step log can still see, so the step must emit them.
      expect(source, contains('::error title='));
    }
  });

  test('the OHOS build warms and patches the embedding har', () {
    final prepare = File('.github/actions/prepare-ohos-build/action.yml')
        .readAsStringSync();
    final script = File('ohos/scripts/patch-flutter-ohos-har.py')
        .readAsStringSync();
    // The pinned SDK's KeyEvent has no isCapsLockOn/isNumLockOn, so the
    // embedding har must be patched after precache or CompileArkTS rejects
    // the embedding and the HAP build fails.
    expect(prepare, contains('precache --ohos --ohos_internal_build'));
    expect(prepare, contains('patch-flutter-ohos-har.py'));
    expect(script, contains('isCapsLockOn'));
    expect(script, contains('isNumLockOn'));
    // The same har's PiP bridge calls the process-level
    // window.getGlobalWindowMode(), which this SDK does not expose either,
    // so it is rewritten to the answer its own catch block already gave.
    expect(script, contains('getGlobalWindowMode'));
  });
}
