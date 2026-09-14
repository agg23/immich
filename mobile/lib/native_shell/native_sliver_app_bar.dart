import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:immich_mobile/native_shell/native_bar_actions.dart';
import 'package:immich_mobile/native_shell/native_shell.dart';

class NativeSliverAppBar extends StatefulWidget {
  const NativeSliverAppBar({
    super.key,
    required this.title,
    this.actions,
    this.floating = false,
    this.snap = false,
    this.pinned = false,
    this.centerTitle = false,
    this.elevation,
    this.backgroundColor,
    this.shape,
  });

  final String title;
  final List<Widget>? actions;
  final bool floating;
  final bool snap;
  final bool pinned;
  final bool centerTitle;
  final double? elevation;
  final Color? backgroundColor;
  final ShapeBorder? shape;

  /// Public: [Timeline] reserves `kToolbarHeight` for a header it will draw.
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
    if (actions == null) {
      NativeShell.logFallback(route, untranslatableAction(widget.actions) ?? 'unknown');
      NativeShell.clearBar(route);
      return;
    }
    NativeShell.publishBar(route, title: widget.title, actions: actions);
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
      return SliverPadding(padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top));
    }
    return SliverAppBar(
      title: Text(widget.title),
      floating: widget.floating,
      snap: widget.snap,
      pinned: widget.pinned,
      centerTitle: widget.centerTitle,
      elevation: widget.elevation,
      backgroundColor: widget.backgroundColor,
      shape: widget.shape,
      actions: widget.actions,
    );
  }
}
