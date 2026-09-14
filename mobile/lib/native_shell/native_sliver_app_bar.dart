import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:immich_mobile/native_shell/native_bar_actions.dart';
import 'package:immich_mobile/native_shell/native_shell.dart';
import 'package:immich_mobile/widgets/common/mesmerizing_sliver_app_bar.dart';

/// [MesmerizingSliverAppBar]'s native counterpart.
///
/// The sliver shape of [NativeAppBar]: same publication, same route-derived
/// key, but it lives inside a `CustomScrollView` rather than a `Scaffold` slot.
/// It exists separately because these titles are *dynamic* — an album's name, a
/// partner's name, a place — so the route-to-translation table the earlier
/// pages use cannot express them. The page has the title; the page publishes it.
///
/// Two shapes, because Immich's sliver headers are two shapes. The default
/// falls back to [MesmerizingSliverAppBar] — the cover-photo header an album, a
/// person or a place uses. [NativeSliverAppBar.plain] falls back to an ordinary
/// `SliverAppBar`, which is what Trash has. Both publish the same thing, so the
/// native side cannot tell them apart and does not need to.
class NativeSliverAppBar extends StatefulWidget {
  const NativeSliverAppBar({super.key, required this.title, this.icon = Icons.camera, this.actions})
    : plain = false,
      floating = false,
      snap = false,
      pinned = false,
      centerTitle = false,
      elevation = null;

  const NativeSliverAppBar.plain({
    super.key,
    required this.title,
    this.actions,
    this.floating = false,
    this.snap = false,
    this.pinned = false,
    this.centerTitle = false,
    this.elevation,
  }) : plain = true,
       icon = Icons.camera;

  final String title;
  final IconData icon;
  final List<Widget>? actions;

  /// Which header this stands in for when it is not suppressed.
  final bool plain;
  final bool floating;
  final bool snap;
  final bool pinned;
  final bool centerTitle;
  final double? elevation;

  /// Whether this will hand itself to the native bar and draw nothing.
  ///
  /// Public because the header's *absence* changes the layout around it:
  /// [Timeline] reserves `kToolbarHeight` for a header it is going to draw, and
  /// a suppressed one is not drawn. Asking the widget is more honest than
  /// having every page pass a second flag saying what its own app bar is doing.
  ///
  /// An untranslatable action suppresses nothing, by the same all-or-nothing
  /// rule [NativeAppBar] follows: a native bar missing one of a page's actions
  /// is a worse failure than a Flutter header that has all of them.
  bool get suppressed => NativeShell.isActive && title.isNotEmpty && translateActions(actions) != null;

  @override
  State<NativeSliverAppBar> createState() => _NativeSliverAppBarState();
}

class _NativeSliverAppBarState extends State<NativeSliverAppBar> {
  String? _route;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route ??= RouteData.of(context).name;
    _publish();
  }

  @override
  void didUpdateWidget(NativeSliverAppBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    _publish();
  }

  void _publish() {
    final route = _route;
    if (route == null || !NativeShell.isActive) {
      return;
    }
    final actions = translateActions(widget.actions);
    if (widget.suppressed && actions != null) {
      NativeShell.publishBar(route, title: widget.title, actions: actions);
    } else {
      if (actions == null) {
        NativeShell.logFallback(route, untranslatableAction(widget.actions) ?? 'unknown');
      }
      NativeShell.clearBar(route);
    }
  }

  @override
  void dispose() {
    final route = _route;
    if (route != null) {
      NativeShell.clearBar(route);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.suppressed) {
      // The space the native bar covers, not an empty sliver.
      //
      // [Timeline] reserves the top inset in the branch it takes when there is
      // *no* app bar at all. A suppressed header is still a widget, so it takes
      // the app-bar branch instead and that fallback never runs — which put the
      // first row of "Recently taken" under the navigation bar while "Recently
      // added", which passes null, was correct. Mirrors the padding that branch
      // would have applied.
      return SliverPadding(padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top));
    }
    if (widget.plain) {
      return SliverAppBar(
        title: Text(widget.title),
        floating: widget.floating,
        snap: widget.snap,
        pinned: widget.pinned,
        centerTitle: widget.centerTitle,
        elevation: widget.elevation,
        actions: widget.actions,
      );
    }
    return MesmerizingSliverAppBar(title: widget.title, icon: widget.icon);
  }
}
