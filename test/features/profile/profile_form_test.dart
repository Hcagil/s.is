// ProfileForm from its contract: what a member can submit, when, and what
// they see while the tag is checked. The availability check goes through the
// real ownProfileProvider to a fake repository that answers like the
// database — and, like the network, not instantly and not in order.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/profile/application/profile_controller.dart';
import 'package:sis/features/profile/domain/own_profile.dart';
import 'package:sis/features/profile/presentation/profile_form.dart';

import '../../support/fakes.dart';

const me = OwnProfile(
  userId: 'u1',
  displayName: 'Maya',
  tag: 'maya',
  onboardingDone: true,
);

const nameKey = ValueKey('profile-name');
const tagKey = ValueKey('profile-tag');
const submitKey = ValueKey('profile-submit');
const errorKey = ValueKey('profile-error');

/// Well past the ~400 ms debounce.
const settle = Duration(milliseconds: 600);

final takenText = find.textContaining(
  RegExp('taken|in use|not available|unavailable', caseSensitive: false),
);

class Harness {
  Harness(this.fake);
  final ProfileFake fake;
  final submitted = <(String, String)>[];

  Future<Result<OwnProfile>> onSubmit(String name, String tag) async {
    submitted.add((name, tag));
    return fake.save(displayName: name, tag: tag);
  }
}

/// Mounted the way production mounts it: under a widget that watches the
/// profile, as the settings screen and the session gate both do.
Future<Harness> pumpForm(WidgetTester t, ProfileFake fake) async {
  final h = Harness(fake);
  await t.pumpWidget(
    ProviderScope(
      overrides: [profileRepositoryProvider.overrideWithValue(fake)],
      child: MaterialApp(
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) =>
                switch (ref.watch(ownProfileProvider)) {
                  AsyncData(:final value) => ProfileForm(
                    profile: value,
                    submitLabel: 'Save',
                    onSubmit: h.onSubmit,
                  ),
                  _ => const SizedBox(),
                },
          ),
        ),
      ),
    ),
  );
  await t.pumpAndSettle();
  expect(find.byKey(tagKey), findsOneWidget, reason: 'the form did not mount');
  return h;
}

bool submitEnabled(WidgetTester t) {
  final f = find.byKey(submitKey);
  final w = t.widget(f);
  if (w is ButtonStyleButton) return w.enabled;
  final inner = find.descendant(
    of: f,
    matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
  );
  return t.widget<ButtonStyleButton>(inner.first).enabled;
}

String fieldText(WidgetTester t, Key key) => t
    .widget<EditableText>(
      find.descendant(of: find.byKey(key), matching: find.byType(EditableText)),
    )
    .controller
    .text;

Future<void> typeTag(WidgetTester t, String text) async {
  await t.enterText(find.byKey(tagKey), text);
  await t.pump();
}

Future<void> tapSubmit(WidgetTester t) async {
  await t.tap(find.byKey(submitKey), warnIfMissed: false);
  await t.pump();
  await t.pump();
}

