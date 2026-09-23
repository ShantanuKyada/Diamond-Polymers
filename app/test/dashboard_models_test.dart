import 'package:diamond_polymers/features/dashboard/domain/dashboard_models.dart';
import 'package:flutter_test/flutter_test.dart';

/// Parsing of the `admin_dashboard()` / `operator_dashboard()` payloads.
///
/// The fixtures below mirror the exact jsonb shape those functions build in
/// 0004_rpc.sql, including Postgres numeric values arriving as strings.
void main() {
  group('AdminDashboard', () {
    final payload = <String, dynamic>{
      'date': '2026-09-04',
      'production': {
        'total_bundles': 213,
        'total_wastage': '8.52',
        'entry_count': 8,
      },
      'production_by_machine': [
        {'machine_id': 'm1', 'machine_name': 'Machine 1', 'bundles': 120},
        {'machine_id': 'm2', 'machine_name': 'Machine 2', 'bundles': 93},
      ],
      'production_by_type': [
        {'pipe_type_id': 't1', 'pipe_type_name': 'Type A', 'bundles': 130},
      ],
      'production_by_size': [
        {'pipe_size_id': 's1', 'pipe_size_name': 'Size 1', 'bundles': 60},
      ],
      'raw_materials': [
        {
          'raw_material_id': 'r1',
          'name': 'Raizin',
          'category_name': 'Raizin',
          'unit': 'kg',
          'quantity': '1250.500',
          'minimum_stock': '200.000',
          'status': 'GOOD',
        },
        {
          'raw_material_id': 'r2',
          'name': 'Chemical',
          'category_name': 'Chemical',
          'unit': 'kg',
          'quantity': '45.000',
          'minimum_stock': '50.000',
          'status': 'LOW',
        },
      ],
      'raw_consumption_today': [
        {'name': 'Raizin', 'unit': 'kg', 'consumed': '106.000'},
      ],
      'finished_goods': [
        {
          'pipe_type_id': 't1',
          'pipe_type_name': 'Type A',
          'pipe_size_id': 's2',
          'pipe_size_name': 'Size 2',
          'quantity_bundles': 8,
          'minimum_stock': 15,
          'status': 'LOW',
        },
      ],
      'finished_goods_total': 452,
      'dispatch_today': {'total_bundles': 50, 'dispatch_count': 2},
      'wastage_today': {
        'raw_wastage': '3.000',
        'production_scrap': '12.500',
        'reusable': '12.500',
      },
      'reusable_wastage': [],
      'machines': [
        {
          'machine_id': 'm1',
          'code': 'M1',
          'name': 'Machine 1',
          'status': 'ACTIVE',
          'operators': ['Ravi Kumar'],
          'bundles_today': 120,
        },
      ],
      'unread_notifications': 3,
    };

    test('parses headline figures, including numerics sent as strings', () {
      final dashboard = AdminDashboard.from(payload);

      expect(dashboard.bundlesToday, 213);
      expect(dashboard.wastageToday, 8.52);
      expect(dashboard.entryCount, 8);
      expect(dashboard.finishedGoodsTotal, 452);
      expect(dashboard.dispatchBundlesToday, 50);
      expect(dashboard.unreadNotifications, 3);
      expect(dashboard.date, DateTime(2026, 9, 4));
    });

    test('parses breakdowns and machine summaries', () {
      final dashboard = AdminDashboard.from(payload);

      expect(dashboard.productionByMachine, hasLength(2));
      expect(dashboard.productionByMachine.first.name, 'Machine 1');
      expect(dashboard.productionByMachine.first.value, 120);
      expect(dashboard.machines.single.operators, ['Ravi Kumar']);
    });

    test('surfaces one alert per item below its threshold (§27)', () {
      final dashboard = AdminDashboard.from(payload);

      // Chemical is LOW and Type A Size 2 is LOW; Raizin is GOOD.
      expect(dashboard.alerts, hasLength(2));
      expect(dashboard.alerts.first, contains('Chemical'));
      expect(dashboard.alerts.first, contains('low'));
      expect(dashboard.alerts.last, contains('Type A · Size 2'));
    });

    test('an empty factory parses without throwing', () {
      final dashboard = AdminDashboard.from({'date': '2026-09-04'});

      expect(dashboard.bundlesToday, 0);
      expect(dashboard.rawMaterials, isEmpty);
      expect(dashboard.machines, isEmpty);
      expect(dashboard.alerts, isEmpty);
    });
  });

  group('OperatorDashboard', () {
    test('parses the assignment when a machine is assigned', () {
      final dashboard = OperatorDashboard.from({
        'date': '2026-09-04',
        'assignment': {
          'machine_id': 'm1',
          'machine_name': 'Machine 1',
          'machine_code': 'M1',
          'machine_status': 'ACTIVE',
          'shift_id': 'sh1',
          'shift_name': 'Morning',
          'start_time': '06:00:00',
          'end_time': '14:00:00',
        },
        'production_today': {
          'total_bundles': 42,
          'total_wastage': '1.68',
          'entry_count': 2,
        },
        'consumption_today': [
          {'name': 'Raizin', 'unit': 'kg', 'consumed': '26.000'},
        ],
        'recent_production': [
          {
            'id': 'p1',
            'pipe_type_name': 'Type A',
            'pipe_size_name': 'Size 3',
            'bundle_quantity': 22,
            'shift_name': 'Morning',
            'created_at': '2026-09-04T08:15:00Z',
          },
        ],
      });

      expect(dashboard.assignment, isNotNull);
      expect(dashboard.assignment!.machineName, 'Machine 1');
      expect(dashboard.assignment!.shiftName, 'Morning');
      expect(dashboard.bundlesToday, 42);
      expect(dashboard.consumptionToday.single.consumed, 26.0);
      expect(dashboard.recentProduction.single.bundles, 22);
    });

    test('a null assignment is preserved rather than faked (§19)', () {
      final dashboard = OperatorDashboard.from({
        'date': '2026-09-04',
        'assignment': null,
        'production_today': {'total_bundles': 0, 'entry_count': 0},
      });

      // The home screen keys off this to tell the operator that no machine is
      // assigned, instead of rendering an empty machine card.
      expect(dashboard.assignment, isNull);
      expect(dashboard.bundlesToday, 0);
      expect(dashboard.recentProduction, isEmpty);
    });
  });
}
