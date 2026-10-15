import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:printing/printing.dart';

import '../../../core/error/app_exception.dart';
import '../../../core/utils/formatters.dart';
import '../../masters/data/settings_values.dart';
import '../data/staff_repository.dart';
import '../../../core/widgets/responsive.dart';
import 'salary_slip_document.dart';

/// Gathers everything one salary slip needs and hands it to the phone.
///
/// The advances and payments are fetched when the slip is asked for rather than
/// held on the payslip list: a slip is produced for one worker at a time, and
/// loading every worker's transaction history to render a list of cards would
/// be a lot of work for a screen that shows none of it.
Future<SalarySlipData?> _gather(
  BuildContext context,
  WidgetRef ref,
  Payslip payslip,
) async {
  final settings = ref.read(settingsMapProvider);
  String? value(String key) {
    final v = settings[key]?.trim();
    return (v == null || v.isEmpty) ? null : v;
  }

  try {
    final repo = ref.read(staffRepositoryProvider);
    final advances = await repo.advancesTaken(
      profileId: payslip.profileId,
      month: payslip.periodMonth,
    );
    final payments = await repo.paymentsFor(payslip.id);

    return SalarySlipData(
      payslip: payslip,
      advances: advances,
      payments: payments,
      factoryName: ref.read(factoryNameProvider),
      currencySymbol: ref.read(currencySymbolProvider),
      factoryAddress: value('factory_address'),
      factoryPhone: value('factory_phone'),
      factoryGstin: value('factory_gstin'),
      footer: value('salary_slip_footer'),
    );
  } on AppException catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error.message)));
    }
    return null;
  }
}

Future<void> shareSalarySlip(
  BuildContext context,
  WidgetRef ref,
  Payslip payslip,
) async {
  final data = await _gather(context, ref, payslip);
  if (data == null) return;

  try {
    final bytes = Uint8List.fromList(await buildSalarySlipPdf(data));
    await Printing.sharePdf(bytes: bytes, filename: '${data.number}.pdf');
  } catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('The slip could not be produced: $error')),
      );
    }
  }
}

Future<void> printSalarySlip(
  BuildContext context,
  WidgetRef ref,
  Payslip payslip,
) async {
  final data = await _gather(context, ref, payslip);
  if (data == null) return;

  try {
    await Printing.layoutPdf(
      onLayout: (format) async =>
          Uint8List.fromList(await buildSalarySlipPdf(data)),
      name: data.number,
    );
  } catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('The slip could not be printed: $error')),
      );
    }
  }
}

/// Offered from a payslip card. Share covers WhatsApp, email and saving to the
/// phone, which between them is how a slip actually reaches a worker.
Future<void> showSalarySlipOptions(
  BuildContext context,
  WidgetRef ref,
  Payslip payslip,
) async {
  await showAppSheet<void>(
    context: context,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Salary slip',
                  style: Theme.of(sheetContext)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 2),
                Text(
                  '${payslip.staffName} · '
                  '${Fmt.monthYear(payslip.periodMonth)}',
                  style: Theme.of(sheetContext).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          ListTile(
            leading: const Icon(Icons.share_outlined),
            title: const Text('Share'),
            subtitle: const Text('WhatsApp, email, or save to the phone'),
            onTap: () {
              Navigator.of(sheetContext).pop();
              shareSalarySlip(context, ref, payslip);
            },
          ),
          ListTile(
            leading: const Icon(Icons.print_outlined),
            title: const Text('Print'),
            subtitle: const Text('Send to a printer'),
            onTap: () {
              Navigator.of(sheetContext).pop();
              printSalarySlip(context, ref, payslip);
            },
          ),
          const SizedBox(height: 12),
        ],
      ),
    ),
  );
}
