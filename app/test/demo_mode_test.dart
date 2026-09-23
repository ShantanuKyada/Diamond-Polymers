import 'package:diamond_polymers/app.dart';
import 'package:diamond_polymers/core/demo/demo_overrides.dart';
import 'package:diamond_polymers/core/demo/demo_repositories.dart';
import 'package:diamond_polymers/core/demo/demo_store.dart';
import 'package:diamond_polymers/core/utils/formatters.dart';
import 'package:diamond_polymers/core/error/app_exception.dart';
import 'package:diamond_polymers/features/mixture/data/mixture_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Demo mode boots the real application — real router, real screens, real
/// controllers — with only the repository layer swapped. These tests drive it
/// end to end, which is the closest thing to "run the frontend" that can be
/// asserted automatically.
void main() {
  // Demo reads are deliberately slow so loading states are visible; in a widget
  // test that only leaves pending timers behind.
  setUp(() => DemoStore.latency = Duration.zero);
  tearDown(() => DemoStore.latency = const Duration(milliseconds: 320));

  group('the app runs end to end with no backend', () {
    testWidgets('signs in as admin and reaches the dashboard', (tester) async {
      // The dashboard is a long ListView, which builds lazily. A taller surface
      // brings the lower sections into the render tree so they can be asserted.
      tester.view.physicalSize = const Size(1100, 3000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(demoScope(child: const DiamondPolymersApp()));
      await tester.pumpAndSettle();

      expect(find.widgetWithText(FilledButton, 'Sign in'), findsOneWidget);

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Email'),
        'admin@diamondpolymers.local',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Password'),
        'demo1234',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
      await tester.pumpAndSettle();

      // The admin shell, not the operator one.
      expect(find.text('Dashboard'), findsWidgets);
      expect(find.text('Inventory'), findsWidgets);
      expect(find.text('Dispatch'), findsWidgets);

      // Figures came from the demo store rather than a placeholder.
      expect(find.text("Today's production"), findsOneWidget);
      expect(find.text('Raw material stock'), findsOneWidget);
      expect(find.text('Chemical'), findsWidgets);
    });

    testWidgets('signs in as an operator and reaches the operator home',
        (tester) async {
      await tester.pumpWidget(demoScope(child: const DiamondPolymersApp()));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Email'),
        'ravi@diamondpolymers.local',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Password'),
        'demo1234',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
      await tester.pumpAndSettle();

      // The operator application: no admin destinations anywhere.
      expect(find.text('Home'), findsWidgets);
      expect(find.text('My Entries'), findsWidgets);
      expect(find.text('Dispatch'), findsNothing);

      // The assignment the demo store seeded.
      expect(find.text('Ravi Kumar'), findsWidgets);
      expect(find.text('Machine 1'), findsWidgets);
    });
  });

  group('the demo repositories keep the rules the database keeps', () {
    test('a mixture short on one material deducts nothing at all', () async {
      final store = DemoStore();
      final repository = DemoMixtureRepository(store..signedInProfileId = DemoStore.adminId);

      final chemicalBefore =
          store.materialById(DemoStore.chemicalId)!['quantity'] as num;
      final raizinBefore =
          store.materialById(DemoStore.raizinId)!['quantity'] as num;

      // Chemical is seeded at 38 kg, so 500 kg cannot be satisfied.
      await expectLater(
        repository.consume(
          machineId: DemoStore.machine1,
          shiftId: DemoStore.shiftMorning,
          clientRef: 'ref-short',
          lines: const [
            MixtureLine(rawMaterialId: DemoStore.raizinId, quantity: 25),
            MixtureLine(rawMaterialId: DemoStore.chemicalId, quantity: 500),
          ],
        ),
        throwsA(isA<AppException>().having(
          (e) => e.kind,
          'kind',
          AppErrorKind.insufficientStock,
        )),
      );

      // §16: the Raizin in the same basket must be untouched.
      expect(
        store.materialById(DemoStore.raizinId)!['quantity'],
        raizinBefore,
        reason: 'a refused batch must not deduct the materials it could satisfy',
      );
      expect(
        store.materialById(DemoStore.chemicalId)!['quantity'],
        chemicalBefore,
      );
    });

    test('a successful mixture deducts every line', () async {
      final store = DemoStore();
      final repository = DemoMixtureRepository(store..signedInProfileId = DemoStore.adminId);

      final before = store.materialById(DemoStore.raizinId)!['quantity'] as num;

      final result = await repository.consume(
        machineId: DemoStore.machine1,
        shiftId: DemoStore.shiftMorning,
        clientRef: 'ref-ok',
        lines: const [
          MixtureLine(rawMaterialId: DemoStore.raizinId, quantity: 25),
          MixtureLine(rawMaterialId: DemoStore.colorId, quantity: 2),
        ],
      );

      expect(result.duplicate, isFalse);
      expect(result.totalQuantity, 27);
      expect(store.materialById(DemoStore.raizinId)!['quantity'], before - 25);
    });

    test('a retried submission is reported as a duplicate, not applied twice',
        () async {
      final store = DemoStore();
      final repository = DemoMixtureRepository(store..signedInProfileId = DemoStore.adminId);
      const ref = 'ref-retry';

      await repository.consume(
        machineId: DemoStore.machine1,
        shiftId: DemoStore.shiftMorning,
        clientRef: ref,
        lines: const [
          MixtureLine(rawMaterialId: DemoStore.raizinId, quantity: 10),
        ],
      );
      final after = store.materialById(DemoStore.raizinId)!['quantity'] as num;

      final retry = await repository.consume(
        machineId: DemoStore.machine1,
        shiftId: DemoStore.shiftMorning,
        clientRef: ref,
        lines: const [
          MixtureLine(rawMaterialId: DemoStore.raizinId, quantity: 10),
        ],
      );

      expect(retry.duplicate, isTrue);
      expect(store.materialById(DemoStore.raizinId)!['quantity'], after,
          reason: 'a double tap must not deduct the batch twice (§47)');
    });

    test('an adjustment cannot drive stock below zero', () async {
      final store = DemoStore();
      final repository = DemoInventoryRepository(store);

      await expectLater(
        repository.adjust(
          rawMaterialId: DemoStore.chemicalId,
          delta: -9999,
          clientRef: 'ref-neg',
          remarks: 'stock take',
        ),
        throwsA(isA<AppException>().having(
          (e) => e.kind,
          'kind',
          AppErrorKind.insufficientStock,
        )),
      );
    });

    test('an adjustment without a reason is refused', () async {
      final store = DemoStore();
      final repository = DemoInventoryRepository(store);

      await expectLater(
        repository.adjust(
          rawMaterialId: DemoStore.chemicalId,
          delta: -1,
          clientRef: 'ref-noreason',
          remarks: '   ',
        ),
        throwsA(isA<AppException>().having(
          (e) => e.kind,
          'kind',
          AppErrorKind.validation,
        )),
      );
    });

    test('stock-in raises the balance and clears a low-stock status', () async {
      final store = DemoStore();
      final repository = DemoInventoryRepository(store);

      expect(store.materialById(DemoStore.chemicalId)!['status'], 'LOW');

      await repository.stockIn(
        rawMaterialId: DemoStore.chemicalId,
        quantity: 200,
        clientRef: 'ref-in',
      );

      expect(store.materialById(DemoStore.chemicalId)!['quantity'], 238.0);
      expect(store.materialById(DemoStore.chemicalId)!['status'], 'GOOD');
    });
  });

  group('the demo dashboards agree with the store', () {
    test('admin totals are derived, not hard-coded', () async {
      final store = DemoStore();
      final dashboard = await DemoDashboardRepository(store).loadAdmin(
        DateTime.now(),
      );

      // The dashboard is about today; the store also holds the past week.
      final today = Fmt.isoDate(DateTime.now());
      final todays = store.productionEntries
          .where((e) => e['entry_date'] == today)
          .toList();
      final expected =
          todays.fold<int>(0, (sum, e) => sum + (e['bundle_quantity'] as int));

      expect(dashboard.bundlesToday, expected);
      expect(dashboard.entryCount, todays.length);
      expect(todays.length, lessThan(store.productionEntries.length),
          reason: 'older entries exist and must not be counted');
      expect(dashboard.productionByMachine, isNotEmpty);

      // Chemical is under threshold and Type A Size 2 is low, so the alert
      // list the dashboard renders should not be empty.
      expect(dashboard.alerts, isNotEmpty);
    });

    test('the operator dashboard reports only that operator', () async {
      final store = DemoStore();
      final dashboard = await DemoDashboardRepository(store).loadOperator(
        DateTime.now(),
      );

      final today = Fmt.isoDate(DateTime.now());
      final mine = store.productionEntries
          .where((e) => e['operator_id'] == DemoStore.raviId)
          .where((e) => e['entry_date'] == today)
          .fold<int>(0, (sum, e) => sum + (e['bundle_quantity'] as int));

      expect(dashboard.bundlesToday, mine);
      expect(dashboard.assignment, isNotNull);
      expect(dashboard.assignment!.machineName, 'Machine 1');
      expect(dashboard.recentProduction, isNotEmpty);
    });
  });
}
