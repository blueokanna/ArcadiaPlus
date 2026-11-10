import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../utils/serial_task_queue.dart';

/// Owns one LAN proxy transaction, including PAC/WPAD restoration after a crash.
class WindowsSystemProxy {
  WindowsSystemProxy({
    this.channel = const MethodChannel('com.arcadiaplus/windows_proxy'),
    Future<File> Function()? snapshotFile,
  }) : _snapshotFile = snapshotFile ?? _defaultSnapshot;

  final MethodChannel channel;
  final Future<File> Function() _snapshotFile;
  final _changes = SerialTaskQueue();

  static Future<File> _defaultSnapshot() async {
    final directory = await getApplicationSupportDirectory();
    return File('${directory.path}/windows-proxy-connection.json');
  }

  Future<Map<String, Object>> read() async {
    final result = await channel.invokeMapMethod<String, Object>('read');
    return _validate(result);
  }

  static Map<String, Object> _validate(Object? raw) {
    if (raw is! Map ||
        raw['flags'] is! int ||
        (raw['flags'] as int) < 0 ||
        (raw['flags'] as int) > 15 ||
        raw['server'] is! String ||
        raw['bypass'] is! String ||
        raw['autoConfigUrl'] is! String) {
      throw const FormatException('Invalid saved Windows proxy connection');
    }
    return {
      'flags': raw['flags'] as int,
      'server': raw['server'] as String,
      'bypass': raw['bypass'] as String,
      'autoConfigUrl': raw['autoConfigUrl'] as String,
    };
  }

  static bool enabled(Map<String, Object> state) =>
      (state['flags'] as int) & 2 != 0 &&
      (state['server'] as String).trim().isNotEmpty;

  Future<void> enable(String endpoint, String bypass) => _changes.run(() async {
    final previous = await read();
    final file = await _snapshotFile();
    if (!await file.exists()) {
      await file.parent.create(recursive: true);
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(jsonEncode(previous), flush: true);
      await temporary.rename(file.path);
    } else {
      // Do not replace a valid crash-recovery snapshot or apply over corrupt data.
      _validate(jsonDecode(await file.readAsString()));
    }
    await channel.invokeMethod<void>('apply', {
      'flags': 3, // DIRECT | PROXY; PAC and auto-detect cannot supersede this endpoint.
      'server': endpoint,
      'bypass': bypass,
      'autoConfigUrl': '',
    });
    final actual = await read();
    if (actual['flags'] != 3 ||
        actual['server'] != endpoint ||
        actual['bypass'] != bypass ||
        actual['autoConfigUrl'] != '') {
      await channel.invokeMethod<void>('apply', previous);
      throw const FileSystemException(
        'Windows did not retain the proxy settings',
      );
    }
  });

  Future<void> disable() => _changes.run(() async {
    final file = await _snapshotFile();
    if (await file.exists()) {
      final saved = _validate(jsonDecode(await file.readAsString()));
      await channel.invokeMethod<void>('apply', saved);
      final actual = await read();
      if (saved.keys.any((key) => saved[key] != actual[key])) {
        throw const FileSystemException(
          'Windows did not restore the proxy settings',
        );
      }
      await file.delete();
    } else {
      final current = await read();
      await channel.invokeMethod<void>('apply', {
        ...current,
        'flags': ((current['flags'] as int) & ~2) | 1,
      });
      if (enabled(await read())) {
        throw const FileSystemException('Windows did not disable the proxy');
      }
    }
  });

  Future<bool> targets(int port) async {
    final state = await read();
    if (!enabled(state)) return false;
    return (state['server'] as String).split(';').any((entry) {
      final endpoint = entry.split('=').last.trim();
      final uri = Uri.tryParse('http://$endpoint');
      return uri != null &&
          uri.port == port &&
          (uri.host == '127.0.0.1' ||
              uri.host == 'localhost' ||
              uri.host == '::1' ||
              uri.host == '[::1]');
    });
  }
}
