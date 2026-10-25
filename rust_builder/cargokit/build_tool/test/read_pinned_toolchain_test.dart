import 'dart:io';

import 'package:build_tool/src/builder.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

void main() {
  late Directory dir;
  late String toml;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('toolchain_test');
    toml = path.join(dir.path, 'rust-toolchain.toml');
  });

  tearDown(() => dir.deleteSync(recursive: true));

  void write(String content) => File(toml).writeAsStringSync(content);

  Matcher buildException(List<String> parts) =>
      throwsA(isA<BuildException>().having((e) => e.toString(), 'toString',
          allOf(parts.map(contains).toList())));

  void expectUnreadable(String content) {
    write(content);
    expect(
        () => readPinnedToolchain(dir.path),
        buildException([
          'BuildException: Cannot read the compiler version from $toml: '
              'expected a line channel = "x.y.z" (double or single quoted) '
              'under [toolchain].',
        ]));
  }

  group('reads the pinned channel', () {
    test('double quotes', () {
      write('[toolchain]\nchannel = "1.99.0"\nprofile = "minimal"\n');
      expect(readPinnedToolchain(dir.path), '1.99.0');
    });

    test('single quotes', () {
      write("[toolchain]\nchannel = '1.98.1'\nprofile = \"minimal\"\n");
      expect(readPinnedToolchain(dir.path), '1.98.1');
    });

    test('trailing comment', () {
      write('[toolchain]\nchannel = "1.97.2" # pinned\n');
      expect(readPinnedToolchain(dir.path), '1.97.2');
    });

    test('another table before [toolchain]', () {
      write('[other]\nchannel = "9.9.9"\n[toolchain]\nchannel = "1.99.0"\n');
      expect(readPinnedToolchain(dir.path), '1.99.0');
    });
  });

  group('missing file stops the build', () {
    test('missing file', () {
      expect(
          () => readPinnedToolchain(dir.path),
          buildException([
            'BuildException: Missing $toml: it must pin the Rust compiler '
                'with channel = "x.y.z" under [toolchain].',
          ]));
    });

    // The contract lists this case both as "missing" (.toml absent) and as
    // "unreadable"; assert only what both readings share: it stops, naming
    // the .toml path, and never reads the old plain file.
    test('only an old plain rust-toolchain file', () {
      File(path.join(dir.path, 'rust-toolchain')).writeAsStringSync('1.99.0\n');
      expect(() => readPinnedToolchain(dir.path), buildException([toml]));
    });
  });

  group('unreadable file stops the build', () {
    test('inline table', () {
      expectUnreadable('toolchain = { channel = "1.99.0" }\n');
    });

    test('channel before the header', () {
      expectUnreadable(
          'channel = "1.99.0"\n[toolchain]\nprofile = "minimal"\n');
    });

    test('channel under another table', () {
      expectUnreadable(
          '[toolchain]\nprofile = "minimal"\n[other]\nchannel = "1.99.0"\n');
    });

    test('unquoted value', () {
      expectUnreadable('[toolchain]\nchannel = 1.99.0\n');
    });

    test('no channel line', () {
      expectUnreadable('[toolchain]\nprofile = "minimal"\n');
    });

    test('empty file', () {
      expectUnreadable('');
    });
  });

  // Tests run with the package dir (rust_builder/cargokit/build_tool) as cwd.
  test('the repository pin parses', () {
    final channel = readPinnedToolchain(path.join('..', '..', '..', 'rust'));
    expect(channel, matches(RegExp(r'^\d+\.\d+\.\d+$')));
  });
}
