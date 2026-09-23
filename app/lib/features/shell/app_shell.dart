import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// Bottom-navigation scaffolding shared by both applications (§42, §34, §35).
///
/// `StatefulShellRoute.indexedStack` keeps each tab's navigation stack and
/// scroll position alive, so an operator who is halfway through a form does not
/// lose it by glancing at another tab.
class AppShell extends StatelessWidget {
  const AppShell({
    super.key,
    required this.navigationShell,
    required this.destinations,
  });

  final StatefulNavigationShell navigationShell;
  final List<NavigationDestination> destinations;

  void _onSelect(int index) {
    navigationShell.goBranch(
      index,
      // Tapping the current tab returns it to its first screen, which is the
      // behaviour people expect from a bottom bar.
      initialLocation: index == navigationShell.currentIndex,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: navigationShell,
      bottomNavigationBar: NavigationBar(
        selectedIndex: navigationShell.currentIndex,
        onDestinationSelected: _onSelect,
        destinations: destinations,
      ),
    );
  }
}
