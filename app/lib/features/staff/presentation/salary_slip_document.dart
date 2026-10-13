import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../../core/utils/formatters.dart';
import '../data/staff_repository.dart';

/// The salary slip a worker is handed, or sent, for one month (A39).
///
/// It has to answer the question a worker actually asks — "why is this the
/// amount?" — so it does not print a single net figure and stop. It shows the
/// monthly salary, every advance they took with its date, anything deducted,
/// every payment made with its date, and what is left. Somebody who took 2,000
/// mid-month can see exactly that, on the day they were paid the rest.
///
/// A reversal prints as its own line rather than being netted off. A slip that
/// quietly tidied away a payment made in error would be the one document the
/// worker had no way to argue with.
class SalarySlipData {
  const SalarySlipData({
    required this.payslip,
    required this.advances,
    required this.payments,
    required this.factoryName,
    required this.currencySymbol,
    this.factoryAddress,
    this.factoryPhone,
    this.factoryGstin,
    this.footer,
  });

  final Payslip payslip;
  final List<AdvanceTaken> advances;
  final List<SalaryPayment> payments;
  final String factoryName;
  final String currencySymbol;
  final String? factoryAddress;
  final String? factoryPhone;
  final String? factoryGstin;
  final String? footer;

  /// Derived from the payslip, not a counter — the same decision the delivery
  /// challan took, and for the same reason: a sequential series needs rules
  /// about resets and gaps that nobody has set, while a derived number always
  /// leads back to exactly one record.
  String get number {
    final month = Fmt.isoDate(payslip.periodMonth).substring(0, 7)
        .replaceAll('-', '');
    final tail = payslip.id.replaceAll('-', '');
    return 'SAL-$month-${payslip.employeeCode}'
        '-${tail.substring(0, tail.length < 4 ? tail.length : 4).toUpperCase()}';
  }

  String money(double value) => Fmt.pdfMoney(value, symbol: currencySymbol);

  /// Any text on its way onto the page, made drawable.
  ///
  /// Everything here is either typed by the factory — a name, an address, a
  /// note — or a label of ours, and the standard PDF font has no glyph for a
  /// rupee sign, an em dash or anything outside ASCII. The library drops what
  /// it cannot draw and only warns on the console, so this is the one place
  /// that decides what a worker actually sees. See [Fmt.pdfSafe].
  String text(String? value, {String fallback = '-'}) {
    final clean = Fmt.pdfSafe((value ?? '').trim()).trim();
    return clean.isEmpty ? fallback : clean;
  }

  bool get hasDeductions => payslip.deductionsAmount > 0;
  bool get hasAdvances => advances.isNotEmpty || payslip.advanceRecovered > 0;
}

Future<List<int>> buildSalarySlipPdf(SalarySlipData data) async {
  final doc = pw.Document(
    title: 'Salary slip ${data.number}',
    author: data.text(data.factoryName),
  );

  doc.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.fromLTRB(32, 32, 32, 28),
      build: (context) => [
        _header(data),
        pw.SizedBox(height: 18),
        _worker(data),
        pw.SizedBox(height: 16),
        _summary(data),
        if (data.hasAdvances) ...[
          pw.SizedBox(height: 16),
          _advanceTable(data),
        ],
        if (data.payments.isNotEmpty) ...[
          pw.SizedBox(height: 16),
          _paymentTable(data),
        ],
        pw.SizedBox(height: 18),
        _standing(data),
        pw.SizedBox(height: 24),
        _signatures(data),
      ],
      footer: (context) => _footer(data, context),
    ),
  );

  return doc.save();
}

