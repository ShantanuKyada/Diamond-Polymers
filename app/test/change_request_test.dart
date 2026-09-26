import 'package:diamond_polymers/app.dart';
import 'package:diamond_polymers/core/demo/demo_overrides.dart';
import 'package:diamond_polymers/core/demo/demo_operations.dart';
import 'package:diamond_polymers/core/demo/demo_repositories.dart';
import 'package:diamond_polymers/core/demo/demo_store.dart';
import 'package:diamond_polymers/core/error/app_exception.dart';
import 'package:diamond_polymers/core/theme/app_theme.dart';
import 'package:diamond_polymers/features/auth/presentation/profile_screen.dart';
import 'package:diamond_polymers/core/config/app_config.dart';
import 'package:diamond_polymers/features/masters/data/masters_repository.dart';
import 'package:diamond_polymers/features/masters/data/settings_values.dart';
import 'package:diamond_polymers/features/masters/domain/masters.dart';
import 'package:diamond_polymers/features/masters/presentation/catalog_screens.dart';
import 'package:diamond_polymers/features/mixture/data/mixture_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// The September 2026 change request, exercised through the real app in demo
/// mode: operator navigation, attendance on the home page, the production
/// form's bags and wastage question, the weekly My Entries view, profile
/// editing, the fixed shift master, and admin-only material entry.
void main() {
  setUp(() => DemoStore.latency = Duration.zero);
  tearDown(() => DemoStore.latency = const Duration(milliseconds: 320));

  void tallScreen(WidgetTester tester) {
    tester.view.physicalSize = const Size(1080, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  Future<void> signIn(WidgetTester tester, String email) async {
    await tester.pumpWidget(demoScope(child: const DiamondPolymersApp()));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'Email'), email);
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Password'), 'demo1234');
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pumpAndSettle();
  }

  group('Operator app', () {
    // A34 reverses A30. The operator loads their own machine, so they record
    // it; the tab is back, and sits before Production because that is the order
    // the work happens in.
    testWidgets('has Material Entry, before Production (A34)', (tester) async {
      tallScreen(tester);
      await signIn(tester, 'ravi@diamondpolymers.local');

      final bar = find.byType(NavigationBar);
      for (final label in ['Home', 'Material', 'Production', 'My Entries',
        'Profile']) {
        expect(find.descendant(of: bar, matching: find.text(label)),
            findsOneWidget,
            reason: '$label should be in the operator bottom bar');
      }

      // Order matters: material in, then product out.
      final materialX = tester.getCenter(
          find.descendant(of: bar, matching: find.text('Material'))).dx;
      final productionX = tester.getCenter(
          find.descendant(of: bar, matching: find.text('Production'))).dx;
      expect(materialX, lessThan(productionX));
    });

    testWidgets('material entry uses their own machine, not a picker (A34)',
        (tester) async {
      tallScreen(tester);
      await signIn(tester, 'ravi@diamondpolymers.local');

      await tester.tap(find.descendant(
          of: find.byType(NavigationBar), matching: find.text('Material')));
      await tester.pumpAndSettle();

      expect(find.text('Material Entry'), findsWidgets);
      // The machine is stated, never chosen: the database would refuse any
      // other machine with DP006, so offering a choice would only mislead.
      expect(find.text('Machine 1'), findsOneWidget);
      expect(find.byType(DropdownButtonFormField<String>), findsOneWidget,
          reason: 'only the shift is selectable, not the machine');
    });

    testWidgets('home shows attendance in place of material entry (A33)',
        (tester) async {
      tallScreen(tester);
      await signIn(tester, 'ravi@diamondpolymers.local');

      expect(find.text('Attendance'), findsOneWidget);
      expect(find.text('On shift now'), findsOneWidget);
      expect(find.text('Checked in'), findsOneWidget);
      expect(find.text('Checked out'), findsOneWidget);
      expect(find.text('This week'), findsOneWidget);
      expect(find.text('Production Entry'), findsOneWidget);
    });

    testWidgets('production offers bags only where the product is bagged',
        (tester) async {
      tallScreen(tester);
      await signIn(tester, 'ravi@diamondpolymers.local');

      await tester.tap(find.descendant(
          of: find.byType(NavigationBar), matching: find.text('Production')));
      await tester.pumpAndSettle();

      // Only Morning and Night are offered (A29).
      expect(find.widgetWithText(ChoiceChip, 'Morning'), findsOneWidget);
      expect(find.widgetWithText(ChoiceChip, 'Night'), findsOneWidget);
      expect(find.widgetWithText(ChoiceChip, 'Afternoon'), findsNothing);

      await tester.tap(find.widgetWithText(ChoiceChip, 'Type A'));
      await tester.pumpAndSettle();

      // Size 4 is bundles only.
      await tester.tap(find.textContaining('Size 4'));
      await tester.pumpAndSettle();
      final bagsOff = tester.widget<TextField>(find.byKey(const Key('bags')));
      expect(bagsOff.enabled, isFalse);
      expect(find.text('Not packed in bags'), findsOneWidget);

      // Size 1 is packed in bags of 20.
      await tester.tap(find.textContaining('Size 1'));
      await tester.pumpAndSettle();
      final bagsOn = tester.widget<TextField>(find.byKey(const Key('bags')));
      expect(bagsOn.enabled, isTrue);
      expect(find.text('20 pipes each'), findsOneWidget);

      await tester.enterText(find.byKey(const Key('bundles')), '3');
      await tester.enterText(find.byKey(const Key('bags')), '2');
      await tester.pumpAndSettle();
      // 3 x 10 + 2 x 20, from the mapping.
      expect(find.text('= 70 pipes in total'), findsOneWidget);
    });

    testWidgets('the wastage question gates the kilograms field (A28)',
        (tester) async {
      tallScreen(tester);
      await signIn(tester, 'ravi@diamondpolymers.local');

      await tester.tap(find.descendant(
          of: find.byType(NavigationBar), matching: find.text('Production')));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(ChoiceChip, 'Type A'));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Size 1'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('bundles')), '5');
      await tester.pumpAndSettle();

      FilledButton review() =>
          tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Review'));

      // Unanswered: not submittable, and the reason is shown.
      expect(find.text('Say whether wastage material was used.'), findsOneWidget);
      expect(review().onPressed, isNull);
      expect(find.byKey(const Key('wastage-used-kg')), findsNothing);

      // Yes: a quantity is required.
      await tester.tap(find.text('Yes'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('wastage-used-kg')), findsOneWidget);
      expect(review().onPressed, isNull);

      await tester.enterText(find.byKey(const Key('wastage-used-kg')), '4.5');
      await tester.pumpAndSettle();
      expect(review().onPressed, isNotNull);

      // No: the field goes away and the entry is submittable.
      await tester.tap(find.text('No'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('wastage-used-kg')), findsNothing);
      expect(review().onPressed, isNotNull);

      await tester.tap(find.widgetWithText(FilledButton, 'Review'));
      await tester.pumpAndSettle();
      expect(find.text('Confirm production'), findsWidgets);
      expect(find.text('Operator'), findsOneWidget);
      expect(find.text('Ravi Kumar'), findsOneWidget);
    });

    testWidgets('My Entries covers seven days, oldest first (A32)',
        (tester) async {
      tallScreen(tester);
      await signIn(tester, 'ravi@diamondpolymers.local');

      await tester.tap(find.descendant(
          of: find.byType(NavigationBar), matching: find.text('My Entries')));
      await tester.pumpAndSettle();

      // Nine of Ravi's entries fall inside the week; the one from nine days
      // ago does not.
      expect(find.text('Your last 7 days · 9 entries'), findsOneWidget);

      final today = find.textContaining('Today ·');
      final yesterday = find.textContaining('Yesterday ·');
      await tester.scrollUntilVisible(today, 400);
      expect(today, findsOneWidget);
      expect(yesterday, findsOneWidget);
      expect(tester.getTopLeft(yesterday).dy,
          lessThan(tester.getTopLeft(today).dy),
          reason: 'chronological: yesterday is listed before today');

      expect(find.textContaining('Wastage used'), findsWidgets);
      expect(find.textContaining('bags'), findsWidgets);
    });

    testWidgets('profile edits name and phone, with validation (A31)',
        (tester) async {
      tallScreen(tester);
      await signIn(tester, 'ravi@diamondpolymers.local');

      await tester.tap(find.descendant(
          of: find.byType(NavigationBar), matching: find.text('Profile')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('edit-profile')));
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const Key('profile-phone')), '12345');
      await tester.tap(find.byKey(const Key('profile-save')));
      await tester.pumpAndSettle();
      expect(find.textContaining('10 to 15 digits'), findsOneWidget);

      await tester.enterText(find.byKey(const Key('profile-name')), 'Ravi K.');
      await tester.enterText(
          find.byKey(const Key('profile-phone')), '+91 98765 43210');
      await tester.tap(find.byKey(const Key('profile-save')));
      await tester.pumpAndSettle();

      expect(find.text('Profile updated.'), findsOneWidget);
      expect(find.text('Ravi K.'), findsWidgets);
      expect(find.text('+919876543210'), findsOneWidget);
      // Role and employee code are unchanged.
      expect(find.text('Machine Operator'), findsOneWidget);
      expect(find.text('EMP-101'), findsOneWidget);
    });
  });

  group('Admin app', () {
    testWidgets('Material Entry lives under More', (tester) async {
      tallScreen(tester);
      await signIn(tester, 'admin@diamondpolymers.local');

      await tester.tap(find.descendant(
          of: find.byType(NavigationBar), matching: find.text('More')));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Material Entry'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Choose the machine'), findsOneWidget);
    });

    testWidgets('the shift master offers two shifts and no way to add one',
        (tester) async {
      tallScreen(tester);
      await tester.pumpWidget(demoScope(
        child: MaterialApp(theme: AppTheme.light(), home: const ShiftsScreen()),
      ));
      await tester.pumpAndSettle();

      expect(find.text('Morning Shift'), findsOneWidget);
      expect(find.text('Night Shift'), findsOneWidget);
      expect(find.text('Afternoon Shift'), findsNothing);
      expect(find.byType(FloatingActionButton), findsNothing);
      expect(find.textContaining('cannot be added or removed'), findsOneWidget);
    });
  });

  group('Rules the demo keeps, as the database does', () {
    // A34: the boundary moved from "administrators only" to "your own machine
    // only". The demo has to move with it, or the demo APK contradicts the
    // live one.
    test('an operator records material for their own machine', () async {
      final store = DemoStore()..signedInProfileId = DemoStore.raviId;
      final repo = DemoMixtureRepository(store);

      final result = await repo.consume(
        machineId: DemoStore.machine1, // Ravi's machine
        shiftId: DemoStore.shiftMorning,
        lines: const [
          MixtureLine(rawMaterialId: DemoStore.raizinId, quantity: 1),
        ],
        clientRef: 'op-own-machine',
      );

      expect(result.duplicate, isFalse);
      expect(result.totalQuantity, 1);

      // And the batch is kept, because production now points at it (A37).
      final batches = await repo.recentBatches(machineId: DemoStore.machine1);
      expect(batches, isNotEmpty);
      expect(batches.first.id, result.id);
      expect(batches.first.hasProduction, isFalse);
    });

    test('but not for a machine they are not assigned to', () async {
      final store = DemoStore()..signedInProfileId = DemoStore.raviId;
      final repo = DemoMixtureRepository(store);

      await expectLater(
        repo.consume(
          machineId: DemoStore.machine2, // not Ravi's
          shiftId: DemoStore.shiftMorning,
          lines: const [
            MixtureLine(rawMaterialId: DemoStore.raizinId, quantity: 1),
          ],
          clientRef: 'op-other-machine',
        ),
        throwsA(isA<AppException>()
            .having((e) => e.kind, 'kind', AppErrorKind.authorization)),
      );
    });

    test('production without a batch is refused, as in the database (A37)',
        () async {
      final store = DemoStore()..signedInProfileId = DemoStore.raviId;
      final repo = DemoProductionRepository(store);

      await expectLater(
        repo.record(
          machineId: DemoStore.machine1,
          shiftId: DemoStore.shiftMorning,
          pipeTypeId: DemoStore.typeA,
          pipeSizeId: '44444444-4444-4444-8444-000000000001',
          bundleQuantity: 5,
          clientRef: 'no-batch',
        ),
        throwsA(isA<AppException>()
            .having((e) => e.kind, 'kind', AppErrorKind.validation)),
      );
    });

    test('only Morning and Night exist, and they cannot be renamed', () async {
      final store = DemoStore()..signedInProfileId = DemoStore.adminId;
      final repo = DemoMastersRepository(store);

      final names = (await repo.shifts()).map((s) => s.name).toList();
      expect(names, ['Morning', 'Night']);

      await expectLater(
        repo.saveShift(
          name: 'Afternoon',
          startTime: '14:00:00',
          endTime: '22:00:00',
          active: true,
        ),
        throwsA(isA<AppException>()),
      );
      await expectLater(
        repo.saveShift(
          id: DemoStore.shiftMorning,
          name: 'Day',
          startTime: '06:00:00',
          endTime: '18:00:00',
          active: true,
        ),
        throwsA(isA<AppException>()),
      );
    });
  });

  group('Nothing the factory owns is hard-coded', () {
    ProviderContainer containerWith(List<AppSetting> settings) {
      final container = ProviderContainer(overrides: [
        settingsProvider.overrideWith((ref) async => settings),
      ]);
      addTearDown(container.dispose);
      return container;
    }

    test('the factory name, unit and currency come from settings', () async {
      final container = containerWith([
        AppSetting.from(const {'key': 'factory_name', 'value': 'Acme Pipes'}),
        AppSetting.from(const {'key': 'production_wastage_unit', 'value': 'lb'}),
        AppSetting.from(const {'key': 'currency_symbol', 'value': r'$'}),
      ]);
      await container.read(settingsProvider.future);

      expect(container.read(factoryNameProvider), 'Acme Pipes');
      expect(container.read(wastageUnitProvider), 'lb');
      expect(container.read(currencySymbolProvider), r'$');
    });

    test('a missing or blank setting falls back, never to an empty label',
        () async {
      final container = containerWith([
        AppSetting.from(const {'key': 'factory_name', 'value': '   '}),
      ]);
      await container.read(settingsProvider.future);

      expect(container.read(factoryNameProvider), AppConfig.factoryName);
      expect(container.read(wastageUnitProvider), 'kg');
      expect(container.read(currencySymbolProvider), isNotEmpty);
    });
  });

  group('Phone validation (A31)', () {
    test('accepts the formats people type', () {
      for (final ok in ['', '9876543210', '+91 98765 43210', '098765-43210']) {
        expect(EditProfileSheet.validatePhone(ok), isNull, reason: ok);
      }
    });

    test('refuses anything the database would refuse', () {
      for (final bad in ['12345', '98765abcde', '+91 98', '1234567890123456']) {
        expect(EditProfileSheet.validatePhone(bad), isNotNull, reason: bad);
      }
    });
  });
}
