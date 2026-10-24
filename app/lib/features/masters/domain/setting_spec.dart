/// What kind of thing a configuration value is (A42).
///
/// Every setting is stored as text — the database reads and interprets it, and
/// that is the right design for a key-value table. It is the wrong thing to
/// *show* somebody: a free text box for a true/false switch invites "yes",
/// "TRUE", "1" and a typo, each of which silently falls back to the default
/// the next time the database reads it, with nothing to say so.
///
/// So the screen asks the right question for each one. Anything not listed
/// here still gets a text box, so a setting added by a later migration keeps
/// working without an app release.
enum SettingKind { toggle, choice, number, text, multiline }

/// One option in a [SettingKind.choice].
class SettingOption {
  const SettingOption(this.value, this.label, [this.note]);

  /// Exactly what is stored. The database matches on this, so it is never
  /// prettified.
  final String value;

  final String label;
  final String? note;
}

class SettingSpec {
  const SettingSpec({
    required this.kind,
    this.label,
    this.options = const [],
    this.min,
    this.max,
    this.suffix,
    this.hint,
  });

  final SettingKind kind;

  /// Overrides the name derived from the key, where the derived one reads
  /// badly — "Factory gstin" rather than "GSTIN".
  final String? label;

  final List<SettingOption> options;
  final num? min;
  final num? max;
  final String? suffix;
  final String? hint;

  /// What a setting is, by key.
  ///
  /// Keys not in here fall through to a plain text box. That is deliberate: a
  /// migration can add a setting and the app will still let somebody edit it,
  /// just without the typed control.
  static const Map<String, SettingSpec> byKey = {
    // ---- Switches ----------------------------------------------------------
    'enforce_machine_product': SettingSpec(
      kind: SettingKind.toggle,
      label: 'Only run configured products',
      options: [
        SettingOption('true', 'Refuse',
            'Production of a product a machine is not set up to run is '
                'refused.'),
        SettingOption('false', 'Allow',
            'Any machine may be credited with any product.'),
      ],
    ),
    'production_requires_batch': SettingSpec(
      kind: SettingKind.toggle,
      label: 'Production needs a material batch',
      options: [
        SettingOption('true', 'Required',
            'A run must name the batch that fed it.'),
        SettingOption('false', 'Optional',
            'A run may be recorded without one.'),
      ],
    ),
    'payroll_recover_advances': SettingSpec(
      kind: SettingKind.toggle,
      label: 'Recover advances from pay',
      options: [
        SettingOption('true', 'Recover',
            'What somebody has drawn comes off their payslip, capped so pay '
                'never goes below zero.'),
        SettingOption('false', 'Leave outstanding',
            'Advances stay on the ledger and are settled some other way.'),
      ],
    ),

    // ---- Choices -----------------------------------------------------------
    'factory_timezone': SettingSpec(
      kind: SettingKind.choice,
      label: 'Factory timezone',
      options: [
        SettingOption('Asia/Kolkata', 'India (IST)'),
        SettingOption('Asia/Dubai', 'Gulf (GST)'),
        SettingOption('Asia/Singapore', 'Singapore'),
        SettingOption('Europe/London', 'United Kingdom'),
        SettingOption('UTC', 'UTC'),
      ],
      hint: 'Which day a shift belongs to, and the day a report covers. The '
          'night shift crosses midnight, so this decides more than it looks.',
    ),
    'currency_symbol': SettingSpec(
      kind: SettingKind.choice,
      label: 'Currency',
      options: [
        SettingOption('₹', 'Rupee  ₹'),
        SettingOption(r'$', r'Dollar  $'),
        SettingOption('€', 'Euro  €'),
        SettingOption('£', 'Pound  £'),
      ],
      hint: 'Shown on every amount. Salary slips print the rupee as "Rs." '
          'because the PDF font has no glyph for it.',
    ),
    'production_wastage_unit': SettingSpec(
      kind: SettingKind.choice,
      label: 'Wastage unit',
      options: [
        SettingOption('kg', 'Kilograms'),
        SettingOption('g', 'Grams'),
      ],
      hint: 'The label beside a wastage figure. It does not convert anything — '
          'change it only if the numbers being typed in really are in the '
          'other unit.',
    ),

    // ---- Numbers -----------------------------------------------------------
    'shred_recovery_tolerance_pct': SettingSpec(
      kind: SettingKind.number,
      label: 'Shred recovery tolerance',
      min: 0,
      max: 100,
      suffix: '%',
      hint: 'A shred may not recover more than the bundle weighed plus this. '
          'Recovering more mass than went in is impossible, so this catches a '
          'mistyped weight before it corrupts stock.',
    ),

    // ---- Text --------------------------------------------------------------
    'factory_name': SettingSpec(kind: SettingKind.text),
    'factory_phone': SettingSpec(kind: SettingKind.text),
    'factory_gstin': SettingSpec(kind: SettingKind.text, label: 'Factory GSTIN'),
    'challan_prefix': SettingSpec(
      kind: SettingKind.text,
      hint: 'Starts every delivery challan number, as in DC-20260115-A1B2.',
    ),
    'factory_address': SettingSpec(
      kind: SettingKind.multiline,
      hint: 'Printed at the head of every challan and salary slip.',
    ),
    'challan_footer': SettingSpec(kind: SettingKind.multiline),
    'salary_slip_footer': SettingSpec(kind: SettingKind.multiline),
  };

  static SettingSpec forKey(String key) =>
      byKey[key] ?? const SettingSpec(kind: SettingKind.text);

  /// The label a stored value should be shown as, where the choice is known.
  /// Falls back to the raw value, so a setting holding something unexpected
  /// shows what it actually holds rather than hiding it.
  String labelFor(String value) {
    for (final option in options) {
      if (option.value == value) return option.label;
    }
    return value.isEmpty ? 'Not set' : value;
  }
}
