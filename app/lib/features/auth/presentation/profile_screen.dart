import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:flutter/services.dart';

import '../../../core/config/app_config.dart';
import '../../../core/error/app_exception.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/panels.dart';
import '../../dashboard/data/dashboard_repository.dart';
import '../domain/app_user.dart';
import 'session_controller.dart';

class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(currentUserProvider);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    if (user == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Profile')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    // Operators see their live machine and shift here; for an admin the
    // dashboard call is admin-only, so the assignment card is simply omitted.
    final assignment = user.isAdmin
        ? null
        : ref.watch(operatorDashboardProvider).value?.assignment;

    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 30,
                    backgroundColor: scheme.primaryContainer,
                    child: Text(
                      user.initials,
                      style: TextStyle(
                        color: scheme.onPrimaryContainer,
                        fontWeight: FontWeight.w700,
                        fontSize: 22,
                      ),
                    ),
                  ),
                  const SizedBox(width: 18),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          user.name,
                          style: theme.textTheme.titleLarge
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          user.role == UserRole.admin
                              ? 'Administrator'
                              : 'Machine Operator',
                          style: theme.textTheme.bodyMedium
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),

          SectionHeader(
            title: 'Details',
            trailing: TextButton.icon(
              key: const Key('edit-profile'),
              onPressed: () => showModalBottomSheet<void>(
                context: context,
                isScrollControlled: true,
                useSafeArea: true,
                builder: (_) => EditProfileSheet(user: user),
              ),
              icon: const Icon(Icons.edit_outlined, size: 18),
              label: const Text('Edit'),
            ),
          ),
          Card(
            child: Column(
              children: [
                DataRow2(label: 'Employee code', value: user.employeeCode),
                const Divider(height: 1),
                DataRow2(
                  label: 'Phone',
                  value: user.phone?.isNotEmpty == true ? user.phone! : '—',
                ),
                if (assignment != null) ...[
                  const Divider(height: 1),
                  DataRow2(
                    label: 'Machine',
                    value: assignment.machineName,
                  ),
                  const Divider(height: 1),
                  DataRow2(
                    label: 'Shift',
                    value: Fmt.shiftRange(
                      assignment.shiftName ?? '—',
                      assignment.startTime,
                      assignment.endTime,
                    ),
                  ),
                ],
              ],
            ),
          ),

          const SectionHeader(title: 'About'),
          Card(
            child: Column(
              children: [
                const DataRow2(label: 'Application', value: 'v1.0.0'),
                const Divider(height: 1),
                DataRow2(label: 'Environment', value: AppConfig.environment),
              ],
            ),
          ),

          const SizedBox(height: 28),
          OutlinedButton.icon(
            onPressed: () async {
              final confirmed = await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('Sign out?'),
                  content:
                      const Text('You will need to sign in again to continue.'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(false),
                      child: const Text('Cancel'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.of(context).pop(true),
                      child: const Text('Sign out'),
                    ),
                  ],
                ),
              );

              if (confirmed ?? false) {
                await ref.read(sessionControllerProvider.notifier).signOut();
              }
            },
            icon: const Icon(Icons.logout_rounded),
            label: const Text('Sign out'),
          ),
        ],
      ),
    );
  }
}

/// Name and phone, and nothing else (A31).
///
/// Employee code, role and login are shown on the profile but are not editable
/// here — `update_my_profile()` cannot change them either.
class EditProfileSheet extends ConsumerStatefulWidget {
  const EditProfileSheet({super.key, required this.user});

  final AppUser user;

  /// The rule the database applies: optional, otherwise 10–15 digits with an
  /// optional leading +, ignoring spaces and hyphens.
  static String? validatePhone(String? value) {
    final digits = (value ?? '').replaceAll(RegExp(r'[\s-]'), '');
    if (digits.isEmpty) return null;
    if (!RegExp(r'^\+?[0-9]{10,15}$').hasMatch(digits)) {
      return 'Enter 10 to 15 digits, e.g. +91 98765 43210';
    }
    return null;
  }

  static String? validateName(String? value) {
    final name = (value ?? '').trim();
    if (name.isEmpty) return 'Enter your name';
    if (name.length > 80) return 'Keep it under 80 characters';
    return null;
  }

  @override
  ConsumerState<EditProfileSheet> createState() => _EditProfileSheetState();
}

class _EditProfileSheetState extends ConsumerState<EditProfileSheet> {
  final _formKey = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.user.name);
  late final _phone = TextEditingController(text: widget.user.phone ?? '');
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;

    setState(() {
      _saving = true;
      _error = null;
    });

    try {
      await ref.read(sessionControllerProvider.notifier).updateProfile(
            name: _name.text,
            phone: _phone.text.trim().isEmpty ? null : _phone.text,
          );
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Profile updated.')),
      );
    } on AppException catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = error.message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: scheme.outlineVariant,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Text(
                'Edit profile',
                style: theme.textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 18),
              TextFormField(
                key: const Key('profile-name'),
                controller: _name,
                enabled: !_saving,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  prefixIcon: Icon(Icons.person_outline_rounded),
                ),
                validator: EditProfileSheet.validateName,
              ),
              const SizedBox(height: 14),
              TextFormField(
                key: const Key('profile-phone'),
                controller: _phone,
                enabled: !_saving,
                keyboardType: TextInputType.phone,
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9+\s-]')),
                ],
                decoration: const InputDecoration(
                  labelText: 'Phone number',
                  hintText: '+91 98765 43210',
                  prefixIcon: Icon(Icons.phone_outlined),
                ),
                validator: EditProfileSheet.validatePhone,
              ),
              const SizedBox(height: 14),
              Text(
                'Your employee code, role and sign-in are managed by an '
                'administrator.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
              if (_error != null) ...[
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: scheme.errorContainer,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    _error!,
                    style: TextStyle(color: scheme.onErrorContainer),
                  ),
                ),
              ],
              const SizedBox(height: 20),
              FilledButton(
                key: const Key('profile-save'),
                onPressed: _saving ? null : _save,
                child: _saving
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Save'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
