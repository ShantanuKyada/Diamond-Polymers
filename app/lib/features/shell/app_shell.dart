import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/widgets/responsive.dart';
import '../auth/presentation/session_controller.dart';

/// One destination in a shell's navigation.
///
/// Carries its own visibility rule rather than being filtered by the caller,
/// because the branches behind these destinations are positional: hide one in
/// the wrong place and every tap afterwards opens the wrong screen. Keeping the
/// rule and the index together is what stops that.
class ShellDestination {
  const ShellDestination({
    required this.icon,
    required this.label,
    this.selectedIcon,
    this.requiresMachineWork = false,
  });

  final Widget icon;
  final Widget? selectedIcon;
  final String label;

  /// Only shown to somebody who actually runs machines (A40). A labourer signs
  /// in to the same app and is on the payroll, but has no run to record — and
  /// the database refuses one from them — so Material and Production would be
  /// two tabs that could only ever fail.
  final bool requiresMachineWork;
}

/// The frame around a tabbed application: bottom bar on a phone, side rail on
/// a tablet (A40).
///
/// The rail is not decoration. On a 10" screen in landscape a bottom bar puts
/// navigation at the far edge of the glass from where the device is held, and
/// costs a row of height the content wants. Material's own guidance moves it to
/// the side at 600dp, which is what [Breakpoint.usesRail] says.
class AppShell extends ConsumerWidget {
  const AppShell({
    super.key,
    required this.navigationShell,
    required this.destinations,
  });

  final StatefulNavigationShell navigationShell;
  final List<ShellDestination> destinations;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(currentUserProvider);
    final runsMachines = user?.runsMachines ?? true;

    // Each visible destination remembers which branch it belongs to, so the
    // indices stay right however many are hidden.
    final visible = <(ShellDestination, int)>[];
    for (var i = 0; i < destinations.length; i++) {
      final d = destinations[i];
      if (d.requiresMachineWork && !runsMachines) continue;
      visible.add((d, i));
    }

    // If the current branch is one that has just been hidden, the bar shows the
    // first tab rather than nothing — which is what happens to a labourer whose
    // login lands them on a machine screen.
    final selected = visible.indexWhere((e) => e.$2 == navigationShell.currentIndex);
    final index = selected < 0 ? 0 : selected;

    void select(int i) {
      final branch = visible[i].$2;
      navigationShell.goBranch(
        branch,
        // Tapping the current tab returns it to its first screen, which is the
        // behaviour people expect from a bottom bar.
        initialLocation: branch == navigationShell.currentIndex,
      );
    }

    if (!Breakpoint.of(context).usesRail) {
      return Scaffold(
        body: navigationShell,
        bottomNavigationBar: NavigationBar(
          selectedIndex: index,
          onDestinationSelected: select,
          destinations: [
            for (final (d, _) in visible)
              NavigationDestination(
                icon: d.icon,
                selectedIcon: d.selectedIcon,
                label: d.label,
              ),
          ],
        ),
      );
    }

    return Scaffold(
      body: Row(
        children: [
          NavigationRail(
            selectedIndex: index,
            onDestinationSelected: select,
            // Labels always shown: these are five short words, and a factory
            // app is used by people who should not have to learn icons.
            labelType: NavigationRailLabelType.all,
            destinations: [
              for (final (d, _) in visible)
                NavigationRailDestination(
                  icon: d.icon,
                  selectedIcon: d.selectedIcon,
                  label: Text(d.label),
                ),
            ],
          ),
          const VerticalDivider(width: 1, thickness: 1),
          Expanded(child: navigationShell),
        ],
      ),
    );
  }
}
