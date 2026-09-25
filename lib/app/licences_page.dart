import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'brand.dart';
import 'loading.dart';
import 'theme.dart';

/// SIS-styled replacement for [showLicensePage]: every package that
/// registered a licence with [LicenseRegistry], grouped by name.
class SisLicencesPage extends StatelessWidget {
  const SisLicencesPage({
    super.key,
    required this.applicationName,
    required this.applicationVersion,
  });

  final String applicationName;
  final String applicationVersion;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Open-source licences')),
    body: FutureBuilder<List<LicenseEntry>>(
      future: LicenseRegistry.licenses.toList(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Center(child: SisLoadingLogo(size: 48));
        }
        final byPackage = <String, List<LicenseEntry>>{};
        for (final entry in snapshot.data!) {
          for (final package in entry.packages) {
            (byPackage[package] ??= []).add(entry);
          }
        }
        final packages = byPackage.keys.toList()..sort();
        return ListView(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SisLogo(size: 48),
                  const SizedBox(height: 12),
                  Text(
                    applicationName,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    applicationVersion,
                    style: TextStyle(color: SisBrand.of(context).muted),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            for (final package in packages)
              ListTile(
                title: Text(package),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => _PackageLicencePage(
                      package: package,
                      entries: byPackage[package]!,
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    ),
  );
}

class _PackageLicencePage extends StatelessWidget {
  const _PackageLicencePage({required this.package, required this.entries});

  final String package;
  final List<LicenseEntry> entries;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(package)),
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          for (final entry in entries)
            Padding(
              padding: const EdgeInsets.only(bottom: 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final paragraph in entry.paragraphs)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(paragraph.text),
                    ),
                ],
              ),
            ),
        ],
      ),
    ),
  );
}
