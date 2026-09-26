import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../../core/utils/formatters.dart';
import '../data/dispatch_repository.dart';

/// The delivery challan that travels with the goods.
///
/// A challan, not a tax invoice: it states what left the factory, for whom, on
/// which vehicle. It carries no money, because the database holds no prices —
/// accounts raise the invoice separately, which is how most factories already
/// work.
///
/// **It is built so prices can be added later without redrawing it.** The line
/// table is assembled from [_Column] descriptors, so a rate and an amount become
/// two more entries in that list plus a totals block; nothing about the header,
/// the layout or the sharing path changes. That was the explicit brief — challan
/// now, prices later — and designing for it cost nothing today.
class ChallanData {
  const ChallanData({
    required this.dispatch,
    required this.factoryName,
    this.factoryAddress,
    this.factoryPhone,
    this.factoryGstin,
    this.prefix = 'DC',
    this.footer,
  });

  final Dispatch dispatch;
  final String factoryName;
  final String? factoryAddress;
  final String? factoryPhone;
  final String? factoryGstin;
  final String prefix;
  final String? footer;

  /// A stable, human-readable document number derived from the dispatch itself.
  ///
  /// Deliberately **not** a counter. A statutory sequential series needs
  /// decisions this project has not taken — when it resets, what happens to a
  /// cancelled number, who owns the gap — and those belong with the invoice
  /// work. Deriving it means the number on the paper always leads back to
  /// exactly one record, which is what makes a challan useful in a dispute.
  String get number {
    final date = Fmt.isoDate(dispatch.date).replaceAll('-', '');
    final tail = dispatch.id.replaceAll('-', '').substring(0, 4).toUpperCase();
    return '$prefix-$date-$tail';
  }

  bool get hasBags => dispatch.lines.any((l) => l.bagQuantity > 0);

  // Totals come from Dispatch, which already computes them for the on-screen
  // card. A second copy here would be one edit away from a challan that
  // disagrees with the screen it was printed from.
  int get totalBundles => dispatch.totalBundles;
  int get totalBags => dispatch.totalBags;
}

/// One column of the line table. Adding a rate later means adding to this list.
class _Column {
  const _Column(this.heading, this.value, {this.flex = 1, this.numeric = false});

  final String heading;
  final String Function(DispatchLine line) value;
  final int flex;
  final bool numeric;
}

Future<List<int>> buildChallanPdf(ChallanData data) async {
  final doc = pw.Document(
    title: 'Delivery Challan ${data.number}',
    author: data.factoryName,
  );

  final columns = <_Column>[
    _Column('#', (l) => '', flex: 0),
    _Column('Product', (l) => '${l.pipeTypeName} — ${l.pipeSizeName}', flex: 5),
    _Column('Bundles', (l) => Fmt.count(l.bundleQuantity),
        flex: 2, numeric: true),
    // Bags only appear when some line has them: an always-zero column makes a
    // document look like it is missing something.
    if (data.hasBags)
      _Column('Bags', (l) => Fmt.count(l.bagQuantity), flex: 2, numeric: true),
  ];

  doc.addPage(
    pw.Page(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.fromLTRB(32, 32, 32, 28),
      build: (context) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.stretch,
        children: [
          _header(data),
          pw.SizedBox(height: 18),
          _parties(data),
          pw.SizedBox(height: 16),
          _lineTable(data, columns),
          pw.SizedBox(height: 14),
          _totals(data),
          pw.Spacer(),
          _footer(data),
        ],
      ),
    ),
  );

  return doc.save();
}

pw.Widget _header(ChallanData data) {
  return pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.stretch,
    children: [
      pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Expanded(
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text(
                  data.factoryName,
                  style: pw.TextStyle(
                      fontSize: 18, fontWeight: pw.FontWeight.bold),
                ),
                if ((data.factoryAddress ?? '').trim().isNotEmpty)
                  pw.Text(data.factoryAddress!.trim(),
                      style: const pw.TextStyle(fontSize: 9)),
                if ((data.factoryPhone ?? '').trim().isNotEmpty)
                  pw.Text('Phone: ${data.factoryPhone!.trim()}',
                      style: const pw.TextStyle(fontSize: 9)),
                // Omitted entirely rather than printed empty — an unregistered
                // factory should not have a blank GSTIN line on its paperwork.
                if ((data.factoryGstin ?? '').trim().isNotEmpty)
                  pw.Text('GSTIN: ${data.factoryGstin!.trim()}',
                      style: const pw.TextStyle(fontSize: 9)),
              ],
            ),
          ),
          pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.end,
            children: [
              pw.Text('DELIVERY CHALLAN',
                  style: pw.TextStyle(
                      fontSize: 13, fontWeight: pw.FontWeight.bold)),
              pw.SizedBox(height: 4),
              pw.Text(data.number,
                  style: const pw.TextStyle(fontSize: 11)),
              pw.Text(Fmt.date(data.dispatch.date),
                  style: const pw.TextStyle(fontSize: 9)),
            ],
          ),
        ],
      ),
      pw.SizedBox(height: 10),
      pw.Divider(thickness: 1.2, height: 1),
      // Says plainly what this document is not, so nobody files it as one.
      pw.SizedBox(height: 4),
      pw.Text('Not a tax invoice. Issued for delivery of goods only.',
          style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey700)),
    ],
  );
}

