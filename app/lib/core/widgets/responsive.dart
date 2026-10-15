import 'package:flutter/material.dart';

/// Screen-size handling for phones and tablets (A40).
///
/// The app was built phone-first — 360dp, one thumb, a bottom bar — and that
/// part was right: it is what the floor uses. On a tablet the same code was
/// merely *not broken*, which is different from working: a card stretched to
/// 1100dp has a line length nobody reads comfortably, a two-up row of stat
/// tiles becomes two enormous boxes, and a bottom bar on a 10" screen in
/// landscape puts navigation as far from the hands as the layout allows.
///
/// Two mechanisms fix almost all of it, and neither requires a second design:
///
///   * [PageBody] centres a page's content and caps its width, so a tablet
///     shows a comfortable column rather than a stretched phone.
///   * [Breakpoint] tells the shell when to move navigation to the side.
///
/// Both are deliberately blunt. A factory app that reads well in one column on
/// every device beats a second tablet layout nobody maintains.
enum Breakpoint {
  /// Phones, and a tablet in a split-screen pane. One column, bottom bar.
  compact,

  /// Small tablets and large phones in landscape. One column, navigation moves
  /// to a rail so the content keeps the full height.
  medium,

  /// Tablets proper. Rail, and the content column at its full cap.
  expanded;

  /// Material's own window-size classes, which is where these numbers come
  /// from rather than from a device somebody happened to test on.
  static Breakpoint of(BuildContext context) =>
      fromWidth(MediaQuery.sizeOf(context).width);

  static Breakpoint fromWidth(double width) {
    if (width < 600) return Breakpoint.compact;
    if (width < 1000) return Breakpoint.medium;
    return Breakpoint.expanded;
  }

  bool get isCompact => this == Breakpoint.compact;

  /// Navigation belongs at the side once there is room, which is both the
  /// Material guidance and the practical answer on a tablet held in two hands.
  bool get usesRail => this != Breakpoint.compact;
}

/// Centres a page's content and caps how wide it grows.
///
/// Wraps the *body*, never the Scaffold: an AppBar should still span the
/// window, and a FloatingActionButton should still sit in the window's corner.
/// Only the content that people read is constrained.
///
/// [maxWidth] defaults to 840, which holds the widest table in the app without
/// becoming a paragraph nobody can track across. A screen whose whole point is
/// width — a report table — can ask for more.
class PageBody extends StatelessWidget {
  const PageBody({super.key, required this.child, this.maxWidth = 840});

  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    // Below the cap this is a no-op, so a phone pays nothing for it — no extra
    // padding, no shifted layout, the same pixels as before.
    if (MediaQuery.sizeOf(context).width <= maxWidth) return child;

    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: child,
      ),
    );
  }
}

/// A modal bottom sheet that does not stretch across a tablet.
///
/// Flutter's sheet is full-width by design, which is right on a phone and
/// absurd on a 1280dp screen — a form with three fields spread over a metre of
/// glass. This caps it and keeps it centred, and is otherwise
/// [showModalBottomSheet] with the arguments this app always passes.
Future<T?> showAppSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool isScrollControlled = true,
  double maxWidth = 640,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: isScrollControlled,
    useSafeArea: true,
    constraints: BoxConstraints(maxWidth: maxWidth),
    builder: builder,
  );
}
