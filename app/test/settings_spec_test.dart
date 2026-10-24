import 'dart:io';

import 'package:diamond_polymers/features/masters/domain/setting_spec.dart';
import 'package:flutter_test/flutter_test.dart';

/// Configuration values are typed, not free text (A42).
///
/// Everything in app_settings is stored as text, which is right for the
/// database and wrong for a screen: a text box for a true/false rule invites
/// "yes", "TRUE", "1" and a typo, each of which silently falls back to the
/// default the next time the database reads it, with nothing to say so.
void main() {
  group('what each setting is', () {
    test('the rules are switches with the two answers spelled out', () {
      for (final key in [
        'enforce_machine_product',
        'production_requires_batch',
        'payroll_recover_advances',
      ]) {
        final spec = SettingSpec.forKey(key);
        expect(spec.kind, SettingKind.toggle, reason: key);
        expect(spec.options.map((o) => o.value), ['true', 'false'],
            reason: '$key must store exactly what the database reads');
        // Each option says what happens, not just "on" and "off".
        expect(spec.options.every((o) => (o.note ?? '').isNotEmpty), isTrue,
            reason: '$key should explain the consequence of each choice');
      }
    });

    test('the picks are choices, and only offer real values', () {
      expect(SettingSpec.forKey('factory_timezone').kind, SettingKind.choice);
      expect(
        SettingSpec.forKey('factory_timezone').options.map((o) => o.value),
        contains('Asia/Kolkata'),
      );
      expect(SettingSpec.forKey('currency_symbol').options.map((o) => o.value),
          contains('₹'));
      expect(SettingSpec.forKey('production_wastage_unit').options
          .map((o) => o.value), contains('kg'));
    });

    test('the tolerance is a bounded number', () {
      final spec = SettingSpec.forKey('shred_recovery_tolerance_pct');
      expect(spec.kind, SettingKind.number);
      expect(spec.min, 0);
      expect(spec.max, 100);
      expect(spec.suffix, '%');
    });

    test('a key nobody has specified still gets an editor', () {
      // A migration can add a setting without an app release. It loses the
      // typed control, not the ability to be changed.
      final spec = SettingSpec.forKey('something_added_next_year');
      expect(spec.kind, SettingKind.text);
      expect(spec.options, isEmpty);
    });
  });

  group('what the list shows', () {
    test('a known value reads as what it means', () {
      expect(SettingSpec.forKey('enforce_machine_product').labelFor('true'),
          'Refuse');
      expect(SettingSpec.forKey('factory_timezone').labelFor('Asia/Kolkata'),
          'India (IST)');
    });

    test('an unknown value shows itself rather than hiding', () {
      // A setting holding something unexpected is exactly what somebody needs
      // to see, so it is never disguised as the default.
      expect(SettingSpec.forKey('enforce_machine_product').labelFor('maybe'),
          'maybe');
      expect(SettingSpec.forKey('factory_timezone').labelFor(''), 'Not set');
    });
  });

  group('the factory mark', () {
    test('ships with the app and is a real PNG', () {
      for (final path in [
        'assets/brand/logo.png',
        'assets/brand/logo_tile.png',
      ]) {
        final file = File(path);
        expect(file.existsSync(), isTrue, reason: '$path is missing');

        final bytes = file.readAsBytesSync();
        expect(bytes.length, greaterThan(2000), reason: '$path looks empty');
        // PNG signature, so a truncated or mis-saved file fails here rather
        // than as a broken image on the sign-in screen.
        expect(bytes.sublist(0, 8),
            [137, 80, 78, 71, 13, 10, 26, 10], reason: '$path is not a PNG');
      }
    });

    test('the launcher icon exists at every density', () {
      const buckets = {
        'mdpi': 48, 'hdpi': 72, 'xhdpi': 96, 'xxhdpi': 144, 'xxxhdpi': 192,
      };
      for (final bucket in buckets.keys) {
        final icon = File(
            'android/app/src/main/res/mipmap-$bucket/ic_launcher.png');
        expect(icon.existsSync(), isTrue, reason: 'mipmap-$bucket is missing');

        // Width and height live at bytes 16-23 of the IHDR chunk.
        final b = icon.readAsBytesSync();
        final width = (b[16] << 24) | (b[17] << 16) | (b[18] << 8) | b[19];
        final height = (b[20] << 24) | (b[21] << 16) | (b[22] << 8) | b[23];
        expect(width, buckets[bucket], reason: 'mipmap-$bucket wrong width');
        expect(height, width, reason: 'a launcher icon must be square');
      }
    });

    test('the adaptive icon is wired up for Android 8 and later', () {
      final xml = File(
          'android/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml');
      expect(xml.existsSync(), isTrue);

      final text = xml.readAsStringSync();
      expect(text, contains('ic_launcher_foreground'));
      expect(text, contains('ic_launcher_background'));

      // The background colour has to resolve, or the icon renders black.
      final colour = File(
          'android/app/src/main/res/values/ic_launcher_background.xml');
      expect(colour.existsSync(), isTrue);
      expect(colour.readAsStringSync(), contains('ic_launcher_background'));
    });
  });
}
