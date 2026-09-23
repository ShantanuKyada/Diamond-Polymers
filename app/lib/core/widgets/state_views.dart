import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../error/app_exception.dart';

/// Loading, error and empty presentations (§45, §68).
///
/// Screens use [AsyncView] instead of hand-rolling `when(...)` so all three
/// states look and behave the same everywhere.

class LoadingView extends StatelessWidget {
  const LoadingView({super.key, this.label});

  final String? label;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          if (label != null) ...[
            const SizedBox(height: 16),
            Text(label!, style: Theme.of(context).textTheme.bodyMedium),
          ],
        ],
      ),
    );
  }
}

class ErrorView extends StatelessWidget {
  const ErrorView({super.key, required this.error, this.onRetry});

  final AppException error;
  final VoidCallback? onRetry;

  IconData get _icon => switch (error.kind) {
        AppErrorKind.network => Icons.wifi_off_rounded,
        AppErrorKind.authorization => Icons.lock_outline_rounded,
        AppErrorKind.authentication => Icons.person_off_outlined,
        AppErrorKind.insufficientStock => Icons.inventory_2_outlined,
        AppErrorKind.validation => Icons.error_outline_rounded,
        AppErrorKind.notConfigured => Icons.construction_outlined,
        AppErrorKind.conflict => Icons.lock_clock_outlined,
        AppErrorKind.unexpected => Icons.report_gmailerrorred_rounded,
      };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(_icon, size: 44, color: scheme.error),
            const SizedBox(height: 16),
            Text(
              error.message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyLarge,
            ),
            if (onRetry != null && error.isRetryable) ...[
              const SizedBox(height: 20),
              OutlinedButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Try again'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class EmptyView extends StatelessWidget {
  const EmptyView({
    super.key,
    required this.message,
    this.icon = Icons.inbox_outlined,
    this.action,
  });

  final String message;
  final IconData icon;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 44, color: scheme.outline),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .bodyLarge
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
            if (action != null) ...[const SizedBox(height: 20), action!],
          ],
        ),
      ),
    );
  }
}

/// Renders an [AsyncValue] with consistent loading and error handling.
///
/// Errors are mapped through [ErrorMapper] here rather than at every call site,
/// so a raw `PostgrestException` can never reach the screen (§45).
class AsyncView<T> extends StatelessWidget {
  const AsyncView({
    super.key,
    required this.value,
    required this.builder,
    this.onRetry,
    this.loadingLabel,
  });

  final AsyncValue<T> value;
  final Widget Function(BuildContext context, T data) builder;
  final VoidCallback? onRetry;
  final String? loadingLabel;

  @override
  Widget build(BuildContext context) {
    return value.when(
      // `skipLoadingOnRefresh: false` is intentionally not used: on a pull to
      // refresh we keep showing the previous data rather than blanking the
      // screen, which matters when the network is slow (§46).
      data: (data) => builder(context, data),
      loading: () => LoadingView(label: loadingLabel),
      error: (error, stack) => ErrorView(
        error: ErrorMapper.map(error, stack),
        onRetry: onRetry,
      ),
    );
  }
}
