// AppearanceController against a fake store written from the
// AppearanceStore interface: a save that is held (slow disk) or that fails.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/appearance/application/appearance_controller.dart';
import 'package:sis/features/appearance/domain/appearance_settings.dart';

class HeldStore implements AppearanceStore {
  HeldStore({this.fail = false});

  final bool fail;
  final saves = <AppearanceSettings>[];
  Completer<void>? gate;

  @override
  Future<AppearanceSettings> load() async => const AppearanceSettings();

  @override
  Future<void> save(AppearanceSettings s) async {
    saves.add(s);
    if (gate != null) await gate!.future;
    if (fail) throw StateError('disk full');
  }
}

ProviderContainer containerWith(
  HeldStore store, {
  AppearanceSettings? initial,
}) {
  final c = ProviderContainer(
    overrides: [
      appearanceStoreProvider.overrideWithValue(store),
      if (initial != null) initialAppearanceProvider.overrideWithValue(initial),
    ],
  );
  addTearDown(c.dispose);
  return c;
}

typedef Setter = ({
  String name,
  Future<void> Function(AppearanceController) call,
  AppearanceSettings expected,
});

final List<Setter> setters = [
  (
    name: 'setTheme',
    call: (c) => c.setTheme(AppThemeId.forest),
    expected: const AppearanceSettings(themeId: AppThemeId.forest),
  ),
  (
    name: 'setSystemFont',
    call: (c) => c.setSystemFont(false),
    expected: const AppearanceSettings(systemFont: false),
  ),
  (
    name: 'setChatTextSize',
    call: (c) => c.setChatTextSize(TextSize.large),
    expected: const AppearanceSettings(chatTextSize: TextSize.large),
  ),
  (
    name: 'setAppTextSize',
    call: (c) => c.setAppTextSize(TextSize.small),
    expected: const AppearanceSettings(appTextSize: TextSize.small),
  ),
  (
    name: 'setLanguage',
    call: (c) => c.setLanguage(AppLanguage.tr),
    expected: const AppearanceSettings(language: AppLanguage.tr),
  ),
];

void main() {
  test('the store must be provided', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    expect(() => c.read(appearanceStoreProvider), throwsA(anything));
  });

  test('initial settings default to AppearanceSettings()', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    expect(c.read(initialAppearanceProvider), const AppearanceSettings());
  });

  test('starts from the settings read before runApp', () {
    const stored = AppearanceSettings(
      themeId: AppThemeId.rose,
      language: AppLanguage.en,
    );
    final c = containerWith(HeldStore(), initial: stored);
    expect(c.read(appearanceProvider), stored);
  });

  for (final s in setters) {
    test('${s.name} shows at once, before the save finishes', () async {
      final store = HeldStore()..gate = Completer<void>();
      final c = containerWith(store);
      final done = s.call(c.read(appearanceProvider.notifier));

      expect(c.read(appearanceProvider), s.expected);
      await pumpEventQueue();
      expect(store.saves, [s.expected]);

      store.gate!.complete();
      await done;
      expect(c.read(appearanceProvider), s.expected);
    });

    test('${s.name}: a failed save neither throws nor reverts', () async {
      final store = HeldStore(fail: true);
      final c = containerWith(store);
      await expectLater(s.call(c.read(appearanceProvider.notifier)), completes);
      expect(store.saves, [s.expected]);
      expect(c.read(appearanceProvider), s.expected);
    });
  }

  test('changes build on each other and each is saved whole', () async {
    final store = HeldStore();
    final c = containerWith(
      store,
      initial: const AppearanceSettings(themeId: AppThemeId.sunset),
    );
    final n = c.read(appearanceProvider.notifier);
    await n.setLanguage(AppLanguage.tr);
    await n.setChatTextSize(TextSize.small);
    const want = AppearanceSettings(
      themeId: AppThemeId.sunset,
      language: AppLanguage.tr,
      chatTextSize: TextSize.small,
    );
    expect(c.read(appearanceProvider), want);
    expect(store.saves.last, want);
  });
}
