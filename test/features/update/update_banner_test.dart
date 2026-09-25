// The update banner, from its contract: a flexible update that is
// downloading shows SIS's own progress line -- never Android's.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/loading.dart';
import 'package:sis/features/update/application/update_controller.dart';
import 'package:sis/features/update/domain/update_state.dart';
import 'package:sis/features/update/presentation/update_banner.dart';

class _Showing extends UpdateController {
  _Showing(this.shown);
  final UpdateState shown;
  @override
  Future<UpdateState> build() async => shown;
}

Future<void> pump(WidgetTester t, UpdateState state) async {
  await t.pumpWidget(
    ProviderScope(
      overrides: [updateControllerProvider.overrideWith(() => _Showing(state))],
      child: const MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: true),
          child: Scaffold(body: Column(children: [UpdateBanner()])),
        ),
      ),
    ),
  );
  await t.pump();
  await t.pump();
}

void main() {
  testWidgets('downloading shows SIS\'s progress line', (t) async {
    await pump(t, const UpdateDownloading());

    expect(find.byType(SisProgressLine), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('offered or ready: no progress line', (t) async {
    await pump(t, const UpdateAvailableFlexible(108));
    expect(find.byType(UpdateBanner), findsOneWidget);
    expect(find.byType(SisProgressLine), findsNothing);

    await pump(t, const UpdateReadyToInstall());
    expect(find.byType(SisProgressLine), findsNothing);
  });
}