pw.Widget _header(SalarySlipData data) {
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
                pw.Text(data.text(data.factoryName),
                  style: pw.TextStyle(
                      fontSize: 18, fontWeight: pw.FontWeight.bold),
                ),
                if ((data.factoryAddress ?? '').trim().isNotEmpty)
                  pw.Text(data.text(data.factoryAddress),
                      style: const pw.TextStyle(fontSize: 9)),
                if ((data.factoryPhone ?? '').trim().isNotEmpty)
                  pw.Text('Phone: ${data.text(data.factoryPhone)}',
                      style: const pw.TextStyle(fontSize: 9)),
                // Omitted entirely rather than printed empty — an unregistered
                // factory should not have a blank GSTIN on its paperwork.
                if ((data.factoryGstin ?? '').trim().isNotEmpty)
                  pw.Text('GSTIN: ${data.text(data.factoryGstin)}',
                      style: const pw.TextStyle(fontSize: 9)),
              ],
            ),
          ),
          pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.end,
            children: [
              pw.Text('SALARY SLIP',
                  style: pw.TextStyle(
                      fontSize: 13, fontWeight: pw.FontWeight.bold)),
              pw.SizedBox(height: 4),
              pw.Text(Fmt.monthYear(data.payslip.periodMonth),
                  style: pw.TextStyle(
                      fontSize: 12, fontWeight: pw.FontWeight.bold)),
              pw.Text(data.text(data.number), style: const pw.TextStyle(fontSize: 8)),
            ],
          ),
        ],
      ),
      pw.SizedBox(height: 10),
      pw.Divider(thickness: 1.2, height: 1),
    ],
  );
}

pw.Widget _worker(SalarySlipData data) {
  final p = data.payslip;
  return pw.Row(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      pw.Expanded(
        flex: 3,
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text('Worker',
                style: pw.TextStyle(
                    fontSize: 8,
                    color: PdfColors.grey700,
                    fontWeight: pw.FontWeight.bold)),
            pw.SizedBox(height: 2),
            pw.Text(data.text(p.staffName),
                style: pw.TextStyle(
                    fontSize: 13, fontWeight: pw.FontWeight.bold)),
            pw.Text(data.text(p.employeeCode), style: const pw.TextStyle(fontSize: 9)),
          ],
        ),
      ),
      pw.Expanded(flex: 2, child: _field('Phone', p.phone)),
      pw.Expanded(
        flex: 2,
        child: _field('Joined', p.joinedOn == null ? null : Fmt.date(p.joinedOn!)),
      ),
      pw.Expanded(
        flex: 2,
        child: _field('Salary day',
            p.salaryDueOn == null ? null : Fmt.date(p.salaryDueOn!)),
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
      pw.Text(Fmt.pdfSafe((value ?? '').trim()).trim().isEmpty ? '-' : Fmt.pdfSafe(value!.trim()),
          style: const pw.TextStyle(fontSize: 10)),
    ],
  );
}

/// The arithmetic, in the order the factory says it: salary, less what was
/// taken, less anything deducted, equals what is payable.
pw.Widget _summary(SalarySlipData data) {
  final p = data.payslip;

  return pw.Container(
    decoration: pw.BoxDecoration(
      border: pw.Border.all(color: PdfColors.grey400, width: 0.6),
    ),
    child: pw.Column(
      children: [
        _row('Monthly salary', data.money(p.monthlySalary), bold: true),
        if (p.advanceRecovered > 0)
          _row('Less advance taken during the month',
              '- ${data.money(p.advanceRecovered)}'),
        if (data.hasDeductions)
          _row('Less deductions', '- ${data.money(p.deductionsAmount)}'),
        _row('Net payable', data.money(p.netPayable),
            bold: true, shaded: true),
      ],
    ),
  );
}

/// What is left, and whether the month is closed. Printed apart from the
/// arithmetic because it is the line the worker checks first.
pw.Widget _standing(SalarySlipData data) {
  final p = data.payslip;

  return pw.Container(
    decoration: pw.BoxDecoration(
      border: pw.Border.all(color: PdfColors.grey400, width: 0.6),
    ),
    child: pw.Column(
      children: [
        _row('Paid', data.money(p.paidAmount)),
        _row('Outstanding', data.money(p.outstanding),
            bold: true, shaded: true),
        _row('Status', Fmt.pdfSafe(p.status.label)),
      ],
    ),
  );
}

pw.Widget _row(String label, String value,
    {bool bold = false, bool shaded = false}) {
  return pw.Container(
    decoration: shaded
        ? const pw.BoxDecoration(color: PdfColors.grey200)
        : const pw.BoxDecoration(),
    padding: const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    child: pw.Row(
      children: [
        pw.Expanded(
          child: pw.Text(Fmt.pdfSafe(label),
              style: pw.TextStyle(
                  fontSize: 10,
                  fontWeight:
                      bold ? pw.FontWeight.bold : pw.FontWeight.normal)),
        ),
        pw.Text(Fmt.pdfSafe(value),
            style: pw.TextStyle(
                fontSize: bold ? 12 : 10,
                fontWeight:
                    bold ? pw.FontWeight.bold : pw.FontWeight.normal)),
      ],
    ),
  );
}

