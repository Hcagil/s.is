import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/controls.dart';
import '../../../app/theme.dart';
import '../../../l10n/app_localizations.dart';
import '../application/auto_download_controller.dart';
import '../domain/auto_download_settings.dart';

/// Settings > Auto-download, WhatsApp style.
class AutoDownloadPage extends ConsumerWidget {
  const AutoDownloadPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(autoDownloadProvider);
    final controller = ref.read(autoDownloadProvider.notifier);
    final l = AppLocalizations.of(context);
    void preset(AutoDownloadPreset? p) {
      if (p != null) controller.setPreset(p);
    }

    return Scaffold(
      appBar: AppBar(title: Text(l.settingsAutoDownload)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _Section(l.autoDownloadSection),
            SisChoiceCard<AutoDownloadPreset?>(
              key: const ValueKey('autodl-enable'),
              value: AutoDownloadPreset.enable,
              groupValue: settings.preset,
              onChanged: preset,
              title: l.autoDownloadEnable,
            ),
            SisChoiceCard<AutoDownloadPreset?>(
              key: const ValueKey('autodl-wifionly'),
              value: AutoDownloadPreset.wifiOnly,
              groupValue: settings.preset,
              onChanged: preset,
              title: l.autoDownloadWifiOnly,
            ),
            SisChoiceCard<AutoDownloadPreset?>(
              key: const ValueKey('autodl-disabled'),
              value: AutoDownloadPreset.disabled,
              groupValue: settings.preset,
              onChanged: preset,
              title: l.autoDownloadDisabled,
            ),
            _Section(l.autoDownloadChoose),
            for (final network in NetworkKind.values)
              ListTile(
                key: ValueKey('autodl-row-${network.name}'),
                contentPadding: EdgeInsets.zero,
                title: Text(_networkLabel(l, network)),
                subtitle: Text(_valueLine(l, settings.kindsFor(network))),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () async {
                  final chosen = await showDialog<Set<MediaKind>>(
                    context: context,
                    builder: (_) => _KindsDialog(
                      title: _networkLabel(l, network),
                      initial: settings.kindsFor(network),
                    ),
                  );
                  if (chosen != null) controller.setKinds(network, chosen);
                },
              ),
          ],
        ),
      ),
    );
  }
}

String _networkLabel(AppLocalizations l, NetworkKind network) =>
    switch (network) {
      NetworkKind.mobile => l.autoDownloadMobile,
      NetworkKind.wifi => l.autoDownloadWifi,
      NetworkKind.roaming => l.autoDownloadRoaming,
    };

String _kindLabel(AppLocalizations l, MediaKind kind) => switch (kind) {
  MediaKind.photos => l.autoDownloadPhotos,
  MediaKind.audio => l.autoDownloadAudio,
  MediaKind.videos => l.autoDownloadVideos,
  MediaKind.documents => l.autoDownloadDocuments,
};

String _valueLine(AppLocalizations l, Set<MediaKind> kinds) {
  if (kinds.isEmpty) return l.autoDownloadNoMedia;
  if (kinds.length == MediaKind.values.length) return l.autoDownloadAllMedia;
  return [
    for (final kind in MediaKind.values)
      if (kinds.contains(kind)) _kindLabel(l, kind),
  ].join(', ');
}

class _Section extends StatelessWidget {
  const _Section(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w700,
        color: SisBrand.of(context).muted,
      ),
    ),
  );
}

/// The check list of one network: which kinds of media download on it.
class _KindsDialog extends StatefulWidget {
  const _KindsDialog({required this.title, required this.initial});

  final String title;
  final Set<MediaKind> initial;

  @override
  State<_KindsDialog> createState() => _KindsDialogState();
}

class _KindsDialogState extends State<_KindsDialog> {
  late final Set<MediaKind> _chosen = {...widget.initial};

  @override
  Widget build(BuildContext context) {
    final t = SisBrand.of(context);
    final l = AppLocalizations.of(context);
    final button = TextStyle(color: t.brand, fontWeight: FontWeight.w700);

    return Dialog(
      backgroundColor: t.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: t.line),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 300),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.title,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 10),
              for (final kind in MediaKind.values)
                InkWell(
                  key: ValueKey('autodl-kind-${kind.name}'),
                  onTap: () => setState(() {
                    if (!_chosen.remove(kind)) _chosen.add(kind);
                  }),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 9),
                    child: Row(
                      children: [
                        Container(
                          width: 20,
                          height: 20,
                          decoration: BoxDecoration(
                            color: _chosen.contains(kind) ? t.brand : null,
                            borderRadius: BorderRadius.circular(5),
                            border: Border.all(
                              color: _chosen.contains(kind) ? t.brand : t.line,
                              width: 2,
                            ),
                          ),
                          child: _chosen.contains(kind)
                              ? const Icon(
                                  Icons.check,
                                  size: 14,
                                  color: Colors.white,
                                )
                              : null,
                        ),
                        const SizedBox(width: 12),
                        Text(
                          _kindLabel(l, kind),
                          style: const TextStyle(fontSize: 15),
                        ),
                      ],
                    ),
                  ),
                ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    key: const ValueKey('autodl-cancel'),
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(l.autoDownloadCancel, style: button),
                  ),
                  TextButton(
                    key: const ValueKey('autodl-ok'),
                    onPressed: () => Navigator.of(context).pop(_chosen),
                    child: Text(l.autoDownloadOk, style: button),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
