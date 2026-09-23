import 'package:diamond_polymers/core/theme/app_theme.dart';
import 'package:diamond_polymers/features/masters/data/masters_repository.dart';
import 'package:diamond_polymers/features/masters/domain/masters.dart';
import 'package:diamond_polymers/features/masters/presentation/machines_screen.dart';
import 'package:diamond_polymers/features/masters/presentation/operators_screen.dart';
import 'package:diamond_polymers/features/masters/presentation/products_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Phase 2 master screens, rendered against fixed data.
///
/// The providers are overridden rather than the repository, so these exercise
/// what the screens do with rows — including the states that are easy to get
/// wrong and invisible in a happy-path demo: a machine nobody is assigned to, a
/// person with no login, a product whose weight is missing from the catalogue.
void main() {
  // Riverpod 3 keeps `Override` sealed and out of its public exports, so the
  // list cannot be named in a signature. Taking `Object` and casting is the
  // accommodation; every caller passes real overrides, so the cast cannot fail.
  Widget wrap(Widget child, List<Object> overrides) => ProviderScope(
        overrides: overrides.cast(),
        child: MaterialApp(theme: AppTheme.light(), home: child),
      );

  final machine = Machine.from(const {
    'id': 'm1',
    'code': 'M1',
    'name': 'Machine 1',
    'description': 'Braiding line 1',
    'status': 'ACTIVE',
    'active': true,
  });

  final idleMachine = Machine.from(const {
    'id': 'm4',
    'code': 'M4',
    'name': 'Machine 4',
    'status': 'MAINTENANCE',
    'active': true,
  });

  final assignment = MachineAssignment.from(const {
    'assignment_id': 'a1',
    'operator_id': 'p1',
    'operator_name': 'Ravi Kumar',
    'employee_code': 'EMP-101',
    'machine_id': 'm1',
    'machine_name': 'Machine 1',
    'machine_code': 'M1',
    'shift_id': 's1',
    'shift_name': 'Morning',
    'effective_from': '2026-01-01',
  });

  group('MachinesScreen', () {
    testWidgets('shows each line with its status and who is on it',
        (tester) async {
      await tester.pumpWidget(wrap(const MachinesScreen(), [
        machinesProvider.overrideWith((ref) async => [machine, idleMachine]),
        assignmentsProvider.overrideWith((ref) async => [assignment]),
        machineProductIdsProvider.overrideWith((ref, id) async => {'x', 'y'}),
      ]));
      await tester.pumpAndSettle();

      expect(find.text('Machine 1'), findsOneWidget);
      expect(find.text('Ravi Kumar'), findsOneWidget);
      expect(find.text('Maintenance'), findsOneWidget);
      expect(find.text('2 products'), findsNWidgets(2));
    });

    testWidgets('a machine with nobody on it says so rather than looking empty',
        (tester) async {
      await tester.pumpWidget(wrap(const MachinesScreen(), [
        machinesProvider.overrideWith((ref) async => [idleMachine]),
        assignmentsProvider.overrideWith((ref) async => const []),
        machineProductIdsProvider.overrideWith((ref, id) async => <String>{}),
      ]));
      await tester.pumpAndSettle();

      expect(find.text('Unassigned'), findsOneWidget);
      // No configured products means unconstrained, not broken.
      expect(find.text('Any product'), findsOneWidget);
    });

    testWidgets('an empty factory explains what to do next', (tester) async {
      await tester.pumpWidget(wrap(const MachinesScreen(), [
        machinesProvider.overrideWith((ref) async => const []),
        assignmentsProvider.overrideWith((ref) async => const []),
      ]));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Add the first production line'),
        findsOneWidget,
      );
    });
  });

  group('OperatorsScreen', () {
    final withLogin = StaffMember.from(const {
      'id': 'p1',
      'name': 'Ravi Kumar',
      'employee_code': 'EMP-101',
      'role': 'OPERATOR',
      'active': true,
      'auth_user_id': 'auth-1',
    });

    final withoutLogin = StaffMember.from(const {
      'id': 'p2',
      'name': 'Suresh Patel',
      'employee_code': 'EMP-102',
      'role': 'OPERATOR',
      'active': true,
      'auth_user_id': null,
    });

    testWidgets('distinguishes a person with a login from one without',
        (tester) async {
      await tester.pumpWidget(wrap(const OperatorsScreen(), [
        staffProvider.overrideWith((ref) async => [withLogin, withoutLogin]),
        assignmentsProvider.overrideWith((ref) async => [assignment]),
      ]));
      await tester.pumpAndSettle();

      // A3: an operator with no login is a supported, normal state.
      expect(find.text('Can sign in'), findsOneWidget);
      expect(find.text('No login'), findsOneWidget);
    });

    testWidgets('shows the machine and shift a person is assigned to',
        (tester) async {
      await tester.pumpWidget(wrap(const OperatorsScreen(), [
        staffProvider.overrideWith((ref) async => [withLogin, withoutLogin]),
        assignmentsProvider.overrideWith((ref) async => [assignment]),
      ]));
      await tester.pumpAndSettle();

      expect(find.text('M1 · Morning'), findsOneWidget);
      expect(find.text('No machine'), findsOneWidget);
    });

    testWidgets('marks administrators', (tester) async {
      final admin = StaffMember.from(const {
        'id': 'p0',
        'name': 'Factory Admin',
        'employee_code': 'EMP-001',
        'role': 'ADMIN',
        'active': true,
        'auth_user_id': 'auth-0',
      });

      await tester.pumpWidget(wrap(const OperatorsScreen(), [
        staffProvider.overrideWith((ref) async => [admin]),
        assignmentsProvider.overrideWith((ref) async => const []),
      ]));
      await tester.pumpAndSettle();

      expect(find.text('Admin'), findsOneWidget);
    });
  });

  group('at phone width', () {
    // The default test surface is 800x600 — wider than any phone this runs on.
    // A row that fits there and overflows on a real handset is the single most
    // likely visual bug in these screens, and it only shows up if the test is
    // told to be narrow.
    setUp(() => TestWidgetsFlutterBinding.ensureInitialized());

    Future<void> atPhoneSize(WidgetTester tester, Widget scope) async {
      await tester.binding.setSurfaceSize(const Size(360, 780));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(scope);
      await tester.pumpAndSettle();
    }

    testWidgets('the machine list fits a 360px screen', (tester) async {
      await atPhoneSize(
        tester,
        wrap(const MachinesScreen(), [
          machinesProvider.overrideWith((ref) async => [machine, idleMachine]),
          assignmentsProvider.overrideWith((ref) async => [assignment]),
          machineProductIdsProvider.overrideWith((ref, id) async => {'x'}),
        ]),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('the product list fits a 360px screen', (tester) async {
      // Four figures across one row is the tightest layout in the app.
      final product = PipeProduct.from(const {
        'pipe_product_id': 'pp1',
        'sku': 'TB-S4',
        'pipe_type_id': 't1',
        'pipe_type_name': 'Heavy Duty Braided',
        'pipe_size_id': 'z1',
        'pipe_size_name': 'Size 4 (1.25 inch)',
        'bundle_weight_kg': '47.500',
        'active': true,
        'quantity_bundles': 12345,
        'stock_weight_kg': '586387.500',
        'minimum_stock': 150,
        'status': 'GOOD',
        'diameter_mm': '31.75',
      });

      await atPhoneSize(
        tester,
        wrap(const ProductsScreen(), [
          productsProvider.overrideWith((ref) async => [product]),
        ]),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('the operator list fits a 360px screen', (tester) async {
      final person = StaffMember.from(const {
        'id': 'p1',
        'name': 'Ganesh Ramachandran Jadhav',
        'employee_code': 'EMP-104',
        'role': 'ADMIN',
        'active': false,
        'auth_user_id': null,
      });

      await atPhoneSize(
        tester,
        wrap(const OperatorsScreen(), [
          staffProvider.overrideWith((ref) async => [person]),
          assignmentsProvider.overrideWith((ref) async => const []),
        ]),
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('ProductsScreen', () {
    final product = PipeProduct.from(const {
      'pipe_product_id': 'pp1',
      'sku': 'TA-S1',
      'pipe_type_id': 't1',
      'pipe_type_name': 'Type A',
      'pipe_size_id': 'z1',
      'pipe_size_name': 'Size 1',
      'bundle_weight_kg': '18.500',
      'active': true,
      'quantity_bundles': 203,
      'stock_weight_kg': '3755.500',
      'minimum_stock': 15,
      'status': 'GOOD',
      'diameter_mm': '12.70',
      'pipes_per_bundle': 10,
    });

    testWidgets('reports stock in both units, which is the point of a weight',
        (tester) async {
      await tester.pumpWidget(wrap(const ProductsScreen(), [
        productsProvider.overrideWith((ref) async => [product]),
      ]));
      await tester.pumpAndSettle();

      expect(find.text('Type A — Size 1'), findsOneWidget);

      // The figures are `Text.rich`, so the value and its unit can carry
      // different styles on one line. `find.text` skips rich text unless asked.
      expect(find.text('18.5 kg', findRichText: true),
          findsOneWidget); // per bundle
      expect(find.textContaining('203', findRichText: true),
          findsWidgets); // bundles in stock
      expect(find.textContaining('3,755.5', findRichText: true),
          findsOneWidget); // the same stock, in kilograms
    });

    testWidgets('a numeric arriving as a String still renders', (tester) async {
      // Postgres numerics come over PostgREST as Strings. Parsing them as num
      // would silently render every weight as zero.
      expect(product.bundleWeightKg, 18.5);
      expect(product.stockWeightKg, 3755.5);
      expect(product.diameterMm, 12.70);
    });

    testWidgets('an empty catalogue says production is blocked', (tester) async {
      await tester.pumpWidget(wrap(const ProductsScreen(), [
        productsProvider.overrideWith((ref) async => const []),
      ]));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Production cannot be recorded'),
        findsOneWidget,
      );
    });

    testWidgets('a product with no reorder level shows a dash, not zero',
        (tester) async {
      final noThreshold = PipeProduct.from({
        ...const {
          'pipe_product_id': 'pp2',
          'sku': 'TB-S4',
          'pipe_type_id': 't2',
          'pipe_type_name': 'Type B',
          'pipe_size_id': 'z4',
          'pipe_size_name': 'Size 4',
          'bundle_weight_kg': '47.500',
          'active': true,
          'quantity_bundles': 0,
          'stock_weight_kg': '0',
          'minimum_stock': 0,
          'status': 'OUT',
        },
      });

      await tester.pumpWidget(wrap(const ProductsScreen(), [
        productsProvider.overrideWith((ref) async => [noThreshold]),
      ]));
      await tester.pumpAndSettle();

      expect(find.text('—'), findsOneWidget);
      expect(find.text('Out of stock'), findsOneWidget);
    });
  });
}
