import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:immich_mobile/native_shell/native_shell.dart';
import 'package:immich_mobile/routing/tabs.dart';

/// Scripted hooks for driving the shell, the Dart half of `ShellDebug.swift`.
abstract final class NativeShellDebug {
  // Not `kDebugMode`: the shell only runs at speed in a profile build.
  static bool get enabled => !kReleaseMode;

  /// Whether this was a debug call; if not, the caller still treats it as unhandled.
  static Future<bool> handle(MethodCall call, {required RootStackRouter? router, required TabsRouter? tabs}) async {
    if (!enabled || !call.method.startsWith('debug')) {
      return false;
    }
    final args = call.arguments as Map?;
    switch (call.method) {
      case 'debugPush':
        await _push(args!['name']! as String);
      case 'debugPop':
        await router?.maybePopTop();
      case 'debugTab':
        final tab = NativeTab.byId(args!['tab'] as String?);
        if (tab != null) {
          tabs?.setActiveIndex(tab.index);
          NativeShell.syncStack(force: true);
        }
      default:
        return false;
    }
    return true;
  }

  static Future<void> _push(String names) async {
    final router = NativeShell.debugActiveRouter;
    if (router == null) {
      NativeShell.log('no router to push $names onto');
      return;
    }
    for (final name in names.split(',')) {
      NativeShell.log('debug push $name onto ${router.current.name}');
      try {
        unawaited(
          router
              .push(PageRouteInfo<void>(name))
              .then((_) {}, onError: (Object error) => NativeShell.log('debug push $name refused: $error')),
        );
      } catch (error) {
        NativeShell.log('debug push $name threw: $error');
      }
      await Future<void>.delayed(const Duration(milliseconds: 900));
      NativeShell.log('debug push $name left ${router.stackData.map((d) => d.name).join('/')}');
    }
  }
}