void main() {
  testWidgets('starts from the profile; an unchanged tag needs no check', (
    t,
  ) async {
    final fake = ProfileFake(profile: me);
    final h = await pumpForm(t, fake);

    expect(fieldText(t, nameKey), 'Maya');
    expect(fieldText(t, tagKey), 'maya');
    await t.pump(settle);
    expect(fake.checks, isEmpty, reason: 'checked a tag nobody changed');
    expect(submitEnabled(t), isTrue);

    await tapSubmit(t);
    expect(h.submitted, [('Maya', 'maya')]);
  });

  testWidgets('a malformed tag shows the shape problem and is never checked', (
    t,
  ) async {
    final fake = ProfileFake(profile: me);
    final h = await pumpForm(t, fake);

    await typeTag(t, 'ab');
    await t.pump(settle);

    expect(find.text(tagProblem('ab')!), findsOneWidget);
    expect(fake.checks, isEmpty, reason: 'asked the server about a bad shape');
    expect(submitEnabled(t), isFalse);
    await tapSubmit(t);
    expect(h.submitted, isEmpty);
  });

  testWidgets('typing is debounced into one check of the last value', (
    t,
  ) async {
    final fake = ProfileFake(profile: me);
    await pumpForm(t, fake);

    await typeTag(t, 'new');
    await t.pump(const Duration(milliseconds: 100));
    await typeTag(t, 'new_t');
    await t.pump(const Duration(milliseconds: 100));
    await typeTag(t, 'new_tag');
    await t.pump(const Duration(milliseconds: 150));
    expect(fake.checks, isEmpty, reason: 'checked before the debounce ran out');

    await t.pump(settle);
    expect(fake.checks, ['new_tag']);
  });

  testWidgets('a taken tag is shown as taken and cannot be submitted', (
    t,
  ) async {
    final fake = ProfileFake(profile: me, takenByOthers: ['bob']);
    final h = await pumpForm(t, fake);

    await typeTag(t, 'bob');
    await t.pump(settle);
    await t.pump();

    expect(fake.checks, ['bob']);
    expect(takenText, findsOneWidget, reason: 'availability was not shown');
    expect(submitEnabled(t), isFalse);
    await tapSubmit(t);
    expect(h.submitted, isEmpty, reason: 'a taken tag was submitted');
  });

  testWidgets('submit waits for the check in flight', (t) async {
    final fake = ProfileFake(profile: me)..holdCheck('slow_tag');
    final h = await pumpForm(t, fake);

    await typeTag(t, 'slow_tag');
    await t.pump(settle);
    expect(fake.checks, ['slow_tag']);
    expect(submitEnabled(t), isFalse, reason: 'enabled while still checking');
    await tapSubmit(t);
    expect(h.submitted, isEmpty);

    fake.releaseCheck('slow_tag');
    await t.pumpAndSettle();
    expect(submitEnabled(t), isTrue);
    expect(takenText, findsNothing);
  });

  testWidgets('a late answer for an old value does not decide the new one', (
    t,
  ) async {
    // "slow_free" is free and its answer arrives last; "bob" is taken and
    // answers at once. The field says "bob", so submit must stay off.
    final fake = ProfileFake(profile: me, takenByOthers: ['bob'])
      ..holdCheck('slow_free');
    final h = await pumpForm(t, fake);

    await typeTag(t, 'slow_free');
    await t.pump(settle);
    await typeTag(t, 'bob');
    await t.pump(settle);
    await t.pump();
    expect(takenText, findsOneWidget);

    fake.releaseCheck('slow_free');
    await t.pumpAndSettle();

    expect(fake.checks, ['slow_free', 'bob']);
    expect(takenText, findsOneWidget, reason: 'a stale answer overwrote it');
    expect(submitEnabled(t), isFalse, reason: 'a stale "free" enabled submit');
    await tapSubmit(t);
    expect(h.submitted, isEmpty);
  });

  testWidgets('a late answer does not decide a tag that became malformed', (
    t,
  ) async {
    final fake = ProfileFake(profile: me)..holdCheck('slow_free');
    final h = await pumpForm(t, fake);

    await typeTag(t, 'slow_free');
    await t.pump(settle); // the check is in flight
    await typeTag(t, 'ab');
    fake.releaseCheck('slow_free'); // "free" -- for a tag no longer typed
    await t.pumpAndSettle();

    expect(find.text(tagProblem('ab')!), findsOneWidget);
    expect(submitEnabled(t), isFalse, reason: 'a stale "free" enabled "ab"');
    await tapSubmit(t);
    expect(h.submitted, isEmpty);
  });

  testWidgets('a late "taken" does not block going back to the current tag', (
    t,
  ) async {
    final fake = ProfileFake(profile: me, takenByOthers: ['bob'])
      ..holdCheck('bob');
    await pumpForm(t, fake);

    await typeTag(t, 'bob');
    await t.pump(settle); // the check is in flight
    await typeTag(t, 'maya');
    fake.releaseCheck('bob'); // "taken" -- for a tag no longer typed
    await t.pumpAndSettle();

    expect(takenText, findsNothing, reason: 'a stale "taken" was shown');
    expect(submitEnabled(t), isTrue, reason: 'a stale "taken" blocked saving');
  });

  testWidgets('going back to the current tag needs no check', (t) async {
    final fake = ProfileFake(profile: me, takenByOthers: ['bob']);
    await pumpForm(t, fake);

    await typeTag(t, 'bob');
    await t.pump(settle);
    await typeTag(t, '@Maya');
    await t.pump(settle);
    await t.pump();

    expect(fake.checks, ['bob'], reason: 'the member\'s own tag was checked');
    expect(takenText, findsNothing);
    expect(submitEnabled(t), isTrue);
  });

  testWidgets('submits the trimmed name and the normalised tag', (t) async {
    final fake = ProfileFake(profile: me);
    final h = await pumpForm(t, fake);

    await t.enterText(find.byKey(nameKey), '  Maya R  ');
    await typeTag(t, '  @Maya_R ');
    await t.pump(settle);
    await t.pump();
    expect(fake.checks, ['maya_r'], reason: 'the raw input was checked');
    expect(submitEnabled(t), isTrue);

    await tapSubmit(t);
    await t.pumpAndSettle();
    expect(h.submitted, [('Maya R', 'maya_r')]);
  });

  testWidgets('an empty name is not submitted', (t) async {
    final fake = ProfileFake(profile: me);
    final h = await pumpForm(t, fake);

    await t.enterText(find.byKey(nameKey), '   ');
    await t.pump(settle);
    await tapSubmit(t);
    await t.pumpAndSettle();

    expect(h.submitted, isEmpty, reason: 'a blank name went to the server');
  });

  testWidgets('a failed check still lets the member save; the server decides', (
    t,
  ) async {
    final fake = ProfileFake(profile: me)
      ..availabilityResult = const Err(NetworkFailure('offline'));
    final h = await pumpForm(t, fake);

    await typeTag(t, 'new_tag');
    await t.pump(settle);
    await t.pump();
    expect(fake.checks, ['new_tag']);
    expect(submitEnabled(t), isTrue, reason: 'a flaky check blocked saving');

    await tapSubmit(t);
    await t.pumpAndSettle();
    expect(h.submitted, [('Maya', 'new_tag')]);
  });

  testWidgets('a refused save shows the reason and keeps what was typed', (
    t,
  ) async {
    final fake = ProfileFake(profile: me);
    final h = await pumpForm(t, fake);

    await t.enterText(find.byKey(nameKey), 'Maya R');
    await typeTag(t, 'maya_r');
    await t.pump(settle);
    await t.pump();
    expect(submitEnabled(t), isTrue);

    // Free when checked, taken by the time the save arrives: the race the
    // unique index settles.
    fake.claimByOther('maya_r');
    await tapSubmit(t);
    await t.pumpAndSettle();

    expect(h.submitted, [('Maya R', 'maya_r')]);
    expect(
      find.descendant(
        of: find.byKey(errorKey),
        matching: find.textContaining('That tag was just taken by someone.'),
        matchRoot: true,
      ),
      findsOneWidget,
      reason: 'a refused save failed silently',
    );
    expect(fieldText(t, nameKey), 'Maya R', reason: 'the typed name was lost');
    expect(fieldText(t, tagKey), 'maya_r', reason: 'the typed tag was lost');
    expect(fake.profile.tag, 'maya');
  });
}
