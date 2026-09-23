import 'package:diamond_polymers/app.dart';
import 'package:diamond_polymers/core/demo/demo_overrides.dart';
import 'package:diamond_polymers/core/demo/demo_store.dart';
import 'package:diamond_polymers/core/theme/app_theme.dart';
import 'package:diamond_polymers/features/dispatch/presentation/dispatch_screen.dart';
import 'package:diamond_polymers/features/production/presentation/production_history_screens.dart';
import 'package:diamond_polymers/features/reports/presentation/reports_screen.dart';
import 'package:diamond_polymers/features/staff/presentation/staff_screens.dart';
import 'package:diamond_polymers/features/wastage/presentation/wastage_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Every screen that used to be a placeholder, rendered against demo data.
///
/// The point of these is narrow and worth stating: prove that none of them is
/// an empty shell. Each assertion names something that can only appear if the
/// screen actually loaded data and laid it out.
void main() {
  // Demo reads are deliberately slow so the UI shows its loading states.
  // In a widget test that only produces pending timers.
  setUp(() => DemoStore.latency = Duration.zero);
  tearDown(() => DemoStore.latency = const Duration(milliseconds: 320));

  Future<void> show(WidgetTester tester, Widget screen) async {
    tester.view.physicalSize = const Size(1100, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      demoScope(
        child: MaterialApp(theme: AppTheme.light(), home: screen),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('Production records lists entries grouped by day', (tester) async {
    await show(tester, const ProductionRecordsScreen());

    expect(find.text('Production'), findsWidgets);
    expect(find.textContaining('Today'), findsWidgets);
    // A seeded product and the machine that made it.
    expect(find.textContaining('Type A'), findsWidgets);
    expect(find.text('Machine 1 · Morning · Ravi Kumar'), findsWidgets);
  });

  testWidgets('My Entries shows the operator their own work', (tester) async {
    // Driven through a real sign-in, because the screen is scoped to whoever
    // is signed in — rendered on its own it would correctly show nothing.
    tester.view.physicalSize = const Size(1100, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

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

    await tester.tap(find.text('My Entries').last);
    await tester.pumpAndSettle();

    expect(find.textContaining('Type A'), findsWidgets);
  });

  testWidgets('Dispatch lists consignments with their lines', (tester) async {
    await show(tester, const DispatchScreen());

    expect(find.text('Shree Traders'), findsOneWidget);
    expect(find.text('Patel Agro Supply'), findsOneWidget);
    expect(find.text('Bundles today'), findsOneWidget);
    expect(find.text('Bags today'), findsOneWidget);
    // The change request's own example: both packagings on one dispatch.
    expect(find.text('ABC Industries'), findsOneWidget);
    expect(find.text('GJXX1234'), findsOneWidget);
    expect(find.text('20 bundles · 10 bags'), findsOneWidget);
    expect(find.widgetWithText(FloatingActionButton, 'New dispatch'),
        findsOneWidget);
  });

  testWidgets('New dispatch shows available stock per product', (tester) async {
    await show(tester, const NewDispatchScreen());

    expect(find.text('Buyer name'), findsOneWidget);
    expect(find.text('Vehicle number'), findsOneWidget);
    // Both balances beside each product, so a short line is obvious first.
    expect(find.textContaining('in stock'), findsWidgets);
    expect(find.text('Bundles'), findsWidgets);
    expect(find.text('Bags'), findsWidgets);
    // The largest size is not packed in bags, and says so.
    expect(find.text('Not packed in bags'), findsWidgets);
  });

  testWidgets('Wastage separates loss from recoverable scrap', (tester) async {
    await show(tester, const WastageScreen());

    expect(find.text('Lost today'), findsOneWidget);
    expect(find.text('Recoverable today'), findsOneWidget);
    expect(find.text('Material loss'), findsWidgets);
    expect(find.text('Production scrap'), findsWidgets);
  });

  testWidgets('Recording wastage explains what each source does',
      (tester) async {
    await show(tester, const RecordWastageScreen());

    // The distinction decides whether raw stock moves, so it is spelled out.
    expect(
      find.textContaining('Already counted out of raw stock'),
      findsOneWidget,
    );
    expect(find.text('Collected for reuse'), findsOneWidget);
  });

  testWidgets('Reports summarise production, dispatch, wastage and stock',
      (tester) async {
    await show(tester, const ReportsScreen());

    expect(find.textContaining('Production ·'), findsOneWidget);
    expect(find.text('By machine'), findsOneWidget);
    expect(find.text('By operator'), findsOneWidget);
    expect(find.text('Dispatch'), findsWidgets);
    expect(find.text('Closing stock'), findsOneWidget);
  });

  testWidgets('Punches shows who is on site and the month behind it',
      (tester) async {
    await show(tester, const PunchesScreen());

    expect(find.text('On site now'), findsOneWidget);
    expect(find.text('Marked present'), findsOneWidget);
    expect(find.text('Ravi Kumar'), findsWidgets);

    await tester.tap(find.text('This month'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Present'), findsWidgets);
  });

  testWidgets('Salary shows payslips and outstanding advances', (tester) async {
    await show(tester, const SalaryScreen());

    expect(find.text('Net payable'), findsWidgets);
    expect(find.text('Ravi Kumar'), findsWidgets);

    await tester.tap(find.text('Advances'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Outstanding across'), findsOneWidget);
  });
}
