import 'package:diamond_polymers/app.dart';
import 'package:diamond_polymers/core/demo/demo_overrides.dart';
import 'package:diamond_polymers/core/demo/demo_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A fresh install opens onto an empty factory, not somebody else's numbers.
///
/// The master data a factory cannot work without — machines, shifts, pipe
/// types and sizes, products and their packaging, material definitions,
/// employee types, settings — is still there. Everything that is a record of
/// work is not, and every balance starts at zero.
void main() {
  setUp(() => DemoStore.latency = Duration.zero);
  tearDown(() => DemoStore.latency = const Duration(milliseconds: 320));

  group('A clean install', () {
    final store = DemoStore();

    test('keeps the master data', () {
      expect(store.machines, isNotEmpty, reason: 'machines');
      expect(store.shifts.length, 2, reason: 'Morning and Night');
      expect(store.pipeTypes, isNotEmpty, reason: 'pipe types');
      expect(store.pipeSizes, isNotEmpty, reason: 'pipe sizes');
      expect(store.products, isNotEmpty, reason: 'products and packaging');
      expect(store.rawMaterials, isNotEmpty, reason: 'material definitions');
      expect(store.employeeTypes, isNotEmpty, reason: 'employee types');
      expect(store.settings, isNotEmpty, reason: 'configuration');
    });

    test('has one administrator and nobody else', () {
      expect(store.staff.length, 1);
      expect(store.staff.single['role'], 'ADMIN');
      expect(store.staff.single['employee_code'], 'EMP-001');
      // The invented operators are gone, along with their assignments.
      expect(store.assignments, isEmpty);
    });

    test('holds no record of work', () {
      expect(store.productionEntries, isEmpty, reason: 'production');
      expect(store.dispatchRows, isEmpty, reason: 'dispatch');
      expect(store.wastageRows, isEmpty, reason: 'wastage');
      expect(store.attendanceRows, isEmpty, reason: 'attendance');
      expect(store.payslipRows, isEmpty, reason: 'payslips');
      expect(store.notifications, isEmpty, reason: 'notifications');
    });

    test('starts every balance at zero', () {
      for (final material in store.rawMaterials) {
        expect(material['quantity'], 0,
            reason: '${material['name']} should hold nothing yet');
      }
      for (final product in store.products) {
        expect(product['quantity_bundles'], 0, reason: '${product['sku']} bundles');
        expect(product['quantity_bags'], 0, reason: '${product['sku']} bags');
      }
      expect(store.recycled.single['quantity'], 0);
    });

    test('but the packaging rules survive, so entry still works', () {
      // Clearing stock must not clear how a product is packed — that is the
      // mapping production and dispatch validate against.
      final bagged = store.products.where((p) => p['pipes_per_bag'] != null);
      expect(bagged, isNotEmpty);
      expect(store.products.every((p) => (p['bundle_weight_kg'] as num) > 0),
          isTrue, reason: 'every product still has a bundle weight');
    });
  });

  testWidgets('the app signs in and opens an empty dashboard', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(demoScope(child: const DiamondPolymersApp()));
    await tester.pumpAndSettle();

    await tester.enterText(
        find.widgetWithText(TextFormField, 'Email'), 'admin@diamond.local');
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Password'), 'anything');
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pumpAndSettle();

    // Signed in, on the dashboard, with nothing produced and nothing to alert.
    expect(find.text('Dashboard'), findsWidgets);
    expect(find.text('Diamond Polymers'), findsWidgets);
    expect(find.textContaining('Ravi'), findsNothing,
        reason: 'no invented operators anywhere');
  });

  test('sample data is still available for demonstrations', () {
    final demo = DemoStore(withSampleData: true);
    expect(demo.staff.length, greaterThan(1));
    expect(demo.productionEntries, isNotEmpty);
  });
}
