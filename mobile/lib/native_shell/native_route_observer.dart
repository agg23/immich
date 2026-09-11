import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:immich_mobile/native_shell/native_shell.dart';

/// Mirrors Immich's navigation into the native shell's stack.
///
/// An observer rather than a wrapper around every `pushRoute` call site: there
/// are ~70 routes and pushes happen from pages, from guards, from deep links
/// and from the tab router, and an observer sees all of them without any of
/// them knowing the native shell exists.
///
/// Every callback does the same thing, because the shell is told what the stack
/// *is* rather than what changed. A push the native side never received used to
/// leave it short a frame for good; now the next routing event of any kind puts
/// the two sides back in agreement.
class NativeRouteObserver extends AutoRouterObserver {
  NativeRouteObserver();

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    // The one callback that reads its route: whether it is opaque decides
    // whether it is a stack frame at all.
    NativeShell.didPush(route);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    NativeShell.didChangeRoutes();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    NativeShell.didChangeRoutes();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    NativeShell.didChangeRoutes();
  }
}
