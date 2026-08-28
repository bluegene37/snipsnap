import 'package:flutter_test/flutter_test.dart';
import 'package:snipsnap/services/update/semver.dart';

void main() {
  group('Semver.parse', () {
    test('parses plain version', () {
      final v = Semver.parse('1.2.3');
      expect(v.major, 1);
      expect(v.minor, 2);
      expect(v.patch, 3);
      expect(v.preRelease, isNull);
    });

    test('strips leading v prefix used by release tags', () {
      final v = Semver.parse('v1.0.0');
      expect(v.major, 1);
      expect(v.minor, 0);
      expect(v.patch, 0);
    });

    test('ignores build metadata as pubspec versions carry +N', () {
      final v = Semver.parse('1.0.0+1');
      expect(v.major, 1);
      expect(v.patch, 0);
      expect(v.preRelease, isNull);
    });

    test('captures pre-release identifiers', () {
      final v = Semver.parse('1.1.0-beta.2');
      expect(v.preRelease, 'beta.2');
    });

    test('tolerates missing patch segment', () {
      final v = Semver.parse('1.2');
      expect(v.major, 1);
      expect(v.minor, 2);
      expect(v.patch, 0);
    });

    test('parse throws on garbage, tryParse returns null', () {
      expect(() => Semver.parse('not-a-version'), throwsFormatException);
      expect(Semver.tryParse('not-a-version'), isNull);
      expect(Semver.tryParse(''), isNull);
      expect(Semver.tryParse('1.2.3.4'), isNull);
    });
  });

  group('Semver ordering', () {
    int cmp(String a, String b) => Semver.parse(a).compareTo(Semver.parse(b));

    test('equal versions compare as 0 regardless of decorations', () {
      expect(cmp('1.0.0', 'v1.0.0+1'), 0);
      expect(Semver.parse('v1.0.0+1'), Semver.parse('1.0.0'));
    });

    test('numeric compare, not string compare', () {
      expect(cmp('1.10.0', '1.9.0'), greaterThan(0));
      expect(cmp('1.9.0', '1.10.0'), lessThan(0));
    });

    test('major/minor/patch precedence', () {
      expect(cmp('2.0.0', '1.9.9'), greaterThan(0));
      expect(cmp('1.1.0', '1.0.9'), greaterThan(0));
      expect(cmp('1.0.1', '1.0.0'), greaterThan(0));
    });

    test('release outranks its own pre-release', () {
      expect(cmp('1.1.0', '1.1.0-beta'), greaterThan(0));
      expect(cmp('1.1.0-beta', '1.1.0'), lessThan(0));
    });

    test('pre-release identifiers follow semver precedence', () {
      expect(cmp('1.0.0-alpha', '1.0.0-alpha.1'), lessThan(0));
      expect(cmp('1.0.0-alpha.1', '1.0.0-beta'), lessThan(0));
      expect(cmp('1.0.0-beta.2', '1.0.0-beta.11'), lessThan(0));
      expect(cmp('1.0.0-beta.11', '1.0.0-rc.1'), lessThan(0));
      expect(cmp('1.0.0-rc.1', '1.0.0'), lessThan(0));
    });

    test('numeric pre-release segments rank below alphanumeric ones', () {
      expect(cmp('1.0.0-1', '1.0.0-alpha'), lessThan(0));
    });

    test('isNewerThan convenience', () {
      expect(Semver.parse('1.1.0').isNewerThan(Semver.parse('1.0.0')), isTrue);
      expect(Semver.parse('1.0.0').isNewerThan(Semver.parse('1.0.0')), isFalse);
      expect(Semver.parse('0.9.0').isNewerThan(Semver.parse('1.0.0')), isFalse);
    });
  });
}
