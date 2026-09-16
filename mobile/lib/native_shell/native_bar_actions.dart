import 'package:flutter/material.dart';
import 'package:immich_mobile/native_shell/native_bar_menu.dart';
import 'package:immich_mobile/native_shell/native_icon.dart';
import 'package:immich_mobile/native_shell/native_shell.dart';

NativeBarAction? translateAction(Widget widget) {
  if (widget is NativeBarMenu) {
    return widget.describe();
  }
  if (widget is IconButton) {
    final icon = widget.icon;
    if (icon is! Icon) {
      return null;
    }
    final token = nativeIconFor(icon.icon);
    return token == null ? null : NativeBarAction(icon: token, onPressed: widget.onPressed);
  }
  if (widget is TextButton) {
    final child = widget.child;
    final label = child is Text ? child.data : null;
    return label == null ? null : NativeBarAction(label: label, onPressed: widget.onPressed);
  }
  return null;
}

/// All or nothing: a bar silently missing one action fails invisibly.
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
      return icon is Icon ? 'no icon token for ${icon.icon}' : 'IconButton with ${icon.runtimeType}';
    }
    return 'action is ${action.runtimeType}';
  }
  return null;
}
