import 'package:intl/intl.dart';

/// Display formatting for quantities and dates.
///
/// Kept in one place so a bundle count never renders as "25.0" on one screen
/// and "25" on another.
class Fmt {
  const Fmt._();

  static final NumberFormat _quantity = NumberFormat('#,##0.###');
  static final NumberFormat _whole = NumberFormat('#,##0');
  static final DateFormat _date = DateFormat('d MMM yyyy');
  static final DateFormat _dayMonth = DateFormat('d MMM');
  static final DateFormat _time = DateFormat('HH:mm');
  static final DateFormat _dateTime = DateFormat('d MMM, HH:mm');
  static final DateFormat _iso = DateFormat('yyyy-MM-dd');
  static final DateFormat _weekday = DateFormat('EEE');
  static final DateFormat _monthYear = DateFormat('MMMM yyyy');
  static final NumberFormat _money = NumberFormat('#,##0.00');

  /// Weights and volumes: trailing zeros dropped, so 25.000 reads as "25".
  static String quantity(num? value) => _quantity.format(value ?? 0);

  /// Bundles and other counts.
  static String count(num? value) => _whole.format(value ?? 0);

  static String qtyWithUnit(num? value, String? unit) =>
      '${quantity(value)}${unit == null ? '' : ' $unit'}';

  static String bags(num? value) {
    final n = value ?? 0;
    return '${count(n)} ${n == 1 ? 'bag' : 'bags'}';
  }

  /// "Mon", "Tue" — alongside a relative day, so "3 days ago" still has a
  /// name an operator recognises.
  static String weekday(DateTime value) => _weekday.format(value);

  static String bundles(num? value) {
    final n = value ?? 0;
    return '${count(n)} ${n == 1 ? 'bundle' : 'bundles'}';
  }

  /// Money, with the factory's own currency symbol — not the phone's locale,
  /// which would show a visitor's currency for the same wages. Screens pass
  /// `currencySymbolProvider`; the default keeps simple call sites short.
  static String money(num? value, {String symbol = '₹'}) {
    final amount = value ?? 0;
    final sign = amount < 0 ? '-' : '';
    return '$sign$symbol${_money.format(amount.abs())}';
  }

  /// An amount with no symbol and no grouping, for putting back into a text
  /// field. `money()` output cannot be parsed back — the symbol and the commas
  /// both defeat `double.tryParse` — so an edit form needs this instead.
  static String plainAmount(num value) =>
      value == value.roundToDouble() ? value.toStringAsFixed(0) : '$value';

  /// Text that will actually draw in a PDF built on the standard fonts.
  ///
  /// `pdf` renders with Helvetica unless a font is bundled, and Helvetica has
  /// no glyph for a rupee sign or an em dash. The failure is **silent on the
  /// page** — the character is dropped and the library writes a warning to the
  /// console nobody is watching — so a salary slip would print `5,000.00` with
  /// no currency at all, and a challan `Type  Size` with a hole in it.
  ///
  /// The alternative is bundling a Unicode font, which is a few hundred
  /// kilobytes in every APK for a handful of characters that have perfectly
  /// good ASCII spellings. "Rs." is what Indian salary slips print anyway.
  static String pdfSafe(String value) {
    const swaps = {
      '₹': 'Rs.',
      '—': '-',
      '–': '-',
      '‑': '-',
      '’': "'",
      '‘': "'",
      '“': '"',
      '”': '"',
      '…': '...',
      '×': 'x',
      '·': '-',
      ' ': ' ',
    };

    final out = StringBuffer();
    for (final rune in value.runes) {
      final ch = String.fromCharCode(rune);
      final swap = swaps[ch];
      if (swap != null) {
        out.write(swap);
      } else if (rune < 0x80) {
        out.write(ch);
      }
      // Anything else is dropped rather than printed as a box: the glyph was
      // never going to appear, and a replacement character on a wage slip
      // looks like a fault in the figures.
    }
    return out.toString();
  }

  /// Money for a PDF: [money] with the symbol spelled so it draws.
  static String pdfMoney(num? value, {String symbol = '₹'}) =>
      pdfSafe(money(value, symbol: symbol));

  /// A day of the month as people say it: 1st, 2nd, 3rd, 11th, 21st.
  static String ordinalDay(int day) {
    final suffix = (day % 100 >= 11 && day % 100 <= 13)
        ? 'th'
        : switch (day % 10) {
            1 => 'st',
            2 => 'nd',
            3 => 'rd',
            _ => 'th',
          };
    return '$day$suffix';
  }

  static String monthYear(DateTime value) => _monthYear.format(value);

  static String date(DateTime value) => _date.format(value);
  static String dayMonth(DateTime value) => _dayMonth.format(value);
  static String time(DateTime value) => _time.format(value);
  static String dateTime(DateTime value) => _dateTime.format(value.toLocal());

  /// The wire format Postgres `date` columns expect.
  static String isoDate(DateTime value) => _iso.format(value);

  /// "Today" and "Yesterday" read faster than a date on a dashboard.
  static String relativeDay(DateTime value) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final target = DateTime(value.year, value.month, value.day);
    final diff = today.difference(target).inDays;

    return switch (diff) {
      0 => 'Today',
      1 => 'Yesterday',
      _ => _date.format(value),
    };
  }

  /// Shift label such as "Morning · 06:00–14:00".
  static String shiftRange(String name, String? start, String? end) {
    if (start == null || end == null) return name;
    return '$name · ${start.substring(0, 5)}–${end.substring(0, 5)}';
  }
}
