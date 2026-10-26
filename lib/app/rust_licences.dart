import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

const rustLicencesAsset = 'assets/licenses/RUST-LICENSES.txt';

/// Parses the generated notice file (tool/gen_rust_licences.dart): blocks are
/// separated by a line holding only `@@@@`; a block is a line of
/// comma-separated "name version" crates, a blank line, then the licence text.
Iterable<LicenseEntry> parseRustLicences(String notices) sync* {
  for (final block in notices.split('\n@@@@\n')) {
    if (block.trim().isEmpty) continue;
    final i = block.indexOf('\n\n');
    final crates = block
        .substring(0, i)
        .split(', ')
        .map((s) => s.substring(0, s.indexOf(' ')))
        .toSet()
        .toList();
    yield LicenseEntryWithLineBreaks(crates, block.substring(i + 2));
  }
}

/// Registers the Rust crates' licences. The asset is read only when the
/// licence page asks for them, so startup pays nothing.
void registerRustLicences() {
  LicenseRegistry.addLicense(() async* {
    final notices = await rootBundle.loadString(rustLicencesAsset);
    for (final entry in parseRustLicences(notices)) {
      yield entry;
    }
  });
}
