import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:immich_mobile/native_shell/native_bar_actions.dart';
import 'package:immich_mobile/native_shell/native_shell.dart';

/// An [AppBar] that gives itself to the native navigation bar.
///
/// A drop-in: under the native shell it hands its title and actions to the
/// `UINavigationBar` and reserves the space that bar occupies; off the shell it
/// builds the `AppBar` it was handed. One declaration either way, so the native
/// and Flutter versions of a page's header cannot drift apart.
///
/// The route name comes from [RouteData], not from the call site. The earlier
/// mechanism had each page repeat its own route name as a string literal and
/// kept a second table of titles beside it; a page already knows which route it
/// is, and its own `title:` is already localised.
///
/// ### What it refuses to translate
///
/// A `Text` title and whatever [translateAction] can read: `IconButton`s whose
/// icon has an SF Symbol, `TextButton`s with a `Text` child, and a
/// [NativeBarMenu], which describes its own rows. Anything else — a search field
/// in the title, an icon with no symbol for it — and the *whole* bar stays in
/// Flutter.
///
/// All-or-nothing on purpose. A native bar that rendered the two actions it
/// understood and silently dropped the third would be a worse failure than no
/// native bar at all, and it would be invisible in review: the page still looks
/// finished. Falling back whole means the only cost of an unsupported action is
/// that the page keeps the header it has today.
class NativeAppBar extends StatefulWidget implements PreferredSizeWidget {
  const NativeAppBar({
    super.key,
    this.title,
    this.actions,
    this.leading,
    this.centerTitle,
    this.backgroundColor,
    this.bottom,
    this.automaticallyImplyLeading = true,
    this.elevation,
    this.scrolledUnderElevation,
    this.actionsPadding,
  });

  final Widget? title;
  final List<Widget>? actions;
  final Widget? leading;
  final bool? centerTitle;
  final Color? backgroundColor;
  final PreferredSizeWidget? bottom;
  final bool automaticallyImplyLeading;

  /// Forwarded to [AppBar] and meaningless when the native bar is showing:
  /// a `UINavigationBar` draws its own material and spacing.
  final double? elevation;
  final double? scrolledUnderElevation;
  final EdgeInsetsGeometry? actionsPadding;

  static String? _textOf(Widget? widget) => widget is Text ? widget.data : null;

  /// The bar as the native side would receive it, or null if any part of it
  /// does not translate.
  ({String title, List<NativeBarAction> actions})? _translate() {
    final text = _textOf(title);
    // `bottom` is a second row — a tab strip or a progress bar — and a
    // `UINavigationBar` has nowhere to put one.
    if (text == null || bottom != null) {
      return null;
    }
    final translated = translateActions(actions);
    return translated == null ? null : (title: text, actions: translated);
  }

  bool get _suppressed => NativeShell.isActive && _translate() != null;

  /// What stopped this bar translating, for the log.
  String _untranslatable() {
    if (_textOf(title) == null) {
      return 'title is ${title.runtimeType}';
    }
    if (bottom != null) {
      return 'has a bottom (${bottom.runtimeType})';
    }
    return untranslatableAction(actions) ?? 'unknown';
  }

  @override
  Size get preferredSize => _suppressed
      // Zero, so `Scaffold` constrains the slot to exactly the top padding —
      // which is the native bar's own footprint. Reserving it rather than
      // collapsing to nothing is what keeps the body out from under the bar:
      // `Scaffold` strips the top padding from the body whenever an app bar is
      // present, so a zero-height header would put the first row under both the
      // navigation bar and the status bar.
      ? Size.zero
      : Size.fromHeight(kToolbarHeight + (bottom?.preferredSize.height ?? 0));

  @override
  State<NativeAppBar> createState() => _NativeAppBarState();
}

class _NativeAppBarState extends State<NativeAppBar> {
  static final _reported = <String>{};
  String? _route;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route ??= RouteData.of(context).name;
    _publish();
  }

  @override
  void didUpdateWidget(NativeAppBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    _publish();
  }

  void _publish() {
    final route = _route;
    if (route == null || !NativeShell.isActive) {
      return;
    }
    final bar = widget._translate();
    if (bar == null) {
      // Says which pages are still drawing their own header and why, so "this
      // one is not native yet" is a log line rather than a hunt through the
      // page. Once per route, because this runs on every build.
      if (_reported.add(route)) {
        NativeShell.logFallback(route, widget._untranslatable());
      }
      NativeShell.clearBar(route);
    } else {
      NativeShell.publishBar(route, title: bar.title, actions: bar.actions);
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
    if (widget._suppressed) {
      // The space the native bar covers. See [NativeAppBar.preferredSize].
      return SizedBox(height: MediaQuery.paddingOf(context).top);
    }
    return AppBar(
      title: widget.title,
      actions: widget.actions,
      leading: widget.leading,
      centerTitle: widget.centerTitle,
      backgroundColor: widget.backgroundColor,
      bottom: widget.bottom,
      automaticallyImplyLeading: widget.automaticallyImplyLeading,
      elevation: widget.elevation,
      scrolledUnderElevation: widget.scrolledUnderElevation,
      actionsPadding: widget.actionsPadding,
    );
  }
}