pw.Widget _advanceTable(SalarySlipData data) {
  return _table(
    'Advances taken this month',
    ['Date', 'Note', 'Amount'],
    [
      for (final a in data.advances)
        [
          Fmt.date(a.entryDate),
          a.remarks ?? '',
          data.money(a.amount),
        ],
      // The payslip recovers whatever was outstanding, which can include an
      // advance taken in an earlier month. Saying so is better than printing a
      // list that does not add up to the figure above it.
      if (data.advances.fold<double>(0, (s, a) => s + a.amount) !=
          data.payslip.advanceRecovered)
        [
          '',
          'Recovered on this payslip, including any brought forward',
          data.money(data.payslip.advanceRecovered),
        ],
    ],
    flexes: const [3, 7, 3],
  );
}

pw.Widget _paymentTable(SalarySlipData data) {
  return _table(
    'Payments',
    ['Date', 'Method', 'Note', 'Amount'],
    [
      for (final p in data.payments)
        [
          Fmt.date(p.paidOn),
          p.method ?? '',
          p.isReversal
              ? 'Reversed'
              : (p.remarks ?? ''),
          data.money(p.amount),
        ],
    ],
    flexes: const [3, 3, 6, 3],
  );
}

pw.Widget _table(
  String caption,
  List<String> headings,
  List<List<String>> rows, {
  required List<int> flexes,
}) {
  // Every cell of every table passes through here, so a note somebody typed
  // cannot reach the page carrying a character the font will silently drop.
  pw.Widget cell(String text, {required bool numeric, bool bold = false}) {
    final safe = Fmt.pdfSafe(text).trim();
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 5),
      child: pw.Text(safe.isEmpty ? '-' : safe,
        textAlign: numeric ? pw.TextAlign.right : pw.TextAlign.left,
        style: pw.TextStyle(
            fontSize: bold ? 9 : 10,
            fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal),
      ),
    );
  }

  final widths = <int, pw.TableColumnWidth>{
    for (var i = 0; i < flexes.length; i++)
      i: pw.FlexColumnWidth(flexes[i].toDouble()),
  };

  return pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.stretch,
    children: [
      pw.Text(Fmt.pdfSafe(caption),
          style: pw.TextStyle(
              fontSize: 9,
              color: PdfColors.grey700,
              fontWeight: pw.FontWeight.bold)),
      pw.SizedBox(height: 4),
      pw.Table(
        border: pw.TableBorder.all(color: PdfColors.grey400, width: 0.6),
        columnWidths: widths,
        children: [
          pw.TableRow(
            decoration: const pw.BoxDecoration(color: PdfColors.grey200),
            children: [
              for (var i = 0; i < headings.length; i++)
                cell(headings[i],
                    numeric: i == headings.length - 1, bold: true),
            ],
          ),
          for (final row in rows)
            pw.TableRow(
              children: [
                for (var i = 0; i < row.length; i++)
                  cell(row[i], numeric: i == row.length - 1),
              ],
            ),
        ],
      ),
    ],
  );
}

pw.Widget _signatures(SalarySlipData data) {
  pw.Widget line(String label) => pw.Expanded(
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.SizedBox(height: 26),
            pw.Container(
              height: 0.8,
              color: PdfColors.grey600,
              margin: const pw.EdgeInsets.only(right: 24),
            ),
            pw.SizedBox(height: 3),
            pw.Text(Fmt.pdfSafe(label),
                style:
                    const pw.TextStyle(fontSize: 8, color: PdfColors.grey700)),
          ],
        ),
      );

  return pw.Row(children: [line('Worker'), line(data.text('For ${data.factoryName}'))]);
}

pw.Widget _footer(SalarySlipData data, pw.Context context) {
  return pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.stretch,
    children: [
      pw.Divider(thickness: 0.6, height: 10),
      pw.Row(
        children: [
          pw.Expanded(
            child: pw.Text((data.footer ?? '').trim().isEmpty
                  ? 'Computer generated salary slip.'
                  : data.text(data.footer),
              style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey700),
            ),
          ),
          pw.Text('Page ${context.pageNumber} of ${context.pagesCount}',
              style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey700)),
        ],
      ),
    ],
  );
}
