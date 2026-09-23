import 'package:diamond_polymers/core/theme/app_theme.dart';
import 'package:diamond_polymers/features/dashboard/domain/dashboard_models.dart';
import 'package:diamond_polymers/features/inventory/domain/inventory.dart';
import 'package:diamond_polymers/features/masters/data/masters_repository.dart';
import 'package:diamond_polymers/features/masters/domain/masters.dart';
import 'package:diamond_polymers/features/mixture/presentation/mixture_entry_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Phase 3: Inventory and Raw Material Entry.
///
/// The mixture screen carries most of these, because it is the one an operator
/// uses under time pressure and the one where a wrong number costs material.
void main() {
  Widget wrap(Widget child, List<Object> overrides) => ProviderScope(
        overrides: overrides.cast(),
        child: MaterialApp(theme: AppTheme.light(), home: child),
      );

  final raizin = RawMaterial.from(const {
    'raw_material_id': 'rm1',
    'code': 'RM-RAIZIN',
    'name': 'Raizin',
    'category': 'RAIZIN',
    'category_name': 'Raizin',
    'unit': 'kg',
    'minimum_stock': '2000',
    'quantity': '2725.778',
    'status': 'GOOD',
    'active': true,
  });

  final chemical = RawMaterial.from(const {
    'raw_material_id': 'rm2',
    'code': 'RM-CHEM',
    'name': 'Chemical',
    'category': 'CHEMICAL',
    'category_name': 'Chemical',
    'unit': 'kg',
    'minimum_stock': '400',
    'quantity': '343.355',
    'status': 'LOW',
    'active': true,
  });

  final regrind = RawMaterial.from(const {
    'raw_material_id': 'rm3',
    'code': 'RM-REGRIND-A',
    'name': 'Regrind — Standard',
    'category': 'RECYCLED',
    'category_name': 'Recycled / Shredded',
    'unit': 'kg',
    'minimum_stock': '0',
    'quantity': '33.7',
    'status': 'GOOD',
    'active': true,
  });

  final machine1 = Machine.from(const {
    'id': 'm1',
    'code': 'M1',
    'name': 'Machine 1',
    'description': null,
    'status': 'ACTIVE',
    'active': true,
  });

  final ravisAssignment = MachineAssignment.from(const {
    'assignment_id': 'a1',
    'operator_id': 'p1',
    'operator_name': 'Ravi Kumar',
    'employee_code': 'EMP-101',
    'machine_id': 'm1',
    'machine_name': 'Machine 1',
    'machine_code': 'M1',
    'shift_id': 's1',
    'shift_name': 'Morning',
    'effective_from': '2026-09-01',
  });

  List<Object> mixtureOverrides({
    bool withMachines = true,
    bool assigned = true,
  }) =>
      [
        machinesProvider
            .overrideWith((ref) async => withMachines ? [machine1] : const []),
        assignmentsProvider.overrideWith(
            (ref) async => assigned ? [ravisAssignment] : const []),
        rawMaterialsProvider
            .overrideWith((ref) async => [raizin, chemical, regrind]),
        shiftsProvider.overrideWith((ref) async => [
              Shift.from(const {
                'id': 's1',
                'name': 'Morning',
                'start_time': '06:00:00',
                'end_time': '14:00:00',
                'active': true,
              }),
            ]),
      ];

  group('MixtureEntryScreen', () {
    testWidgets('with no machines configured, it says so', (tester) async {
      await tester.pumpWidget(
        wrap(const MixtureEntryScreen(), mixtureOverrides(withMachines: false)),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('No machines are configured'), findsOneWidget);
      expect(find.text('Review'), findsNothing);
    });

    testWidgets('the admin picks the machine and sees who is credited (A30)',
        (tester) async {
      await tester.pumpWidget(
        wrap(const MixtureEntryScreen(), mixtureOverrides()),
      );
      await tester.pumpAndSettle();

      expect(find.text('Material Entry'), findsOneWidget);
      expect(find.textContaining('Choose the machine'), findsOneWidget);

      await tester.tap(find.text('Machine 1'));
      await tester.pump();

      expect(find.text('Credited to Ravi Kumar.'), findsOneWidget);
    });

    testWidgets('a machine nobody runs is credited to the admin',
        (tester) async {
      await tester.pumpWidget(
        wrap(const MixtureEntryScreen(), mixtureOverrides(assigned: false)),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Machine 1'));
      await tester.pump();

      expect(find.textContaining('recorded against your account'),
          findsOneWidget);
    });

    testWidgets('every material shows what is actually in stock',
        (tester) async {
      // Tall enough that the list builds every material row at once.
      await tester.binding.setSurfaceSize(const Size(800, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        wrap(const MixtureEntryScreen(), mixtureOverrides()),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('In stock 2,725.778 kg'), findsOneWidget);
      expect(find.textContaining('In stock 343.355 kg'), findsOneWidget);
      // Regrind is raw material like any other, and says so.
      expect(find.textContaining('regrind'), findsOneWidget);
    });

    testWidgets('the running total adds the lines up', (tester) async {
      await tester.pumpWidget(
        wrap(const MixtureEntryScreen(), mixtureOverrides()),
      );
      await tester.pumpAndSettle();

      final fields = find.byType(TextFormField);
      await tester.enterText(fields.at(0), '20');
      await tester.pump();
      await tester.enterText(fields.at(1), '4.5');
      await tester.pump();

      expect(find.textContaining('24.5', findRichText: true), findsWidgets);
      expect(find.textContaining('2 materials', findRichText: true),
          findsOneWidget);
    });

    testWidgets('Review stays disabled until something is entered',
        (tester) async {
      await tester.pumpWidget(
        wrap(const MixtureEntryScreen(), mixtureOverrides()),
      );
      await tester.pumpAndSettle();

      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Review'),
      );
      expect(button.onPressed, isNull);

      await tester.enterText(find.byType(TextFormField).at(0), '10');
      await tester.pump();

      // Quantities alone are not enough: the machine has to be chosen too.
      final stillOff = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Review'),
      );
      expect(stillOff.onPressed, isNull);

      await tester.tap(find.text('Machine 1'));
      await tester.pump();

      final enabled = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Review'),
      );
      expect(enabled.onPressed, isNotNull);
    });

    testWidgets('entering more than there is warns before submitting',
        (tester) async {
      // A hint, not a verdict — the database is still the authority — but it
      // catches the common case before a batch is thrown away.
      await tester.pumpWidget(
        wrap(const MixtureEntryScreen(), mixtureOverrides()),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextFormField).at(1), '5000');
      await tester.pump();

      expect(find.text('Only 343.355'), findsOneWidget);
    });

    testWidgets('the confirmation summary lists the batch before it is written',
        (tester) async {
      await tester.pumpWidget(
        wrap(const MixtureEntryScreen(), mixtureOverrides()),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Machine 1'));
      await tester.pump();
      await tester.enterText(find.byType(TextFormField).at(0), '20');
      await tester.pump();
      await tester.enterText(find.byType(TextFormField).at(1), '4');
      await tester.pump();

      await tester.tap(find.widgetWithText(FilledButton, 'Review'));
      await tester.pumpAndSettle();

      expect(find.text('Confirm this batch'), findsOneWidget);
      expect(find.text('Raizin'), findsWidgets);
      expect(find.text('24 kg'), findsOneWidget);
      expect(find.text('Record batch'), findsOneWidget);
      // §44: nothing is written until this is confirmed.
      expect(find.text('Go back and change it'), findsOneWidget);
    });

    testWidgets('fits a 360px screen with three materials', (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 780));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        wrap(const MixtureEntryScreen(), mixtureOverrides()),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });
  });

  group('Inventory models', () {
    test('finished goods survive numerics arriving as Strings', () {
      final row = FinishedGoodsStock.from(const {
        'pipe_type_id': 't1',
        'pipe_type_name': 'Type A',
        'pipe_size_id': 'z1',
        'pipe_size_name': 'Size 1',
        'quantity_bundles': '203',
        'minimum_stock': '15',
        'status': 'GOOD',
        'sort_order': '1',
      });

      expect(row.bundles, 203);
      expect(row.minimumStock, 15);
      expect(row.label, 'Type A · Size 1');
      expect(row.productKey, 't1|z1');
    });

    test('regrind reports both halves of the loop', () {
      final pool = RecycledStock.from(const {
        'raw_material_id': 'rm3',
        'code': 'RM-REGRIND-A',
        'name': 'Regrind — Standard',
        'unit': 'kg',
        'quantity': '33.700',
        'total_recovered_kg': '43.700',
        'total_consumed_kg': '10.000',
      });

      expect(pool.quantity, 33.7);
      // What the shredder produced, less what mixtures have taken back.
      expect(pool.totalRecovered - pool.totalConsumed, pool.quantity);
    });

    test('a missing figure reads as zero rather than throwing', () {
      final pool = RecycledStock.from(const {
        'raw_material_id': 'rm4',
        'code': 'RM-REGRIND-B',
        'name': 'Regrind — Heavy',
        'unit': 'kg',
        'quantity': null,
        'total_recovered_kg': null,
        'total_consumed_kg': null,
      });

      expect(pool.quantity, 0);
      expect(pool.totalRecovered, 0);
    });
  });
}
