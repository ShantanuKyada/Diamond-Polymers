import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/error/app_exception.dart';
import '../../../../core/widgets/state_views.dart';

/// The list-and-edit pattern every master screen shares.
///
/// Five screens would otherwise each reimplement pull-to-refresh, the three
/// async states, an empty message and a floating add button — and drift apart
/// doing it. Parameterised on the row type so each screen only supplies the
/// tile and the form.
class MasterScaffold<T> extends StatelessWidget {
  const MasterScaffold({
    super.key,
    required this.title,
    required this.items,
    required this.itemBuilder,
    required this.onRefresh,
    required this.emptyMessage,
    this.subtitle,
    this.onAdd,
    this.addLabel = 'Add',
    this.emptyIcon = Icons.inbox_outlined,
    this.header,
    this.actions,
  });

  final String title;
  final String? subtitle;
  final AsyncValue<List<T>> items;
  final Widget Function(BuildContext context, T item) itemBuilder;
  final VoidCallback onRefresh;
  final String emptyMessage;
  final IconData emptyIcon;
  final VoidCallback? onAdd;
  final String addLabel;

  /// Rendered above the list, inside the scroll view — used for explanatory
  /// notes that would be wrong in an app bar.
  final Widget? header;
  final List<Widget>? actions;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: subtitle == null
            ? Text(title)
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(title),
                  Text(
                    subtitle!,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                ],
              ),
        actions: actions,
      ),
      floatingActionButton: onAdd == null
          ? null
          : FloatingActionButton.extended(
              onPressed: onAdd,
              icon: const Icon(Icons.add_rounded),
              label: Text(addLabel),
            ),
      body: RefreshIndicator(
        onRefresh: () async => onRefresh(),
        child: AsyncView<List<T>>(
          value: items,
          onRetry: onRefresh,
          builder: (context, rows) {
            if (rows.isEmpty) {
              return ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: [
                  ?header,
                  const SizedBox(height: 80),
                  EmptyView(message: emptyMessage, icon: emptyIcon),
                ],
              );
            }

            return ListView.separated(
              physics: const AlwaysScrollableScrollPhysics(),
              // Room for the FAB not to cover the last row.
              padding: EdgeInsets.only(bottom: onAdd == null ? 16 : 88),
              itemCount: rows.length + (header == null ? 0 : 1),
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) {
                if (header != null) {
                  if (index == 0) return header!;
                  return itemBuilder(context, rows[index - 1]);
                }
                return itemBuilder(context, rows[index]);
              },
            );
          },
        ),
      ),
    );
  }
}

/// Opens an edit form as a bottom sheet and returns true if it saved.
///
/// A sheet rather than a page because master edits are short, and returning to
/// an unchanged list behind the sheet makes the change easy to see.
Future<bool> showEditSheet({
  required BuildContext context,
  required String title,
  required List<Widget> Function(void Function() rebuild) fields,
  required Future<void> Function() onSave,
  String saveLabel = 'Save',
}) async {
  final saved = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (context) => _EditSheet(
      title: title,
      fields: fields,
      onSave: onSave,
      saveLabel: saveLabel,
    ),
  );
  return saved ?? false;
}

class _EditSheet extends StatefulWidget {
  const _EditSheet({
    required this.title,
    required this.fields,
    required this.onSave,
    required this.saveLabel,
  });

  final String title;
  final List<Widget> Function(void Function() rebuild) fields;
  final Future<void> Function() onSave;
  final String saveLabel;

  @override
  State<_EditSheet> createState() => _EditSheetState();
}

class _EditSheetState extends State<_EditSheet> {
  final _formKey = GlobalKey<FormState>();
  bool _busy = false;
  String? _error;

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      await widget.onSave();
      if (mounted) Navigator.of(context).pop(true);
    } on AppException catch (error) {
      // The sheet stays open and shows why, rather than closing and leaving the
      // operator to guess whether anything was saved.
      if (mounted) {
        setState(() {
          _busy = false;
          _error = error.message;
        });
      }
    } catch (error, stack) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = ErrorMapper.map(error, stack).message;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final inset = MediaQuery.of(context).viewInsets.bottom;

    return Padding(
      padding: EdgeInsets.only(bottom: inset),
      child: Form(
        key: _formKey,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: scheme.outlineVariant,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Text(
                widget.title,
                style: Theme.of(context)
                    .textTheme
                    .titleLarge
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 20),
              ...widget.fields(() => setState(() {})),
              if (_error != null) ...[
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: scheme.errorContainer,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.error_outline_rounded,
                          size: 18, color: scheme.onErrorContainer),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          _error!,
                          style: TextStyle(color: scheme.onErrorContainer),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _busy ? null : _save,
                child: _busy
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(widget.saveLabel),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: _busy ? null : () => Navigator.of(context).pop(false),
                child: const Text('Cancel'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A labelled text field sized for a factory floor (§42: large targets).
class SheetField extends StatelessWidget {
  const SheetField({
    super.key,
    required this.controller,
    required this.label,
    this.hint,
    this.keyboardType,
    this.required = false,
    this.validator,
    this.maxLines = 1,
    this.helper,
  });

  final TextEditingController controller;
  final String label;
  final String? hint;
  final String? helper;
  final TextInputType? keyboardType;
  final bool required;
  final String? Function(String?)? validator;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: TextFormField(
        controller: controller,
        keyboardType: keyboardType,
        maxLines: maxLines,
        decoration: InputDecoration(
          labelText: required ? '$label *' : label,
          hintText: hint,
          helperText: helper,
          helperMaxLines: 3,
          border: const OutlineInputBorder(),
        ),
        validator: validator ??
            (value) {
              if (!required) return null;
              return (value == null || value.trim().isEmpty)
                  ? '$label is required'
                  : null;
            },
      ),
    );
  }
}

/// A dropdown with the same spacing as [SheetField].
class SheetDropdown<T> extends StatelessWidget {
  const SheetDropdown({
    super.key,
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
    this.required = false,
    this.helper,
  });

  final String label;
  final T? value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?> onChanged;
  final bool required;
  final String? helper;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: DropdownButtonFormField<T>(
        initialValue: value,
        items: items,
        onChanged: onChanged,
        isExpanded: true,
        decoration: InputDecoration(
          labelText: required ? '$label *' : label,
          helperText: helper,
          helperMaxLines: 3,
          border: const OutlineInputBorder(),
        ),
        validator: required
            ? (v) => v == null ? '$label is required' : null
            : null,
      ),
    );
  }
}

/// Shows a message without needing a `BuildContext` gymnastics dance at every
/// call site.
void showMessage(BuildContext context, String message, {bool error = false}) {
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(message),
      backgroundColor:
          error ? Theme.of(context).colorScheme.error : null,
    ),
  );
}
