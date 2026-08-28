/// Minimal semantic-version value type used by the update checker.
///
/// Handles the version shapes this project actually produces: release tags
/// (`v1.2.3`), pubspec versions with build metadata (`1.2.3+4`), and optional
/// pre-release identifiers (`1.2.3-beta.1`). Build metadata is ignored for
/// ordering, per the semver spec.
class Semver implements Comparable<Semver> {
  const Semver(this.major, this.minor, this.patch, {this.preRelease});

  final int major;
  final int minor;
  final int patch;
  final String? preRelease;

  static final RegExp _pattern = RegExp(
    r'^v?(\d+)\.(\d+)(?:\.(\d+))?(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$',
  );

  /// Parses [input], returning null when it is not a recognizable version.
  static Semver? tryParse(String input) {
    final match = _pattern.firstMatch(input.trim());
    if (match == null) return null;
    return Semver(
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3) ?? '0'),
      preRelease: match.group(4),
    );
  }

  /// Parses [input], throwing [FormatException] when invalid.
  static Semver parse(String input) {
    final result = tryParse(input);
    if (result == null) {
      throw FormatException('Invalid semantic version: "$input"');
    }
    return result;
  }

  bool isNewerThan(Semver other) => compareTo(other) > 0;

  @override
  int compareTo(Semver other) {
    if (major != other.major) return major.compareTo(other.major);
    if (minor != other.minor) return minor.compareTo(other.minor);
    if (patch != other.patch) return patch.compareTo(other.patch);
    return _comparePreRelease(preRelease, other.preRelease);
  }

  /// Semver precedence: a release outranks any of its pre-releases, and
  /// pre-release identifiers compare dot-segment by dot-segment (numeric
  /// segments numerically and below alphanumeric ones; on a common-prefix
  /// tie the shorter identifier list loses).
  static int _comparePreRelease(String? a, String? b) {
    if (a == null && b == null) return 0;
    if (a == null) return 1;
    if (b == null) return -1;

    final aParts = a.split('.');
    final bParts = b.split('.');
    final len = aParts.length < bParts.length ? aParts.length : bParts.length;
    for (var i = 0; i < len; i++) {
      final aNum = int.tryParse(aParts[i]);
      final bNum = int.tryParse(bParts[i]);
      int cmp;
      if (aNum != null && bNum != null) {
        cmp = aNum.compareTo(bNum);
      } else if (aNum != null) {
        cmp = -1; // numeric identifiers rank below alphanumeric ones
      } else if (bNum != null) {
        cmp = 1;
      } else {
        cmp = aParts[i].compareTo(bParts[i]);
      }
      if (cmp != 0) return cmp;
    }
    return aParts.length.compareTo(bParts.length);
  }

  @override
  String toString() =>
      '$major.$minor.$patch${preRelease == null ? '' : '-$preRelease'}';

  @override
  bool operator ==(Object other) => other is Semver && compareTo(other) == 0;

  @override
  int get hashCode => Object.hash(major, minor, patch, preRelease);
}
