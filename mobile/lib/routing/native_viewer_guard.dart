import 'package:auto_route/auto_route.dart';
import 'package:immich_mobile/native_shell/native_shell.dart';
import 'package:immich_mobile/native_shell/native_timeline_bridge.dart';
import 'package:immich_mobile/routing/router.dart';

/// Sends `AssetViewerRoute` to the native viewer. A guard, because five call sites
/// reach this route; and it *declines*, so Dart's stack has nothing new to mirror.
class NativeViewerGuard extends AutoRouteGuard {
  const NativeViewerGuard(this._timeline);

  final NativeTimelineBridge _timeline;

  @override
  void onNavigation(NavigationResolver resolver, StackRouter router) {
    final args = resolver.route.args;
    if (!NativeShell.isActive || args is! AssetViewerRouteArgs) {
      NativeShell.log('viewer guard: passing ${resolver.route.name} (args ${args.runtimeType})');
      resolver.next(true);
      return;
    }
    NativeShell.log('viewer guard: native viewer at ${args.initialIndex}');
    _timeline.openViewer(args.timelineService, args.initialIndex);
    resolver.next(false);
  }
}
