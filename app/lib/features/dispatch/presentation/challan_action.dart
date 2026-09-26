import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:printing/printing.dart';

import '../../../core/utils/formatters.dart';
import '../../masters/data/settings_values.dart';
import '../data/dispatch_repository.dart';
import 'challan_document.dart';

/// Assembles a [ChallanData] for a dispatch from the factory's own settings.
///
/// The factory's name, address, phone and GSTIN are configuration, not
/// literals: the address on a document that leaves the premises must be
/// changeable without a new APK.
ChallanData challanFor(WidgetRef ref, Dispatch dispatch) {
  final settings = ref.read(settingsMapProvider);
  String? value(String key) {
    final v = settings[key]?.trim();
    return (v == null || v.isEmpty) ? null : v;
  }

  return ChallanData(
    dispatch: dispatch,
    factoryName: ref.read(factoryNameProvider),
    factoryAddress: value('factory_address'),
    factoryPhone: value('factory_phone'),
    factoryGstin: value('factory_gstin'),
    prefix: value('challan_prefix') ?? 'DC',
    footer: value('challan_footer'),
  );
}

/// Builds the challan and hands it to the phone's share sheet or a printer.
///
/// Share rather than save: the driver needs it on WhatsApp, the buyer by email,
/// and the office on paper. `Printing` covers all three from one sheet, and
/// works with no signal — which is the case that matters, standing next to a
/// loaded lorry.
Future<void> shareChallan(
  BuildContext context,
  WidgetRef ref,
  Dispatch dispatch,
) async {
  final data = challanFor(ref, dispatch);

  // Warn once, but do not block: a challan with no address is still better
  // than no challan when the lorry is waiting. The missing piece is fixable in
  // Configuration and the document says so by looking unfinished.
  if (data.factoryAddress == null && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'No factory address set — the challan will print without one. '
          'Add it under More → Configuration.',
        ),
      ),
    );
  }

  try {
    final bytes = Uint8List.fromList(await buildChallanPdf(data));
    await Printing.sharePdf(
      bytes: bytes,
      filename: '${data.number}.pdf',
    );
  } catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('The challan could not be produced: $error')),
      );
    }
  }
}

/// Opens the challan in a print preview, for an office printer.
Future<void> printChallan(
  BuildContext context,
  WidgetRef ref,
  Dispatch dispatch,
) async {
  final data = challanFor(ref, dispatch);
  try {
    await Printing.layoutPdf(
      onLayout: (format) async =>
          Uint8List.fromList(await buildChallanPdf(data)),
      name: data.number,
    );
  } catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('The challan could not be printed: $error')),
      );
    }
  }
}

/// The bottom sheet offered from a dispatch row.
Future<void> showChallanOptions(
  BuildContext context,
  WidgetRef ref,
  Dispatch dispatch,
) async {
  final data = challanFor(ref, dispatch);

  await showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
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
                  'Delivery challan',
                  style: Theme.of(sheetContext)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 2),
                Text(
                  '${data.number} · ${dispatch.customerName} · '
                  '${Fmt.date(dispatch.date)}',
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
              shareChallan(context, ref, dispatch);
            },
          ),
          ListTile(
            leading: const Icon(Icons.print_outlined),
            title: const Text('Print'),
            subtitle: const Text('Send to a printer'),
            onTap: () {
              Navigator.of(sheetContext).pop();
              printChallan(context, ref, dispatch);
            },
          ),
          const SizedBox(height: 12),
        ],
      ),
    ),
  );
}
