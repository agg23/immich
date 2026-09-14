import 'package:auto_route/auto_route.dart';
import 'package:immich_mobile/native_shell/native_shell.dart';
import 'package:immich_mobile/native_shell/native_timeline_bridge.dart';
import 'package:immich_mobile/routing/router.dart';

/// Sends `AssetViewerRoute` to the native viewer instead of Immich's.
///
/// A guard rather than an edit at each call site: the viewer is opened from a
/// timeline tile, a folder, a shared-link deep link, an activity comment and an
/// Android view intent, and every one of them ends at this route with the same
/// two pieces of information. Guards are also how this codebase already answers
/// "not this route, not right now" — [AuthGuard] and [DuplicateGuard] both stop
/// a navigation from exactly here.
///
/// The route is *declined*, not redirected. Nothing is pushed on Dart's stack,
/// so the mirror has nothing new to describe and the native viewer is a screen
/// that replaced a route rather than a route wearing native chrome.
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
