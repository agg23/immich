import 'package:auto_route/auto_route.dart';
import 'package:flutter/widgets.dart';
import 'package:immich_mobile/native_shell/native_bar_actions.dart';
import 'package:immich_mobile/native_shell/native_shell.dart';

mixin NativeHeroBar<T extends StatefulWidget> on State<T> {
  String? _route;
  bool _hero = false;

  bool get isHero => _hero;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route ??= RouteData.of(context).name;
  }

  void publishHeroBar({required String title, List<Widget>? actions}) {
    final route = _route;
    if (route == null || !NativeShell.isActive) {
      return;
    }
    final translated = translateActions(actions);
    _hero = translated != null;
    if (translated == null) {
      NativeShell.logFallback(route, untranslatableAction(actions) ?? 'unknown');
      return;
    }
    NativeShell.publishBar(route, title: title, actions: translated, hero: true);
  }

  void reportHeroCollapse(double scrollProgress) {
    final route = _route;
    if (_hero && route != null) {
      NativeShell.setBarCollapsed(route, collapsed: scrollProgress > 0.95);
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
}
