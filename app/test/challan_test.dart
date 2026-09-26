import 'package:diamond_polymers/features/dispatch/data/dispatch_repository.dart';
import 'package:diamond_polymers/features/dispatch/presentation/challan_document.dart';
import 'package:flutter_test/flutter_test.dart';

/// The delivery challan that travels with the goods.
///
/// The PDF's appearance is not worth asserting — it changes whenever anyone
/// adjusts a margin. What is worth pinning is the arithmetic and the document
/// number, because those are what a buyer or an auditor would dispute.
void main() {
  Dispatch dispatchWith(List<DispatchLine> lines, {String? vehicle = 'MH-12-AB-4471'}) {
    return Dispatch(
      id: 'a1b2c3d4-0000-4000-8000-000000000000',
      date: DateTime(2026, 9, 26),
      customerName: 'Shree Traders',
      lines: lines,
      createdAt: DateTime(2026, 9, 26, 10),
      reference: 'PO-4471',
      vehicleNumber: vehicle,
      remarks: 'Handle with care',
    );
  }

  DispatchLine line(String type, String size, int bundles, int bags) =>
      DispatchLine(
        pipeTypeId: 't-$type',
        pipeSizeId: 'z-$size',
        pipeTypeName: type,
        pipeSizeName: size,
        bundleQuantity: bundles,
        bagQuantity: bags,
      );

  ChallanData challan(Dispatch d, {String prefix = 'DC', String? address}) =>
      ChallanData(
        dispatch: d,
        factoryName: 'Diamond Polymers',
        factoryAddress: address,
        prefix: prefix,
      );

  group('document number', () {
    test('is derived from the dispatch, so it always leads back to one record',
        () {
      final data = challan(dispatchWith([line('Type A', 'Size 1', 10, 0)]));
      expect(data.number, 'DC-20260926-A1B2');
    });

    test('is stable — the same dispatch always produces the same number', () {
      final d = dispatchWith([line('Type A', 'Size 1', 10, 0)]);
      expect(challan(d).number, challan(d).number);
    });

    test('honours the configured prefix', () {
      final data = challan(
        dispatchWith([line('Type A', 'Size 1', 1, 0)]),
        prefix: 'CH',
      );
      expect(data.number, startsWith('CH-'));
    });
  });

  group('totals', () {
    test('adds bundles and bags across every line', () {
      final data = challan(dispatchWith([
        line('Type A', 'Size 1', 10, 4),
        line('Type B', 'Size 3', 5, 2),
      ]));

      expect(data.totalBundles, 15);
      expect(data.totalBags, 6);
      expect(data.hasBags, isTrue);
    });

    test('a consignment with no bags does not claim a bag column', () {
      // An always-zero column makes a document look like it is missing
      // something, so the table drops it entirely.
      final data = challan(dispatchWith([
        line('Type A', 'Size 1', 10, 0),
        line('Type B', 'Size 3', 5, 0),
      ]));

      expect(data.hasBags, isFalse);
      expect(data.totalBags, 0);
      expect(data.totalBundles, 15);
    });
  });

  group('the PDF itself', () {
    test('is produced, and is a PDF', () async {
      final bytes = await buildChallanPdf(
        challan(dispatchWith([line('Type A', 'Size 1', 10, 4)]),
            address: '12 Industrial Estate\nRajkot'),
      );

      expect(bytes.length, greaterThan(1000));
      // %PDF- magic number.
      expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    });

    test('a missing vehicle or address does not stop it being produced',
        () async {
      // The lorry is waiting. A challan with a gap beats no challan, and the
      // gap is visible on the page rather than swallowed.
      final bytes = await buildChallanPdf(
        challan(dispatchWith([line('Type A', 'Size 1', 1, 0)], vehicle: null)),
      );
      expect(bytes.length, greaterThan(1000));
    });

    test('many lines still produce one document', () async {
      final bytes = await buildChallanPdf(
        challan(dispatchWith([
          for (var i = 0; i < 25; i++) line('Type A', 'Size $i', i + 1, i),
        ])),
      );
      expect(bytes.length, greaterThan(1000));
    });
  });
}
