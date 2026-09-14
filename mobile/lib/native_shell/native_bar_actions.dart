import 'package:flutter/material.dart';
import 'package:immich_mobile/native_shell/native_bar_menu.dart';
import 'package:immich_mobile/native_shell/native_shell.dart';
import 'package:immich_mobile/native_shell/native_symbols.dart';

/// One app bar action as the native bar would receive it, or null.
///
/// A `NativeBarMenu` describes itself. Everything else is read off the widget:
/// an `IconButton` whose icon has a symbol, or a `TextButton` with a `Text`
/// child. Anything else does not translate, and by the all-or-nothing rule that
/// keeps its whole bar in Flutter.
NativeBarAction? translateAction(Widget widget) {
  // Declared rather than inferred: a menu's rows only exist once the page's own
  // action widget has been built, which is not something a bar reading
  // `actions` can do. See [NativeBarMenu].
  if (widget is NativeBarMenu) {
    return widget.describe();
  }
  if (widget is IconButton) {
    final icon = widget.icon;
    if (icon is! Icon) {
      return null;
    }
    final symbol = nativeSymbolFor(icon.icon);
    return symbol == null ? null : NativeBarAction(symbol: symbol, onPressed: widget.onPressed);
  }
  if (widget is TextButton) {
    final child = widget.child;
    final label = child is Text ? child.data : null;
    return label == null ? null : NativeBarAction(label: label, onPressed: widget.onPressed);
  }
  return null;
}

/// Every action translated, or null if any one of them did not.
///
/// Shared by both bar shapes because the rule is the same in both and a second
/// copy would be a second thing to keep in step: a native bar that rendered the
/// two actions it understood and silently dropped the third is a worse failure
/// than no native bar at all, and an invisible one — the page still looks
/// finished.
List<NativeBarAction>? translateActions(List<Widget>? actions) {
  final translated = <NativeBarAction>[];
  for (final action in actions ?? const <Widget>[]) {
    final mapped = translateAction(action);
    if (mapped == null) {
      return null;
    }
    translated.add(mapped);
  }
  return translated;
}

/// Which action stopped a bar translating, and why, for the log.
String? untranslatableAction(List<Widget>? actions) {
  for (final action in actions ?? const <Widget>[]) {
    if (translateAction(action) != null) {
      continue;
    }
    if (action is NativeBarMenu) {
      return action.untranslatable() ?? 'menu did not translate';
    }
    if (action is IconButton) {
      final icon = action.icon;
      return icon is Icon ? 'no symbol for ${icon.icon}' : 'IconButton with ${icon.runtimeType}';
    }
    return 'action is ${action.runtimeType}';
  }
  return null;
}
