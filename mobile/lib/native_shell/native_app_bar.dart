import 'package:flutter/material.dart';
import 'package:immich_mobile/native_shell/native_bar_actions.dart';
import 'package:immich_mobile/native_shell/native_bar_publisher.dart';
import 'package:immich_mobile/native_shell/native_shell.dart';

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

  final double? elevation;
  final double? scrolledUnderElevation;
  final EdgeInsetsGeometry? actionsPadding;

  static String? _textOf(Widget? widget) => widget is Text ? widget.data : null;

  ({String title, List<NativeBarAction> actions})? _translate() {
    // No title is a title: a search tab's bar holds only actions.
    final text = title == null ? '' : _textOf(title);
    if (text == null || bottom != null) {
      return null;
    }
    final translated = translateActions(actions);
    return translated == null ? null : (title: text, actions: translated);
  }

  bool get _suppressed => NativeShell.isActive && _translate() != null;

  String _untranslatable() {
    if (title != null && _textOf(title) == null) {
      return 'title is ${title.runtimeType}';
    }
    if (bottom != null) {
      return 'has a bottom (${bottom.runtimeType})';
    }
    return untranslatableAction(actions) ?? 'unknown';
  }

  @override
  Size get preferredSize => _suppressed
      // Zero, not collapsed: `Scaffold` drops the body's top padding when an app bar exists.
      ? Size.zero
      : Size.fromHeight(kToolbarHeight + (bottom?.preferredSize.height ?? 0));

  @override
  State<NativeAppBar> createState() => _NativeAppBarState();
}

class _NativeAppBarState extends State<NativeAppBar> with NativeBarPublisher<NativeAppBar> {
  @override
  void publishBar() {
    final bar = widget._translate();
    if (bar == null) {
      fallBack(widget._untranslatable());
      return;
    }
    publish(title: bar.title, actions: bar.actions);
  }

  @override
  Widget build(BuildContext context) {
    if (widget._suppressed) {
      return SizedBox(height: MediaQuery.paddingOf(context).top); // See [preferredSize].
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
