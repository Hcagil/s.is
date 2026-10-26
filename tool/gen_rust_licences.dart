// Regenerates assets/licenses/RUST-LICENSES.txt: the licences of every Rust crate in the native lib.
// Run inside the flutter container: docker compose run --rm flutter dart run tool/gen_rust_licences.dart
import 'dart:convert';
import 'dart:io';

const _targets = ['aarch64-linux-android', 'aarch64-apple-ios'];

Map<String, dynamic> _metadata(String target) {
  final result = Process.runSync('cargo', [
    'metadata',
    '--format-version',
    '1',
    '--locked',
    '--filter-platform',
    target,
  ], workingDirectory: 'rust');
  if (result.exitCode != 0) {
    stderr.write(result.stderr);
    exit(1);
  }
  return jsonDecode(result.stdout as String) as Map<String, dynamic>;
}

Set<String> _shippedIds(Map<String, dynamic> meta) {
  final byId = {
    for (final n in meta['resolve']['nodes'] as List<dynamic>)
      n['id'] as String: n as Map<String, dynamic>,
  };
  final visited = <String>{};
  final stack = <String>[meta['resolve']['root'] as String];
  while (stack.isNotEmpty) {
    final id = stack.removeLast();
    if (!visited.add(id)) continue;
    for (final dep in byId[id]!['deps'] as List<dynamic>) {
      if ((dep['dep_kinds'] as List<dynamic>).any((k) => k['kind'] == null)) {
        stack.add(dep['pkg'] as String);
      }
    }
  }
  return visited;
}

final _licenceFile = RegExp(
  r'^(LICEN[CS]E|COPYING|NOTICE|UNLICENSE)',
  caseSensitive: false,
);

/// The licence texts shipped inside a crate's directory, joined; '' when none.
String _licenceText(String name, String manifestPath) {
  final files = [
    for (final e in File(manifestPath).parent.listSync())
      if (e is File && _licenceFile.hasMatch(e.uri.pathSegments.last)) e,
  ]..sort((a, b) => a.uri.pathSegments.last.compareTo(b.uri.pathSegments.last));
  // Some published crates leave their licence out: the upstream copy is kept in tool/rust_licence_extras.
  final extra = File('tool/rust_licence_extras/$name.txt');
  if (files.isEmpty && extra.existsSync()) files.add(extra);
  return files
      .map(
        (f) => f
            .readAsStringSync()
            .replaceAll('\r\n', '\n')
            // Contact addresses in copyright lines are personal data: the name stays.
            .replaceAll(RegExp(r'\s*<[^<>\s]+@[^<>\s]+>'), '')
            .trim(),
      )
      .join('\n\n');
}

/// One block per distinct licence text: the crates sharing it, a blank line,
/// the text. Blocks are joined by a line holding only `@@@@`.
String _render(List<Map<String, dynamic>> packages) {
  final sorted = packages.toList()
    ..sort((a, b) {
      final c = (a['name'] as String).compareTo(b['name'] as String);
      return c != 0
          ? c
          : (a['version'] as String).compareTo(b['version'] as String);
    });
  final groups = <String, List<String>>{};
  var missing = false;
  for (final p in sorted) {
    final text = _licenceText(
      p['name'] as String,
      p['manifest_path'] as String,
    );
    if (text.isEmpty) {
      stderr.writeln(
        'no licence file: ${p['name']} ${p['version']} (${p['license']})',
      );
      missing = true;
      continue;
    }
    groups.putIfAbsent(text, () => []).add('${p['name']} ${p['version']}');
  }
  if (missing) exit(1);
  return '${[for (final e in groups.entries) '${e.value.join(', ')}\n\n${e.key}'].join('\n@@@@\n')}\n';
}

void main() {
  final metas = [for (final t in _targets) _metadata(t)];
  final ids = {for (final m in metas) ..._shippedIds(m)};
  final byId = <String, Map<String, dynamic>>{};
  for (final m in metas) {
    for (final p in m['packages'] as List<dynamic>) {
      // The root crate (ours) has no registry source: it is not a notice.
      if (ids.contains(p['id']) && p['source'] != null) {
        byId[p['id'] as String] = p as Map<String, dynamic>;
      }
    }
  }
  File('assets/licenses/RUST-LICENSES.txt')
      .writeAsStringSync(_render(byId.values.toList()));
  stdout.writeln('${byId.length} crates');
}
