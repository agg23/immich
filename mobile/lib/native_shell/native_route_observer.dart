import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:immich_mobile/native_shell/native_shell.dart';

class NativeRouteObserver extends AutoRouterObserver {
  NativeRouteObserver();

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
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
