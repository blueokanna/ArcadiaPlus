import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

void main() {
  final action = loadYaml(
    File('.github/actions/setup-android-ndk/action.yml').readAsStringSync(),
  ) as YamlMap;
  final steps = (action['runs'] as YamlMap)['steps'] as YamlList;
  final script = (steps.single as YamlMap)['run'] as String;
  final String bash;
  if (Platform.isWindows) {
    final git = Process.runSync('git', ['--exec-path']);
    if (git.exitCode != 0) {
      throw StateError('Git for Windows is required to test CI shell scripts.');
    }
    final root = Directory((git.stdout as String).trim()).parent.parent.parent;
    bash = '${root.path}/bin/bash.exe';
  } else {
    bash = 'bash';
  }

  late Directory fixture;
  late File environmentFile;
  late String sdk;
  late String toolchain;

  void write(String path, String content) {
    File(path)
      ..createSync(recursive: true)
      ..writeAsStringSync(content);
  }

  ProcessResult run({String target = 'aarch64-linux-android'}) {
    return Process.runSync(
      bash,
      ['--noprofile', '--norc', '${fixture.path}/setup.sh'],
      environment: {
        'GITHUB_WORKSPACE': fixture.path.replaceAll(r'\', '/'),
        'GITHUB_ENV': environmentFile.path.replaceAll(r'\', '/'),
        'ANDROID_HOME': sdk,
        'RUNNER_OS': 'Linux',
        'RUST_ANDROID_TARGET': target,
      },
    );
  }

  setUp(() {
    fixture = Directory.systemTemp.createTempSync('arcadia ndk ');
    sdk = '${fixture.path.replaceAll(r'\', '/')}/Android SDK';
    toolchain =
        '$sdk/ndk/28.2.13676358/toolchains/llvm/prebuilt/linux-x86_64/bin';
    environmentFile = File('${fixture.path}/environment')
      ..writeAsStringSync('');
    write('${fixture.path}/setup.sh', script);
    write(
      '${fixture.path}/android/app/build.gradle.kts',
      'android {\n    ndkVersion = "28.2.13676358"\n'
          '    defaultConfig {\n        minSdk = 24\n    }\n}\n',
    );
    write(
      '$sdk/cmdline-tools/latest/bin/sdkmanager',
      '#!/usr/bin/env bash\n[[ "\$1" == "ndk;28.2.13676358" ]]\n',
    );
    for (final tool in [
      'clang',
      'llvm-ar',
      for (final triple in [
        'aarch64-linux-android',
        'armv7a-linux-androideabi',
        'i686-linux-android',
        'x86_64-linux-android',
      ]) ...['${triple}24-clang', '${triple}24-clang++'],
    ]) {
      write('$toolchain/$tool', '#!/usr/bin/env bash\nexit 0\n');
    }
    final chmod = Process.runSync(bash, [
      '-c',
      'chmod -R u+x "\$1"',
      'chmod',
      sdk,
    ]);
    expect(chmod.exitCode, 0, reason: '${chmod.stderr}');
  });

  tearDown(() => fixture.deleteSync(recursive: true));

  for (final target in [
    'aarch64-linux-android',
    'armv7-linux-androideabi',
    'i686-linux-android',
    'x86_64-linux-android',
  ]) {
    test('standalone $target exports both cc-rs aliases and a linker', () {
      final result = run(target: target);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      final env = Map.fromEntries(
        environmentFile.readAsLinesSync().map((line) {
          final separator = line.indexOf('=');
          return MapEntry(
            line.substring(0, separator),
            line.substring(separator + 1),
          );
        }),
      );
      final triple = target == 'armv7-linux-androideabi'
          ? 'armv7a-linux-androideabi'
          : target;
      final key = target.replaceAll('-', '_');
      expect(env.length, 7);
      for (final alias in [target, key]) {
        expect(env['CC_$alias'], '$toolchain/${triple}24-clang');
        expect(env['CXX_$alias'], '$toolchain/${triple}24-clang++');
        expect(env['AR_$alias'], '$toolchain/llvm-ar');
      }
      expect(
        env['CARGO_TARGET_${key.toUpperCase()}_LINKER'],
        env['CC_$target'],
      );
    });
  }

  test('Flutter installation leaves ABI compiler selection to Cargokit', () {
    final result = run(target: '');
    expect(result.exitCode, 0, reason: '${result.stderr}');
    expect(environmentFile.readAsStringSync(), isEmpty);
  });

  test('missing version pin fails instead of accepting the runner default', () {
    write('${fixture.path}/android/app/build.gradle.kts', 'minSdk = 24\n');
    final result = run();
    expect(result.exitCode, isNot(0));
    expect(result.stdout, contains('Expected one explicit ndkVersion'));
    expect(environmentFile.readAsStringSync(), isEmpty);
  });

  test('missing C++ compiler fails before exporting partial configuration', () {
    File('$toolchain/aarch64-linux-android24-clang++').deleteSync();
    final result = run();
    expect(result.exitCode, isNot(0));
    expect(result.stdout, contains('Missing Android tool:'));
    expect(environmentFile.readAsStringSync(), isEmpty);
  });

  test('sdkmanager failure is propagated', () {
    write(
      '$sdk/cmdline-tools/latest/bin/sdkmanager',
      '#!/usr/bin/env bash\nexit 23\n',
    );
    final result = run();
    expect(result.exitCode, 23);
    expect(environmentFile.readAsStringSync(), isEmpty);
  });

  test('Cargo configs cannot override the Android toolchain selected by the build', () {
    for (final directory in ['.cargo', 'rust/.cargo']) {
      for (final name in ['config', 'config.toml']) {
        final file = File('$directory/$name');
        if (!file.existsSync()) continue;
        final source = file
            .readAsLinesSync()
            .where((line) => !line.trimLeft().startsWith('#'))
            .join('\n');
        expect(
          source,
          isNot(
            matches(
              RegExp(
                r'^\s*(?:\[target\.[^\]\n]*android|["\x27]?(?:CC|CXX|AR|CARGO_TARGET_)[^=\n]*ANDROID)',
                caseSensitive: false,
                multiLine: true,
              ),
            ),
          ),
          reason:
              '${file.path}: Android compilers must come from the selected NDK, not Cargo defaults.',
        );
      }
    }
  });
}
