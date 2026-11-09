/// Release identity: semantic version followed by the Flutter build revision.
/// Unlike SemVer precedence, app updates must compare the numeric revision.
class ReleaseVersion implements Comparable<ReleaseVersion> {
  const ReleaseVersion(this.major, this.minor, this.patch, [this.build = 0]);
  final int major;
  final int minor;
  final int patch;
  final int build;

  factory ReleaseVersion.parse(String value) {
    final match = RegExp(r'^(\d+)\.(\d+)\.(\d+)(?:\+(\d+))?$')
        .firstMatch(value);
    if (match == null) throw FormatException('Invalid release version: $value');
    return ReleaseVersion(
      int.parse(match[1]!),
      int.parse(match[2]!),
      int.parse(match[3]!),
      int.parse(match[4] ?? '0'),
    );
  }

  factory ReleaseVersion.installed(
    String version,
    String buildNumber, {
    required bool android,
  }) {
    final base = ReleaseVersion.parse(version);
    var revision = int.tryParse(buildNumber) ?? base.build;
    // Android stores the semantic prefix in versionCode, unlike desktop/iOS.
    final prefix =
        base.major * 100000000 + base.minor * 1000000 + base.patch * 10000;
    if (android && revision >= prefix && revision < prefix + 10000) {
      revision -= prefix;
    }
    return ReleaseVersion(base.major, base.minor, base.patch, revision);
  }

  String get base => '$major.$minor.$patch';
  @override
  String toString() => build == 0 ? base : '$base+$build';

  @override
  int compareTo(ReleaseVersion other) {
    final left = [major, minor, patch, build];
    final right = [other.major, other.minor, other.patch, other.build];
    for (var i = 0; i < left.length; i++) {
      final order = left[i].compareTo(right[i]);
      if (order != 0) return order;
    }
    return 0;
  }
}
