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
