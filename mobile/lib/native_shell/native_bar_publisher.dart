import 'package:auto_route/auto_route.dart';
import 'package:flutter/widgets.dart';
import 'package:immich_mobile/native_shell/native_bar_actions.dart';
import 'package:immich_mobile/native_shell/native_shell.dart';

/// Resolves the route, republishes on rebuild, and withdraws the bar on dispose.
mixin NativeBarPublisher<T extends StatefulWidget> on State<T> {
  String? _route;

  /// Null until dependencies resolve, so publishing cannot happen in `initState`.
  String? get barRoute => _route;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route ??= RouteData.of(context).name;
    publishBar();
  }

  @override
  void didUpdateWidget(covariant T oldWidget) {
    super.didUpdateWidget(oldWidget);
    publishBar();
  }

  /// Empty for bars published from `build`, which read scroll state living only there.
  void publishBar() {}

  void publish({required String title, required List<NativeBarAction> actions, bool hero = false}) {
    final route = _route;
    if (route != null && NativeShell.isActive) {
      NativeShell.publishBar(route, title: title, actions: actions, hero: hero);
    }
  }

  /// Gives the bar back to Flutter, saying once why it could not be translated.
  void fallBack(String reason) {
    final route = _route;
    if (route == null || !NativeShell.isActive) {
      return;
    }
    if (_reported.add(route)) {
      NativeShell.logFallback(route, reason);
    }
    NativeShell.clearBar(route);
  }

  /// Whether the native bar took it; falls back on the first untranslatable action.
  bool publishTranslated({required String title, List<Widget>? actions, bool hero = false}) {
    if (!NativeShell.isActive) {
      return false;
    }
    final translated = translateActions(actions);
    if (translated == null) {
      fallBack(untranslatableAction(actions) ?? 'unknown');
      return false;
    }
    publish(title: title, actions: translated, hero: hero);
    return true;
  }

  @override
  void dispose() {
    final route = _route;
    if (route != null) {
      NativeShell.clearBar(route);
    }
    super.dispose();
  }

  /// Per route, not per widget: the same untranslatable bar rebuilds constantly.
  static final _reported = <String>{};

  @visibleForTesting
  static void resetFallbackLog() => _reported.clear();
}