pw.Widget _parties(ChallanData data) {
  final d = data.dispatch;
  return pw.Row(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      pw.Expanded(
        flex: 3,
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text('Consignee',
                style: pw.TextStyle(
                    fontSize: 8,
                    color: PdfColors.grey700,
                    fontWeight: pw.FontWeight.bold)),
            pw.SizedBox(height: 2),
            pw.Text(d.customerName,
                style: pw.TextStyle(
                    fontSize: 12, fontWeight: pw.FontWeight.bold)),
          ],
        ),
      ),
      pw.Expanded(
        flex: 2,
        child: _field('Vehicle', d.vehicleNumber),
      ),
      pw.Expanded(
        flex: 2,
        child: _field('Reference', d.reference),
      ),
    ],
  );
}

pw.Widget _field(String label, String? value) {
  return pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      pw.Text(label,
          style: pw.TextStyle(
              fontSize: 8,
              color: PdfColors.grey700,
              fontWeight: pw.FontWeight.bold)),
      pw.SizedBox(height: 2),
      pw.Text((value ?? '').trim().isEmpty ? '—' : value!.trim(),
          style: const pw.TextStyle(fontSize: 11)),
    ],
  );
}

pw.Widget _lineTable(ChallanData data, List<_Column> columns) {
  pw.Widget cell(String text,
      {required bool numeric, bool bold = false, double size = 10}) {
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 5),
      child: pw.Text(
        text,
        textAlign: numeric ? pw.TextAlign.right : pw.TextAlign.left,
        style: pw.TextStyle(
            fontSize: size,
            fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal),
      ),
    );
  }

  final widths = <int, pw.TableColumnWidth>{};
  for (var i = 0; i < columns.length; i++) {
    widths[i] = columns[i].flex == 0
        ? const pw.FixedColumnWidth(26)
        : pw.FlexColumnWidth(columns[i].flex.toDouble());
  }

  return pw.Table(
    border: pw.TableBorder.all(color: PdfColors.grey400, width: 0.6),
    columnWidths: widths,
    children: [
      pw.TableRow(
        decoration: const pw.BoxDecoration(color: PdfColors.grey200),
        children: [
          for (final c in columns)
            cell(c.heading, numeric: c.numeric, bold: true, size: 9),
        ],
      ),
      for (var i = 0; i < data.dispatch.lines.length; i++)
        pw.TableRow(
          children: [
            for (var j = 0; j < columns.length; j++)
              cell(
                j == 0 ? '${i + 1}' : columns[j].value(data.dispatch.lines[i]),
                numeric: columns[j].numeric,
              ),
          ],
        ),
    ],
  );
}

pw.Widget _totals(ChallanData data) {
  return pw.Row(
    mainAxisAlignment: pw.MainAxisAlignment.end,
    children: [
      pw.Container(
        padding: const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: pw.BoxDecoration(
          border: pw.Border.all(color: PdfColors.grey500, width: 0.8),
        ),
        child: pw.Row(
          children: [
            pw.Text('Total  ',
                style: pw.TextStyle(
                    fontSize: 10, fontWeight: pw.FontWeight.bold)),
            pw.Text('${Fmt.count(data.totalBundles)} bundles',
                style: const pw.TextStyle(fontSize: 10)),
            if (data.hasBags)
              pw.Text('   ·   ${Fmt.count(data.totalBags)} bags',
                  style: const pw.TextStyle(fontSize: 10)),
          ],
        ),
      ),
    ],
  );
}

pw.Widget _footer(ChallanData data) {
  final remarks = (data.dispatch.remarks ?? '').trim();
  final note = (data.footer ?? '').trim();

  return pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.stretch,
    children: [
      if (remarks.isNotEmpty) ...[
        pw.Text('Remarks',
            style: pw.TextStyle(
                fontSize: 8,
                color: PdfColors.grey700,
                fontWeight: pw.FontWeight.bold)),
        pw.Text(remarks, style: const pw.TextStyle(fontSize: 9)),
        pw.SizedBox(height: 14),
      ],
      if (note.isNotEmpty) ...[
        pw.Text(note,
            style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey700)),
        pw.SizedBox(height: 14),
      ],
      pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          _signature('Receiver\'s signature'),
          _signature('For ${data.factoryName}'),
        ],
      ),
    ],
  );
}

pw.Widget _signature(String label) {
  return pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      pw.SizedBox(height: 28),
      pw.Container(width: 170, height: 0.8, color: PdfColors.grey600),
      pw.SizedBox(height: 3),
      pw.Text(label, style: const pw.TextStyle(fontSize: 8)),
    ],
  );
}
