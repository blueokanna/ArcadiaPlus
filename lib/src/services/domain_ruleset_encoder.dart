import 'dart:io';
import 'dart:typed_data';

/// Write the sing-box v1 domain matcher that Corduit can load directly.
/// [source] contains validated ASCII full: and +. lines. Reverse their keys
/// in place and sort offsets so neither sorting nor walking the trie allocates
/// an object per domain or per trie node.
Future<void> encodeDomainRules(File source, File target, int entries) async {
  // SRS rules are ORed. Encode consecutive 1 MiB blocks as separate matchers
  // so even a 32 MiB input needs only one block of keys and offsets in RAM.
  final keys = Uint8List(1024 * 1024);
  final input = source.openSync();
  final body = File('${target.parent.path}/body');
  final sink = body.openWrite();
  var rules = 0;
  var total = 0;
  try {
    while (true) {
      final read = input.readIntoSync(keys);
      if (read == 0) break;
      var end = read;
      while (end > 0 && keys[end - 1] != 10) {
        end--;
      }
      if (end == 0) throw const FormatException('Incomplete domain key');
      if (end != read) input.setPositionSync(input.positionSync() - read + end);
      final block = Uint8List.sublistView(keys, 0, end);
      var count = 0;
      for (final byte in block) {
        if (byte == 10) count++;
      }
      await sink.addStream(_matcher(block, count, target.parent));
      total += count;
      rules++;
    }
  } finally {
    input.closeSync();
    await sink.close();
  }
  if (total != entries || total == 0) {
    throw const FormatException('Incomplete domain index');
  }
  Stream<List<int>> document() async* {
    yield _varint(rules);
    yield* body.openRead();
  }

  final output = target.openWrite()..add(const [83, 82, 83, 1]); // SRS, v1
  try {
    await output.addStream(document().transform(zlib.encoder));
  } finally {
    await output.close();
  }
}

List<int> _varint(int count) {
  final prefix = <int>[];
  while (count >= 128) {
    prefix.add((count & 127) | 128);
    count >>= 7;
  }
  return prefix..add(count);
}

Stream<List<int>> _matcher(
  Uint8List keys,
  int entries,
  Directory directory,
) async* {
  final offsets = Uint32List(entries);
  var start = 0;
  var write = 0;
  for (var i = 0; i < entries; i++) {
    final suffix = keys[start] == 43; // +.
    final domain = start + (suffix ? 2 : 5);
    final end = keys.indexOf(10, domain);
    if (end <= domain) throw const FormatException('Incomplete domain key');
    for (var left = domain, right = end - 1; left < right; left++, right--) {
      final byte = keys[left];
      keys[left] = keys[right];
      keys[right] = byte;
    }
    offsets[i] = write;
    for (var j = domain; j < end; j++) {
      final byte = keys[j];
      keys[write++] = byte >= 65 && byte <= 90 ? byte + 32 : byte;
    }
    if (suffix) keys[write++] = 10; // sing-box root-label marker
    keys[write++] = 0;
    start = end + 1;
  }
  offsets.sort((a, b) {
    while (keys[a] == keys[b]) {
      if (keys[a] == 0) return 0;
      a++;
      b++;
    }
    return keys[a] - keys[b];
  });

  final leaves = _Bitmap(File('${directory.path}/leaves'));
  final branches = _Bitmap(File('${directory.path}/branches'));
  final labels = _Bytes(File('${directory.path}/labels'));
  try {
    // Each frontier contains nonempty, disjoint ranges in sorted key order.
    // Advancing one depth at a time bounds it by the number of source entries.
    var current = Uint32List(2 * entries);
    var next = Uint32List(2 * entries);
    current[1] = entries;
    var length = 2;
    for (var depth = 0; length > 0; depth++) {
      var nextLength = 0;
      for (var r = 0; r < length; r += 2) {
        var pos = current[r];
        final end = current[r + 1];
        leaves.bit(keys[offsets[pos] + depth] == 0);
        while (pos < end && keys[offsets[pos] + depth] == 0) {
          pos++;
        }
        while (pos < end) {
          final label = keys[offsets[pos] + depth];
          labels.add(label);
          branches.bit(false);
          next[nextLength++] = pos;
          do {
            pos++;
          } while (pos < end && keys[offsets[pos] + depth] == label);
          next[nextLength++] = pos;
        }
        branches.bit(true);
      }
      final spare = current;
      current = next;
      next = spare;
      length = nextLength;
    }
  } finally {
    leaves.close();
    branches.close();
    labels.close();
  }

  yield const [0, 2, 0]; // default rule, domain item, matcher v0
  for (final part in [leaves, branches, labels]) {
    yield _varint(part.file.lengthSync() ~/ (part is _Bitmap ? 8 : 1));
    yield* part.file.openRead();
  }
  yield const [255, 0]; // end of conditions, invert=false
}

class _Bytes {
  _Bytes(this.file) : _output = file.openSync(mode: FileMode.write);
  final File file;
  final RandomAccessFile _output;
  final _buffer = Uint8List(65536);
  int _length = 0;
  void add(int value) {
    _buffer[_length++] = value;
    if (_length == _buffer.length) {
      _output.writeFromSync(_buffer);
      _length = 0;
    }
  }

  void close() {
    try {
      _output.writeFromSync(_buffer, 0, _length);
    } finally {
      _output.closeSync();
    }
  }
}

class _Bitmap extends _Bytes {
  _Bitmap(super.file);
  int _bits = 0;
  int _word = 0;
  void bit(bool value) {
    if (value) _word |= 1 << _bits;
    if (++_bits == 64) _flushWord();
  }

  void _flushWord() {
    for (var shift = 56; shift >= 0; shift -= 8) {
      add(_word >>> shift);
    }
    _word = 0;
    _bits = 0;
  }

  @override
  void close() {
    if (_bits > 0) _flushWord();
    super.close();
  }
}
