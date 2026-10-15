import 'package:diamond_polymers/app.dart';
import 'package:diamond_polymers/core/demo/demo_overrides.dart';
import 'package:diamond_polymers/core/demo/demo_operations.dart';
import 'package:diamond_polymers/core/demo/demo_repositories.dart';
import 'package:diamond_polymers/core/demo/demo_store.dart';
import 'package:diamond_polymers/core/utils/formatters.dart';
import 'package:diamond_polymers/core/widgets/responsive.dart';
import 'package:diamond_polymers/features/auth/domain/app_user.dart';
import 'package:diamond_polymers/core/error/app_exception.dart';
import 'package:diamond_polymers/core/theme/app_theme.dart';
import 'package:diamond_polymers/features/auth/presentation/profile_screen.dart';
import 'package:diamond_polymers/core/config/app_config.dart';
import 'package:diamond_polymers/features/masters/data/masters_repository.dart';
import 'package:diamond_polymers/features/masters/data/settings_values.dart';
import 'package:diamond_polymers/features/masters/domain/masters.dart';
import 'package:diamond_polymers/features/masters/presentation/catalog_screens.dart';
import 'package:diamond_polymers/features/masters/presentation/employee_roles_screen.dart';
import 'package:diamond_polymers/features/mixture/data/mixture_repository.dart';
import 'package:diamond_polymers/features/masters/presentation/operators_screen.dart';
import 'package:diamond_polymers/features/staff/presentation/salary_slip_document.dart';
import 'package:diamond_polymers/features/staff/data/staff_repository.dart';
import 'package:diamond_polymers/features/staff/presentation/staff_screens.dart';
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

  /// A tall phone: 412dp wide, which is what the floor actually holds, and long
  /// enough that nothing a test looks for has scrolled out of view.
  ///
  /// It used to be 1080 logical pixels, which is a tablet — so every test that
  /// asserted a bottom bar was unknowingly asserting it on a tablet, and the
  /// phone layout these tests are named for went unexercised.
  void tallScreen(WidgetTester tester) {
    tester.view.physicalSize = const Size(412, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  /// A tablet in landscape, where navigation moves to a side rail (A40).
  void tabletScreen(WidgetTester tester) {
    tester.view.physicalSize = const Size(1280, 900);
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

    // A40 reverses the machine half of A34. The operator still records their
    // own material — that part stands — but they pick the machine they are
    // standing at, because the factory moves people between machines during a
    // shift and the database no longer refuses it.
    testWidgets('material entry lets them pick any machine, theirs first (A40)',
        (tester) async {
      tallScreen(tester);
      await signIn(tester, 'ravi@diamondpolymers.local');

      await tester.tap(find.descendant(
          of: find.byType(NavigationBar), matching: find.text('Material')));
      await tester.pumpAndSettle();

      expect(find.text('Material Entry'), findsWidgets);

      // Every running machine is offered, not just his own.
      final chips = find.byType(ChoiceChip);
      expect(tester.widgetList(chips).length, greaterThan(1),
          reason: 'an operator may work on any machine');

      // His own is marked and already selected, so the common case is still no
      // taps at all.
      expect(find.text('Machine 1 · yours'), findsOneWidget);
      final mine = tester.widget<ChoiceChip>(
          find.widgetWithText(ChoiceChip, 'Machine 1 · yours'));
      expect(mine.selected, isTrue);
    });

    testWidgets('and picking another machine says so rather than refusing',
        (tester) async {
      tallScreen(tester);
      await signIn(tester, 'ravi@diamondpolymers.local');

      await tester.tap(find.descendant(
          of: find.byType(NavigationBar), matching: find.text('Material')));
      await tester.pumpAndSettle();

      // Any chip that is not his own.
      final others = find
          .byWidgetPredicate((w) => w is ChoiceChip && w.selected == false);
      await tester.tap(others.first);
      await tester.pumpAndSettle();

      expect(find.textContaining('Not your usual machine'), findsOneWidget);
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

  // A38. Payroll used to prorate a salary by attendance and pay statutory
  // overtime. The factory does neither: a month's salary is a month's salary,
  // and what somebody has drawn against it comes off. These pin that, because
  // the difference between the two models is invisible on a screen that is
  // only ever shown a full month.
  group('Payroll is a salary less what was taken (A38)', () {
    testWidgets('a payslip shows four figures and no overtime', (tester) async {
      tallScreen(tester);
      await tester.pumpWidget(demoScope(
        signedInProfileId: DemoStore.adminId,
        child: MaterialApp(theme: AppTheme.light(), home: const SalaryScreen()),
      ));
      await tester.pumpAndSettle();

      expect(find.text('Monthly salary'), findsWidgets);
      expect(find.text('Net payable'), findsWidgets);
      expect(find.text('Advance taken'), findsWidgets);

      for (final gone in ['Basic', 'Overtime', 'Additions']) {
        expect(find.text(gone), findsNothing,
            reason: '$gone no longer exists in the calculation');
      }
    });

    testWidgets('the Salaries tab says what each person is on', (tester) async {
      tallScreen(tester);
      await tester.pumpWidget(demoScope(
        signedInProfileId: DemoStore.adminId,
        child: MaterialApp(theme: AppTheme.light(), home: const SalaryScreen()),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Salaries'));
      await tester.pumpAndSettle();

      expect(find.text('Monthly salary'), findsWidgets);
      expect(find.text('Ravi Kumar'), findsWidgets);
    });

    test('the demo pays the salary whatever the attendance says', () async {
      final store = DemoStore()..signedInProfileId = DemoStore.adminId;
      final repo = DemoStaffRepository(store);
      final month = DateTime.now();

      // Ravi is marked absent in the demo month and has drawn 3000.
      final before = (await repo.staffPay())
          .firstWhere((p) => p.employeeCode == 'EMP-101');
      expect(before.outstandingAdvance, 3000);

      await repo.runPayroll(month);
      final slip = (await repo.payslips(month: month))
          .firstWhere((s) => s.employeeCode == 'EMP-101');

      expect(slip.monthlySalary, before.monthlySalary);
      expect(slip.advanceRecovered, 3000);
      expect(slip.netPayable,
          slip.monthlySalary - slip.deductionsAmount - slip.advanceRecovered);
    });

    test('an advance comes off the next payslip, once', () async {
      final store = DemoStore()..signedInProfileId = DemoStore.adminId;
      final repo = DemoStaffRepository(store);
      final month = DateTime.now();
      final ganesh = (await repo.staffPay())
          .firstWhere((p) => p.employeeCode == 'EMP-104');

      await repo.issueAdvance(
        profileId: ganesh.profileId,
        amount: 300,
        clientRef: 'ref-1',
      );
      await repo.runPayroll(month);

      var slip = (await repo.payslips(month: month))
          .firstWhere((s) => s.employeeCode == 'EMP-104');
      expect(slip.advanceRecovered, 300);
      expect(slip.netPayable, slip.monthlySalary - 300);

      // Finalising is the point the money actually moves, so recalculating a
      // draft beforehand must not recover it twice.
      await repo.runPayroll(month);
      slip = (await repo.payslips(month: month))
          .firstWhere((s) => s.employeeCode == 'EMP-104');
      expect(slip.advanceRecovered, 300);

      await repo.finalisePayroll(month);
      final after = (await repo.staffPay())
          .firstWhere((p) => p.employeeCode == 'EMP-104');
      expect(after.outstandingAdvance, 0);
    });

    test('recovery never pushes a payslip below zero', () async {
      final store = DemoStore()..signedInProfileId = DemoStore.adminId;
      final repo = DemoStaffRepository(store);
      final month = DateTime.now();
      final ganesh = (await repo.staffPay())
          .firstWhere((p) => p.employeeCode == 'EMP-104');

      await repo.issueAdvance(
        profileId: ganesh.profileId,
        amount: ganesh.monthlySalary! * 5,
        clientRef: 'ref-2',
      );
      await repo.runPayroll(month);

      final slip = (await repo.payslips(month: month))
          .firstWhere((s) => s.employeeCode == 'EMP-104');
      expect(slip.netPayable, 0);
      expect(slip.advanceRecovered, slip.monthlySalary);

      // The rest is still owed; it carries to the month after.
      await repo.finalisePayroll(month);
      final after = (await repo.staffPay())
          .firstWhere((p) => p.employeeCode == 'EMP-104');
      expect(after.outstandingAdvance, ganesh.monthlySalary! * 4);
    });

    test('a finalised month refuses every further change', () async {
      final store = DemoStore()..signedInProfileId = DemoStore.adminId;
      final repo = DemoStaffRepository(store);
      final month = DateTime.now();

      await repo.runPayroll(month);
      await repo.finalisePayroll(month);

      final ravi = (await repo.staffPay())
          .firstWhere((p) => p.employeeCode == 'EMP-101');

      expect(
        () => repo.addDeduction(
          profileId: ravi.profileId,
          periodMonth: month,
          label: 'Late',
          amount: 100,
          clientRef: 'ref-3',
        ),
        throwsA(isA<AppException>()
            .having((e) => e.kind, 'kind', AppErrorKind.conflict)),
      );
      expect(() => repo.runPayroll(month), throwsA(isA<AppException>()));
    });

    test('a deduction bigger than the salary is refused by name', () async {
      final store = DemoStore()..signedInProfileId = DemoStore.adminId;
      final repo = DemoStaffRepository(store);
      final month = DateTime.now();
      final ravi = (await repo.staffPay())
          .firstWhere((p) => p.employeeCode == 'EMP-101');

      final added = await repo.addDeduction(
        profileId: ravi.profileId,
        periodMonth: month,
        label: 'Typo',
        amount: ravi.monthlySalary! * 2,
        clientRef: 'ref-4',
      );

      await expectLater(
        repo.runPayroll(month),
        throwsA(isA<AppException>()
            .having((e) => e.message, 'message', contains('Ravi Kumar'))),
      );

      // And can be taken back, so one slip of the keyboard does not strand the
      // month's payroll.
      await repo.removeDeduction(added['id'] as String);
      final result = await repo.runPayroll(month);
      expect(result['payslips'], greaterThan(0));
    });
  });

  // A39. 0019 worked out what a worker is owed and had no way to record that
  // they were paid. These cover the half that was missing, and the profile
  // fields payroll needed: a joining date and the day somebody is paid on.
  group('Worker profiles and salary payments (A39)', () {
    test('an admin creates a worker with a salary in one go', () async {
      final store = DemoStore()..signedInProfileId = DemoStore.adminId;
      final repo = DemoMastersRepository(store);

      await repo.saveStaff(
        name: 'Worker A',
        employeeCode: 'EMP-901',
        role: 'OPERATOR',
        active: true,
        phone: '9876543210',
        joinedOn: DateTime(2026, 7, 1),
        salaryDay: 7,
        monthlySalary: 5000,
      );

      final person = (await repo.staff())
          .firstWhere((p) => p.employeeCode == 'EMP-901');
      expect(person.name, 'Worker A');
      expect(person.monthlySalary, 5000);
      expect(person.salaryDay, 7);
      expect(person.joinedOn, DateTime(2026, 7, 1));
      expect(person.hasSalary, isTrue);
    });

    test('a worker ID already in use is refused', () async {
      final store = DemoStore()..signedInProfileId = DemoStore.adminId;
      final repo = DemoMastersRepository(store);

      expect(
        () => repo.saveStaff(
          name: 'Somebody Else',
          employeeCode: 'EMP-101',
          role: 'OPERATOR',
          active: true,
        ),
        throwsA(isA<AppException>()
            .having((e) => e.message, 'message', contains('EMP-101'))),
      );
    });

    test('a joining date in the future, and an impossible salary day, are '
        'refused', () async {
      final store = DemoStore()..signedInProfileId = DemoStore.adminId;
      final repo = DemoMastersRepository(store);

      expect(
        () => repo.saveStaff(
          name: 'Time Traveller',
          employeeCode: 'EMP-902',
          role: 'OPERATOR',
          active: true,
          joinedOn: DateTime.now().add(const Duration(days: 30)),
        ),
        throwsA(isA<AppException>()),
      );
      expect(
        () => repo.saveStaff(
          name: 'Bad Day',
          employeeCode: 'EMP-903',
          role: 'OPERATOR',
          active: true,
          salaryDay: 32,
        ),
        throwsA(isA<AppException>()),
      );
    });

    test('somebody already on the roll with no joining date still reads',
        () async {
      final store = DemoStore()..signedInProfileId = DemoStore.adminId;
      final repo = DemoMastersRepository(store);

      // Ganesh predates both fields. A screen has to render that, not crash on
      // it — which is why the demo deliberately leaves him incomplete.
      final ganesh = (await repo.staff())
          .firstWhere((p) => p.employeeCode == 'EMP-104');
      expect(ganesh.joinedOn, isNull);
      expect(ganesh.salaryDay, isNull);
      expect(ganesh.hasSalary, isTrue);
    });

    // The brief's own worked example, through the demo twin.
    test('5000 salary, 2000 advance, 3000 paid on salary day', () async {
      final store = DemoStore()..signedInProfileId = DemoStore.adminId;
      final masters = DemoMastersRepository(store);
      final staff = DemoStaffRepository(store);
      final month = DateTime.now();

      await masters.saveStaff(
        name: 'Worker A',
        employeeCode: 'EMP-901',
        role: 'OPERATOR',
        active: true,
        joinedOn: DateTime(2026, 7, 1),
        salaryDay: 7,
        monthlySalary: 5000,
      );
      final worker = (await staff.staffPay())
          .firstWhere((p) => p.employeeCode == 'EMP-901');

      await staff.issueAdvance(
        profileId: worker.profileId,
        amount: 2000,
        clientRef: 'adv-1',
      );
      await staff.runPayroll(month);

      var slip = (await staff.payslips(month: month))
          .firstWhere((s) => s.employeeCode == 'EMP-901');

      // The three figures the factory asked to see.
      expect(slip.monthlySalary, 5000);
      expect(slip.advanceRecovered, 2000);
      expect(slip.netPayable, 3000);
      expect(slip.status, PaymentStatus.draft);

      // A draft cannot be paid against: its figures can still move.
      expect(
        () => staff.recordPayment(
            payslipId: slip.id, amount: 3000, clientRef: 'pay-0'),
        throwsA(isA<AppException>()),
      );

      await staff.finalisePayroll(month);
      slip = (await staff.payslips(month: month))
          .firstWhere((s) => s.employeeCode == 'EMP-901');
      expect(slip.status, PaymentStatus.unpaid);
      expect(slip.outstanding, 3000);

      await staff.recordPayment(
          payslipId: slip.id, amount: 3000, clientRef: 'pay-1');
      slip = (await staff.payslips(month: month))
          .firstWhere((s) => s.employeeCode == 'EMP-901');
      expect(slip.paidAmount, 3000);
      expect(slip.outstanding, 0);
      expect(slip.status, PaymentStatus.paid);
    });

    test('partial payments add up, and a retry does not pay twice', () async {
      final store = DemoStore()..signedInProfileId = DemoStore.adminId;
      final staff = DemoStaffRepository(store);
      final month = DateTime.now();

      await staff.runPayroll(month);
      await staff.finalisePayroll(month);

      var slip = (await staff.payslips(month: month))
          .firstWhere((s) => s.employeeCode == 'EMP-102');
      final owed = slip.netPayable;

      await staff.recordPayment(
          payslipId: slip.id, amount: 1000, clientRef: 'p1');
      // Same reference: the same payment, retried.
      await staff.recordPayment(
          payslipId: slip.id, amount: 1000, clientRef: 'p1');

      slip = (await staff.payslips(month: month))
          .firstWhere((s) => s.employeeCode == 'EMP-102');
      expect(slip.paidAmount, 1000);
      expect(slip.status, PaymentStatus.partial);

      await staff.recordPayment(
          payslipId: slip.id, amount: owed - 1000, clientRef: 'p2');
      slip = (await staff.payslips(month: month))
          .firstWhere((s) => s.employeeCode == 'EMP-102');
      expect(slip.outstanding, 0);
      expect(slip.status, PaymentStatus.paid);

      // And not a rupee more.
      expect(
        () => staff.recordPayment(
            payslipId: slip.id, amount: 1, clientRef: 'p3'),
        throwsA(isA<AppException>()
            .having((e) => e.kind, 'kind', AppErrorKind.insufficientStock)),
      );
    });

    test('a reversal gives the money back without erasing the record',
        () async {
      final store = DemoStore()..signedInProfileId = DemoStore.adminId;
      final staff = DemoStaffRepository(store);
      final month = DateTime.now();

      await staff.runPayroll(month);
      await staff.finalisePayroll(month);

      var slip = (await staff.payslips(month: month))
          .firstWhere((s) => s.employeeCode == 'EMP-102');
      final paid = await staff.recordPayment(
          payslipId: slip.id, amount: 5000, clientRef: 'p1');

      await staff.reversePayment(
          paymentId: paid['id'] as String, clientRef: 'r1');

      slip = (await staff.payslips(month: month))
          .firstWhere((s) => s.employeeCode == 'EMP-102');
      expect(slip.paidAmount, 0);
      expect(slip.status, PaymentStatus.unpaid);

      // Both rows survive — the payment and its undo.
      final history = await staff.paymentsFor(slip.id);
      expect(history, hasLength(2));
      expect(history.where((p) => p.isReversal), hasLength(1));
      expect(history.where((p) => p.isReversed), hasLength(1));

      // And it cannot be reversed twice.
      expect(
        () => staff.reversePayment(
            paymentId: paid['id'] as String, clientRef: 'r2'),
        throwsA(isA<AppException>()),
      );
    });

    test('a salary entirely taken as advances reads as paid, not owed',
        () async {
      final store = DemoStore()..signedInProfileId = DemoStore.adminId;
      final staff = DemoStaffRepository(store);
      final month = DateTime.now();

      final ganesh = (await staff.staffPay())
          .firstWhere((p) => p.employeeCode == 'EMP-104');
      await staff.issueAdvance(
        profileId: ganesh.profileId,
        amount: ganesh.monthlySalary!,
        clientRef: 'adv-all',
      );
      await staff.runPayroll(month);
      await staff.finalisePayroll(month);

      final slip = (await staff.payslips(month: month))
          .firstWhere((s) => s.employeeCode == 'EMP-104');
      expect(slip.netPayable, 0);
      expect(slip.status, PaymentStatus.paid);
    });

    test('a salary day past the end of a short month lands on its last day',
        () {
      expect(DemoStore.salaryDueOn(DateTime(2027, 2, 1), 31), '2027-02-28');
      expect(DemoStore.salaryDueOn(DateTime(2027, 2, 1), 7), '2027-02-07');
      expect(DemoStore.salaryDueOn(DateTime(2027, 2, 1), null), isNull);
    });

    test('the monthly overview never loses money between the two columns',
        () async {
      final store = DemoStore()..signedInProfileId = DemoStore.adminId;
      final staff = DemoStaffRepository(store);
      final month = DateTime.now();

      await staff.runPayroll(month);
      await staff.finalisePayroll(month);

      var slip = (await staff.payslips(month: month))
          .firstWhere((s) => s.employeeCode == 'EMP-102');
      await staff.recordPayment(
          payslipId: slip.id, amount: 1000, clientRef: 'p1');

      final period = (await staff.payrollPeriods()).firstWhere((p) =>
          p.periodMonth.year == month.year &&
          p.periodMonth.month == month.month);

      expect(period.paidTotal + period.outstandingTotal, period.netTotal);
      expect(period.partialCount, 1);
    });

    testWidgets('the payslip card shows what is paid and what is left',
        (tester) async {
      tallScreen(tester);
      await tester.pumpWidget(demoScope(
        signedInProfileId: DemoStore.adminId,
        child: MaterialApp(theme: AppTheme.light(), home: const SalaryScreen()),
      ));
      await tester.pumpAndSettle();

      // Back one month, to the finalised one.
      await tester.tap(find.byTooltip('Previous month'));
      await tester.pumpAndSettle();

      expect(find.text('Paid'), findsWidgets);
      expect(find.text('Outstanding'), findsWidgets);
      // Ravi is part paid in the demo's previous month.
      expect(find.text('Part paid'), findsWidgets);
      // A payable payslip offers a way to pay it, and a slip to print.
      expect(find.widgetWithText(FilledButton, 'Pay'), findsWidgets);
      expect(find.widgetWithText(TextButton, 'Slip'), findsWidgets);
    });

    testWidgets('a draft month offers no way to pay', (tester) async {
      tallScreen(tester);
      await tester.pumpWidget(demoScope(
        signedInProfileId: DemoStore.adminId,
        child: MaterialApp(theme: AppTheme.light(), home: const SalaryScreen()),
      ));
      await tester.pumpAndSettle();

      // The current month is a draft: nothing is agreed, so nothing is payable.
      expect(find.text('Draft'), findsWidgets);
      expect(find.widgetWithText(FilledButton, 'Pay'), findsNothing);
      expect(find.widgetWithText(TextButton, 'Slip'), findsNothing);
    });

    testWidgets('the worker form carries a joining date, salary and salary day',
        (tester) async {
      tallScreen(tester);
      await tester.pumpWidget(demoScope(
        signedInProfileId: DemoStore.adminId,
        child:
            MaterialApp(theme: AppTheme.light(), home: const OperatorsScreen()),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();

      expect(find.text('Worker ID *'), findsOneWidget);
      expect(find.text('Joining date'), findsOneWidget);
      expect(find.text('Monthly salary'), findsOneWidget);
      expect(find.text('Salary day'), findsOneWidget);
      expect(find.text('No fixed day'), findsOneWidget);
    });

    // A40: the admin picks what kind of employee this is when they add them,
    // and the form follows the answer.
    testWidgets('adding an employee starts by asking what kind they are',
        (tester) async {
      tallScreen(tester);
      await tester.pumpWidget(demoScope(
        signedInProfileId: DemoStore.adminId,
        child:
            MaterialApp(theme: AppTheme.light(), home: const OperatorsScreen()),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();

      expect(find.text('Employee type *'), findsOneWidget);
      // Operator is the default, because most of the roll are operators.
      expect(find.text('Operator'), findsWidgets);

      await tester.tap(find.byType(DropdownButtonFormField<String>).first);
      await tester.pumpAndSettle();

      for (final type in ['Operator', 'Labourer', 'Office']) {
        expect(find.text(type), findsWidgets, reason: '$type should be offered');
      }

      await tester.tap(find.text('Labourer').last);
      await tester.pumpAndSettle();

      // The helper under the field explains what the choice means, so the
      // admin is not guessing what a labourer does or does not get.
      expect(find.textContaining('No machine work to record'), findsOneWidget);
    });

    testWidgets('and a labourer added through the form really is one',
        (tester) async {
      tallScreen(tester);
      final store = DemoStore()..signedInProfileId = DemoStore.adminId;

      await tester.pumpWidget(demoScope(
        store: store,
        child:
            MaterialApp(theme: AppTheme.light(), home: const OperatorsScreen()),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(DropdownButtonFormField<String>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Labourer').last);
      await tester.pumpAndSettle();

      await tester.enterText(
          find.widgetWithText(TextFormField, 'Name *'), 'Naresh Patel');
      await tester.enterText(
          find.widgetWithText(TextFormField, 'Worker ID *'), 'EMP-301');
      await tester.enterText(
          find.widgetWithText(TextFormField, 'Monthly salary'), '12000');
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      // Bounded pumps rather than pumpAndSettle: saving shows a spinner and
      // then a SnackBar, and pumpAndSettle waits for every animation to stop —
      // which between them those two never do.
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      // runAsync, because the demo repositories await a Future.delayed and a
      // widget test's clock is fake — awaiting one directly here never returns.
      final all = await tester.runAsync(
          () async => DemoMastersRepository(store).staff());
      final added = all!.where((p) => p.employeeCode == 'EMP-301').firstOrNull;

      expect(added, isNotNull,
          reason: 'roster holds ${all.map((p) => p.employeeCode).toList()}');
      expect(added!.name, 'Naresh Patel');
      expect(added.employeeTypeCode, 'LABOURER');
      expect(added.employeeTypeName, 'Labourer');
      expect(added.runsMachines, isFalse);
      // On the payroll like anybody else — that is the whole point of having
      // them on file.
      expect(added.monthlySalary, 12000);
    });

    test('the salary slip prints the advances and payments behind the figure',
        () async {
      final store = DemoStore()..signedInProfileId = DemoStore.adminId;
      final staff = DemoStaffRepository(store);
      final lastMonth = DateTime(DateTime.now().year, DateTime.now().month - 1, 1);

      final slip = (await staff.payslips(month: lastMonth))
          .firstWhere((s) => s.employeeCode == 'EMP-101');

      final data = SalarySlipData(
        payslip: slip,
        advances: await staff.advancesTaken(
            profileId: slip.profileId, month: lastMonth),
        payments: await staff.paymentsFor(slip.id),
        factoryName: 'Diamond Polymers',
        currencySymbol: '₹',
      );

      // The slip has to explain the figure, not just state it.
      expect(data.advances, isNotEmpty);
      expect(data.payments, isNotEmpty);
      expect(data.number, contains('EMP-101'));

      final bytes = await buildSalarySlipPdf(data);
      // A real PDF, not an empty document.
      expect(bytes.length, greaterThan(1000));
      expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    });

    // The `pdf` package draws with Helvetica unless a font is bundled, and
    // Helvetica has no rupee sign and no em dash. It drops what it cannot draw
    // and only warns on a console nobody reads — so a slip would have printed
    // "5,000.00" with no currency at all, and the delivery challan has printed
    // "Type  Size" with a hole in it since the day it shipped.
    group('text that will actually draw in a PDF', () {
      test('the rupee sign is spelled so it appears', () {
        expect(Fmt.pdfMoney(5000), 'Rs.5,000.00');
        expect(Fmt.pdfMoney(5000, symbol: r'$'), r'$5,000.00');
      });

      test('dashes and quotes become their ASCII spellings', () {
        expect(Fmt.pdfSafe('Type — Size'), 'Type - Size');
        expect(Fmt.pdfSafe('Ravi’s note'), "Ravi's note");
        expect(Fmt.pdfSafe('a · b'), 'a - b');
      });

      test('what cannot be drawn is dropped, never left as a box', () {
        // Not ideal — a name in Gujarati would vanish rather than print
        // wrongly — but the employee code beside it is always ASCII, so the
        // worker on the slip stays identifiable. Bundling a Unicode font is
        // the real fix if the factory ever enters non-Latin names.
        expect(Fmt.pdfSafe('रवि'), '');
        expect(Fmt.pdfSafe('Ravi रवि Kumar'), 'Ravi  Kumar');
      });

      test('everything a slip puts on the page is drawable', () async {
        final store = DemoStore()..signedInProfileId = DemoStore.adminId;
        final staff = DemoStaffRepository(store);
        final lastMonth =
            DateTime(DateTime.now().year, DateTime.now().month - 1, 1);
        final slip = (await staff.payslips(month: lastMonth))
            .firstWhere((s) => s.employeeCode == 'EMP-101');

        final data = SalarySlipData(
          payslip: slip,
          advances: await staff.advancesTaken(
              profileId: slip.profileId, month: lastMonth),
          payments: await staff.paymentsFor(slip.id),
          factoryName: 'Diamond Polymers',
          currencySymbol: '₹',
        );

        for (final text in [
          data.money(slip.netPayable),
          data.text(slip.staffName),
          data.text(slip.phone),
          data.text(null),
          data.number,
        ]) {
          expect(text.runes.every((r) => r < 0x80), isTrue,
              reason: '"$text" has a character Helvetica cannot draw');
        }
      });
    });
  });

  // A worker could always read their own payslip — the policies allowed it and
  // there was no screen. This is that screen, and the assertion that matters
  // most is the negative one: it shows them theirs and nobody else's.
  group('A worker sees their own pay (A39)', () {
    test('and nobody else\'s, which the demo now enforces as the policies do',
        () async {
      final store = DemoStore()..signedInProfileId = DemoStore.raviId;
      final staff = DemoStaffRepository(store);

      final mine = await staff.payslips();
      expect(mine, isNotEmpty);
      expect(mine.every((p) => p.employeeCode == 'EMP-101'), isTrue,
          reason: 'saw ${mine.map((p) => p.employeeCode).toSet()}');

      final pay = await staff.staffPay();
      expect(pay.every((p) => p.employeeCode == 'EMP-101'), isTrue);

      final advances = await staff.advances();
      expect(advances.every((a) => a.employeeCode == 'EMP-101'), isTrue);
    });

    test('an administrator still sees everybody', () async {
      final store = DemoStore()..signedInProfileId = DemoStore.adminId;
      final staff = DemoStaffRepository(store);

      final all = await staff.payslips();
      expect(all.map((p) => p.employeeCode).toSet().length, greaterThan(1));
    });

    test('nobody signed in sees nothing at all', () async {
      // What the policies do without an auth.uid(), and therefore what the
      // demo has to do with no signed-in profile.
      final staff = DemoStaffRepository(DemoStore());
      expect(await staff.payslips(), isEmpty);
      expect(await staff.staffPay(), isEmpty);
    });

    // Driven through sign-in rather than by rendering the screen on its own:
    // it reads the session to know whose pay to ask for, so a bare render has
    // nobody to show and would prove nothing.
    Future<void> openMyPay(WidgetTester tester) async {
      tallScreen(tester);
      await signIn(tester, 'ravi@diamondpolymers.local');

      await tester.tap(find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text('Profile'),
      ));
      await tester.pumpAndSettle();

      expect(find.text('My pay'), findsOneWidget,
          reason: 'an operator should reach their pay from their profile');
      await tester.tap(find.text('My pay'));
      await tester.pumpAndSettle();
    }

    testWidgets('the screen shows the working, not just a figure',
        (tester) async {
      await openMyPay(tester);

      // Ravi is part paid in the demo's finalised month and has drawn 3,000.
      expect(find.text('Advance to repay'), findsOneWidget);
      expect(find.text('Monthly salary'), findsWidgets);
      expect(find.text('Advance you took'), findsWidgets);
      expect(find.text('Your pay'), findsWidgets);
      expect(find.text('Paid to you'), findsWidgets);
      expect(find.text('Still to come'), findsWidgets);
      // Their own slip, which the policies already allow them to produce.
      expect(find.widgetWithText(TextButton, 'Get slip'), findsWidgets);
      // And the payment that was made, with its date.
      expect(find.text('Payments'), findsWidgets);
    });

    testWidgets('a draft month is not shown as a debt', (tester) async {
      await openMyPay(tester);

      // The demo's current month is a draft. A figure the office has not
      // agreed is not a promise, so it is left off entirely rather than shown
      // as money owed.
      expect(find.text(Fmt.monthYear(DateTime.now())), findsNothing);
      expect(find.text('Draft'), findsNothing);
    });

    testWidgets('an admin does not get the operator pay screen in Profile',
        (tester) async {
      tallScreen(tester);
      await signIn(tester, 'admin@diamondpolymers.local');

      await tester.tap(find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text('More'),
      ));
      await tester.pumpAndSettle();

      // An administrator has the whole payroll under More → Salary. Offering
      // them a personal pay screen as well would be two doors to two different
      // answers.
      expect(find.text('My pay'), findsNothing);
    });
  });

  // A40. The app was phone-first and merely *not broken* on a tablet, which is
  // different from working. These pin both ends: a bottom bar and one column on
  // a phone, a side rail and a capped content width on a tablet.
  group('Phones and tablets (A40)', () {
    testWidgets('a phone keeps the bottom bar', (tester) async {
      tallScreen(tester);
      await signIn(tester, 'ravi@diamondpolymers.local');

      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.byType(NavigationRail), findsNothing);
    });

    testWidgets('a tablet moves navigation to a side rail', (tester) async {
      tabletScreen(tester);
      await signIn(tester, 'ravi@diamondpolymers.local');

      // On a 10" screen a bottom bar is at the far edge of the glass from the
      // hands, and costs a row of height the content wants.
      expect(find.byType(NavigationRail), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);

      // Same destinations, same order — only where they sit changes.
      final rail = find.byType(NavigationRail);
      for (final label in ['Home', 'Material', 'Production', 'My Entries',
        'Profile']) {
        expect(find.descendant(of: rail, matching: find.text(label)),
            findsOneWidget, reason: '$label should be on the rail');
      }
    });

    testWidgets('the admin app gets a rail on a tablet too', (tester) async {
      tabletScreen(tester);
      await signIn(tester, 'admin@diamondpolymers.local');

      expect(find.byType(NavigationRail), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);
    });

    testWidgets('content does not stretch the width of a tablet',
        (tester) async {
      tabletScreen(tester);
      await signIn(tester, 'admin@diamondpolymers.local');

      // PageBody caps the column. Without it a card runs the full width of the
      // pane and the line length is unreadable.
      //
      // PageBody itself fills the pane — it is the box *inside* it that is
      // capped and centred, which is what gets measured.
      final body = find.byType(PageBody);
      expect(body, findsWidgets);
      expect(tester.getSize(body.first).width, greaterThan(840),
          reason: 'the pane is wider than the cap, or this proves nothing');

      final capped = find.descendant(
        of: body.first,
        matching: find.byType(ConstrainedBox),
      );
      expect(tester.getSize(capped.first).width, 840);
    });

    testWidgets('a phone pays nothing for the cap', (tester) async {
      tallScreen(tester);
      await signIn(tester, 'admin@diamondpolymers.local');

      // Below the cap PageBody returns its child untouched — no Align, no
      // ConstrainedBox — so the phone layout is pixel-for-pixel what it was.
      final body = find.byType(PageBody);
      expect(body, findsWidgets);
      expect(tester.getSize(body.first).width, 412);
      expect(
        find.descendant(of: body.first, matching: find.byType(Align)),
        findsNothing,
      );
    });

    test('the breakpoints follow Material, not a device somebody tested on',
        () {
      expect(Breakpoint.fromWidth(360), Breakpoint.compact);
      expect(Breakpoint.fromWidth(599), Breakpoint.compact);
      expect(Breakpoint.fromWidth(600), Breakpoint.medium);
      expect(Breakpoint.fromWidth(1280), Breakpoint.expanded);

      expect(Breakpoint.compact.usesRail, isFalse);
      expect(Breakpoint.medium.usesRail, isTrue);
    });
  });

  // A40: a labourer is on the payroll and nothing else, so the machine screens
  // are not offered to them. The database refuses a run from anybody who is not
  // an operator, so tabs that could only ever fail would be worse than absent.
  group('A labourer gets no machine screens (A40)', () {
    testWidgets('no Material or Production tab', (tester) async {
      tallScreen(tester);
      await signIn(tester, 'lakha@diamondpolymers.local');

      final bar = find.byType(NavigationBar);
      expect(find.descendant(of: bar, matching: find.text('Home')),
          findsOneWidget);
      expect(find.descendant(of: bar, matching: find.text('My Entries')),
          findsOneWidget);
      expect(find.descendant(of: bar, matching: find.text('Profile')),
          findsOneWidget);

      expect(find.descendant(of: bar, matching: find.text('Material')),
          findsNothing);
      expect(find.descendant(of: bar, matching: find.text('Production')),
          findsNothing);
    });

    testWidgets('but still their own pay', (tester) async {
      tallScreen(tester);
      await signIn(tester, 'lakha@diamondpolymers.local');

      await tester.tap(find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text('Profile'),
      ));
      await tester.pumpAndSettle();

      expect(find.text('My pay'), findsOneWidget);
    });

    test('an operator still gets the machine screens', () {
      const operator = AppUser(
        profileId: 'p1',
        authUserId: 'a1',
        name: 'Ravi',
        employeeCode: 'EMP-101',
        role: UserRole.operator,
        active: true,
      );
      expect(operator.runsMachines, isTrue);

      const labourer = AppUser(
        profileId: 'p2',
        authUserId: 'a2',
        name: 'Lakha',
        employeeCode: 'EMP-201',
        role: UserRole.operator,
        active: true,
        employeeTypeName: 'Labourer',
        runsMachines: false,
      );
      expect(labourer.runsMachines, isFalse);
    });
  });

  // A41: the three roles became master data, so the factory can add their own.
  group('The factory names its own roles (A41)', () {
    test('a new role is created with a code made from its name', () async {
      final store = DemoStore()..signedInProfileId = DemoStore.adminId;
      final repo = DemoMastersRepository(store);

      final made = await repo.saveEmployeeType(
        name: 'Shift Supervisor',
        description: 'Runs a machine and watches the line',
        runsMachines: true,
      );

      expect(made['created'], isTrue);
      expect(made['code'], 'SHIFT_SUPERVISOR');

      final roles = await repo.employeeTypes();
      final added = roles.firstWhere((r) => r.code == 'SHIFT_SUPERVISOR');
      expect(added.name, 'Shift Supervisor');
      expect(added.runsMachines, isTrue);
      expect(added.isSystem, isFalse);
      expect(added.activeStaff, 0);
    });

    test('a role defaults to not running machines', () async {
      final store = DemoStore()..signedInProfileId = DemoStore.adminId;
      final repo = DemoMastersRepository(store);

      await repo.saveEmployeeType(name: 'Helper');
      final helper =
          (await repo.employeeTypes()).firstWhere((r) => r.code == 'HELPER');

      // The safe default: a new role gets no machine rights until the factory
      // says it should have them.
      expect(helper.runsMachines, isFalse);
    });

    test('two roles of the same name are refused', () async {
      final store = DemoStore()..signedInProfileId = DemoStore.adminId;
      final repo = DemoMastersRepository(store);

      await repo.saveEmployeeType(name: 'Helper');
      expect(
        () => repo.saveEmployeeType(name: 'Helper'),
        throwsA(isA<AppException>()
            .having((e) => e.message, 'message', contains('already exists'))),
      );
    });

    test('somebody can be put on a role the factory invented', () async {
      final store = DemoStore()..signedInProfileId = DemoStore.adminId;
      final repo = DemoMastersRepository(store);

      await repo.saveEmployeeType(name: 'Fitter', runsMachines: true);
      await repo.saveStaff(
        name: 'Prakash Shah',
        employeeCode: 'EMP-401',
        role: 'OPERATOR',
        active: true,
        employeeType: 'FITTER',
        monthlySalary: 30000,
      );

      final person = (await repo.staff())
          .firstWhere((p) => p.employeeCode == 'EMP-401');
      expect(person.employeeTypeCode, 'FITTER');
      expect(person.employeeTypeName, 'Fitter');
      // The role said it runs machines, so this person does.
      expect(person.runsMachines, isTrue);
    });

    test('a role nobody has heard of is refused', () async {
      final store = DemoStore()..signedInProfileId = DemoStore.adminId;
      final repo = DemoMastersRepository(store);

      expect(
        () => repo.saveStaff(
          name: 'Nobody',
          employeeCode: 'EMP-402',
          role: 'OPERATOR',
          active: true,
          employeeType: 'DOES_NOT_EXIST',
        ),
        throwsA(isA<AppException>()),
      );
    });

    test('renaming a role does not strip what it can do', () async {
      final store = DemoStore()..signedInProfileId = DemoStore.adminId;
      final repo = DemoMastersRepository(store);

      await repo.saveEmployeeType(name: 'Fitter', runsMachines: true);
      final before =
          (await repo.employeeTypes()).firstWhere((r) => r.code == 'FITTER');

      // Only the name is given. Null must mean "leave as it is" — a default of
      // false here would quietly ground everybody on the role.
      await repo.saveEmployeeType(id: before.id, name: 'Senior Fitter');

      final after =
          (await repo.employeeTypes()).firstWhere((r) => r.code == 'FITTER');
      expect(after.name, 'Senior Fitter');
      expect(after.runsMachines, isTrue, reason: 'a rename is not a demotion');
      expect(after.code, 'FITTER', reason: 'the code never moves');
    });

    test('a role somebody is on cannot be switched off', () async {
      final store = DemoStore()..signedInProfileId = DemoStore.adminId;
      final repo = DemoMastersRepository(store);

      final labourer = (await repo.employeeTypes())
          .firstWhere((r) => r.code == 'LABOURER');
      expect(labourer.activeStaff, greaterThan(0));

      expect(
        () => repo.saveEmployeeType(
            id: labourer.id, name: labourer.name, active: false),
        throwsA(isA<AppException>()
            .having((e) => e.message, 'message', contains('Move them'))),
      );
    });

    test('Operator cannot be switched off or grounded', () async {
      final store = DemoStore()..signedInProfileId = DemoStore.adminId;
      final repo = DemoMastersRepository(store);

      final op = (await repo.employeeTypes())
          .firstWhere((r) => r.code == EmployeeType.operatorCode);
      expect(op.isSystem, isTrue);
      expect(op.canBeRetired, isFalse);

      // With no machine-running role, nobody in the factory could record
      // production at all.
      expect(
        () => repo.saveEmployeeType(id: op.id, name: op.name, active: false),
        throwsA(isA<AppException>()),
      );
      expect(
        () => repo.saveEmployeeType(
            id: op.id, name: op.name, runsMachines: false),
        throwsA(isA<AppException>()),
      );
    });

    testWidgets('the roles screen lists them with how many hold each',
        (tester) async {
      tallScreen(tester);
      await tester.pumpWidget(demoScope(
        signedInProfileId: DemoStore.adminId,
        child: MaterialApp(
            theme: AppTheme.light(), home: const EmployeeRolesScreen()),
      ));
      await tester.pumpAndSettle();

      expect(find.text('Employee roles'), findsOneWidget);
      expect(find.text('Operator'), findsOneWidget);
      expect(find.text('Labourer'), findsOneWidget);
      expect(find.text('Office'), findsOneWidget);

      // The built-in one is marked, so the screen can protect it.
      expect(find.text('built in'), findsOneWidget);
      // And the count is what tells an admin whether a role can be retired.
      expect(find.textContaining('Runs machines'), findsWidgets);
    });

    testWidgets('a new role appears on the employee form', (tester) async {
      tallScreen(tester);
      final store = DemoStore()..signedInProfileId = DemoStore.adminId;

      await tester.runAsync(() async {
        await DemoMastersRepository(store)
            .saveEmployeeType(name: 'Supervisor', runsMachines: true);
      });

      await tester.pumpWidget(demoScope(
        store: store,
        child:
            MaterialApp(theme: AppTheme.light(), home: const OperatorsScreen()),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(DropdownButtonFormField<String>).first);
      await tester.pumpAndSettle();

      // The role the factory just invented is offered beside the built-in ones.
      expect(find.text('Supervisor'), findsWidgets);
      expect(find.text('Operator'), findsWidgets);
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
