import 'dart:async';
import 'dart:io';
import 'dart:ui' show ImageByteFormat;

import 'package:auto_route/auto_route.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

/// Dart's half of the native iOS shell.
///
/// The shell replaces `TabShellPage`'s bottom navigation with a real
/// `UITabBar` and its photos tab with a native grid. It deliberately does not
/// replace the routing: `TabShellRoute` still exists and still owns the four
/// tab routes, so every tab keeps the state it has today. The native tab bar
/// only chooses which of them is active, which is the same thing the Flutter
/// navigation bar did.
///
/// That is the cheapest arrangement that is still honest about the end state.
/// A native tab bar driving `router.replaceAll` per tab would be a smaller
/// diff and would silently throw away each tab's scroll position and provider
/// state on every switch, which would make the demo feel worse than the thing
/// it is meant to evaluate.
class NativeShell {
  static const _channel = MethodChannel('immich/shell');

  /// Compiled into this fork only. There is no runtime toggle: the native
  /// shell owns the window from `ShellSceneDelegate` outwards, so Flutter
  /// cannot decide at runtime that it wants the window back.
  static bool get isActive => Platform.isIOS;

  /// Names the native side uses, in `AutoTabsRouter`'s order.
  static const _tabs = ['photos', 'search', 'albums', 'library'];

  static TabsRouter? _tabsRouter;
  static bool _handlerInstalled = false;
  static RootStackRouter? _router;
  /// A pop the native side asked for and that has not finished applying.
  static Future<void>? _pendingPop;

  /// Routes that are the shell itself rather than something pushed on top of
  /// it. Pushing a native stack frame for these would mirror the tab bar into
  /// the navigation stack.
  static const _shellRoutes = {
    'SplashScreenRoute',
    'LoginRoute',
    'ChangePasswordRoute',
    'TabShellRoute',
    'PhotosTabRoute',
    'SearchTabRoute',
    'AlbumsTabRoute',
    'LibraryTabRoute',
    'MainTimelineRoute',
    'SearchRoute',
    'AlbumsRoute',
    'LibraryRoute',
  };

  /// Native titles for the routes where the Flutter page's own header has been
  /// suppressed, so the native navigation bar can show one instead.
  ///
  /// Short by design. Immich has 47 pages that each construct their own
  /// `appBar:` and no shared app bar widget to switch off, so every entry here
  /// is a page that had to be edited. That is the actual cost of native
  /// chrome on pushed routes, and it is why the rest keep their Flutter
  /// headers and get a hidden native bar.
  static const nativeTitledRoutes = <String, String>{
    'VideoRoute': 'Videos',
    'RecentlyAddedRoute': 'Recently Added',
  };

  /// Whether this route's Flutter header should be left out because the native
  /// bar is showing one. Read from the pages themselves.
  static bool suppressesAppBar(String routeName) => isActive && nativeTitledRoutes.containsKey(routeName);

  /// Called from `TabShellPage` once its `TabsRouter` exists.
  ///
  /// This is also the point where the shell learns it is signed in: reaching
  /// the tab shell means the auth guard let us through, so there is no second
  /// source of truth to keep in step.
  static void attach(TabsRouter tabsRouter) {
    if (!isActive) {
      return;
    }
    // `attach` comes from `build`, which runs whenever the tab shell rebuilds.
    // Only a genuinely new router is news for the native side.
    if (_tabsRouter == tabsRouter) {
      return;
    }
    _tabsRouter?.removeListener(_onTabsChanged);
    _tabsRouter = tabsRouter;
    // A tab change moves the surface as surely as a push does, and not every
    // one of them comes from the native tab bar — Immich navigates to the
    // photos tab from several places. The router says so directly; the route
    // observer does not.
    tabsRouter.addListener(_onTabsChanged);
    if (!_handlerInstalled) {
      _handlerInstalled = true;
      _channel.setMethodCallHandler(_handle);
    }
    unawaited(_channel.invokeMethod('ready'));
    unawaited(_channel.invokeMethod('auth', {'signedIn': true}));
    // A new tab shell means a new stack. Forced, because the signature of an
    // empty stack matches the last one sent and would otherwise be skipped.
    syncStack(force: true);
  }

  /// Called when the tab shell goes away — a logout, or the app dropping back
  /// to the login page.
  static void detach() {
    if (!isActive) {
      return;
    }
    _tabsRouter?.removeListener(_onTabsChanged);
    _tabsRouter = null;
    unawaited(_channel.invokeMethod('auth', {'signedIn': false}));
  }

  /// The root router, so a native pop has something to pop. Set from the app
  /// root, where the router is already being watched.
  static void attachRouter(RootStackRouter router) {
    _router = router;
  }

  /// For debug hooks that live elsewhere because they need something this class
  /// does not have — the asset viewer route needs a `TimelineService`.
  static RootStackRouter? get debugRouter => _router;

  /// Dart's diagnostics, sent to the native log rather than printed.
  ///
  /// `debugPrint` does not reach the device console, so a Dart-side routing
  /// event could not be lined up against the native event it raced with. Same
  /// channel as everything else, so the order in the log is the order the two
  /// sides actually saw.
  static void _log(String message) {
    // Not `kDebugMode`: the shell only runs at full speed in a profile build, so
    // the diagnostics have to survive one. Volume is a handful of lines per
    // navigation, not per frame.
    if (!kReleaseMode) {
      unawaited(_channel.invokeMethod('log', {'text': message}));
    }
  }

  /// Where Dart actually is, for the log. The two stacks can only be compared
  /// if both of them say what they think the truth is at the same moment.
  static String _where() {
    final router = _router;
    if (router == null) {
      return 'no-router';
    }
    final root = router.stackData.map((d) => d.name).join(',');
    final segments = router.currentSegments.map((s) => s.name).join('/');
    return 'root=[$root] top=$segments tab=${_tabsRouter?.activeIndex}';
  }

  /// The frames the native stack should be showing, in order.
  ///
  /// Every route Immich pushes lands on the *root* stack — the four tab
  /// children have no nested stacks of their own — so the mirrored stack is the
  /// root stack with the shell's own routes removed.
  /// The stack the native side mirrors: the active tab's, then anything still
  /// pushed on the root above the tab shell.
  ///
  /// Each tab is its own `AutoRouter` outlet now, so a push lands in the stack
  /// of the tab you are in and the other tabs keep theirs — which is what the
  /// per-tab `UINavigationController`s on the native side were always able to
  /// hold. Reading the root stack alone would report an empty stack for every
  /// tab and unmirror every pushed route.
  ///
  /// Root-level pushes are still appended, because a route that has not been
  /// moved under a tab covers the whole shell, and a route Dart is drawing that
  /// the native side does not know about is the surface mismatch this whole
  /// protocol exists to prevent.
  static List<RouteData> _activeStack() {
    final tabs = _tabsRouter;
    final nested = tabs?.stackRouterOfIndex(tabs.activeIndex);
    final root = _router?.stackData ?? const <RouteData>[];
    return [...?nested?.stackData, ...root];
  }

  /// The router a native pop or push acts on.
  ///
  /// Normally the active tab's, since that is where its stack lives. A route
  /// still declared at the root covers the whole shell, so while one of those is
  /// up it is the root that owns the top of the stack — the same order
  /// [_activeStack] reports.
  static StackRouter? _activeRouter() {
    final root = _router;
    if (root == null) {
      return null;
    }
    final rootHasPushed = root.stackData.any((d) => !_shellRoutes.contains(d.name));
    if (rootHasPushed) {
      return root;
    }
    final tabs = _tabsRouter;
    return tabs?.stackRouterOfIndex(tabs.activeIndex) ?? root;
  }

  static List<Map<String, String?>> _mirroredStack() {
    if (_router == null) {
      return const [];
    }
    return [
      for (final data in _activeStack())
        if (!_shellRoutes.contains(data.name) && !_overlayRoutes.contains(data.name))
          {'name': data.name, 'title': nativeTitledRoutes[data.name]},
    ];
  }

  /// Routes Flutter draws *over* the page below rather than in place of it.
  ///
  /// Learned, not listed. A route that declares `opaque: false` is a layer, not
  /// a stack frame: the asset viewer fades in over the page it was opened from,
  /// which keeps its own hero running underneath. Giving one of those a native
  /// frame plays both transitions at once — Flutter's fade inside a native
  /// slide, with the page underneath frozen mid-hero.
  ///
  /// Flutter already knows which routes these are, so the observer reads it off
  /// the `Route` instead of asking anyone to maintain a list. Immich has ~70
  /// routes; a list would be wrong within a month.
  static final _overlayRoutes = <String>{};

  /// Whether one of those is on top right now. The container holding the
  /// surface still owns the content underneath, but it has to get out of the
  /// way: a native navigation bar drawn over a full-screen viewer, or a
  /// swipe-back that pops the page the viewer was opened from.
  static bool get _overlayPresent {
    // The active tab's stack, for the same reason [_mirroredStack] reads it: the
    // root stack is just the tab shell now, so asking it what is on top answers
    // 'TabShellRoute' forever and no overlay is ever seen. That left the native
    // bar and the swipe-back live over a full-screen viewer — and a back press
    // there asks Dart to pop a route that is not its top, which Dart rightly
    // declines and re-asserts, so the frame native had already started popping
    // was pushed straight back in.
    final stack = _activeStack().where((data) => !_shellRoutes.contains(data.name));
    return stack.isNotEmpty && _overlayRoutes.contains(stack.last.name);
  }

  static String? _lastSync;

  /// Tell the native side what the stack *is*, rather than what changed.
  ///
  /// The mirror used to send "push one" and "pop one", which meant a message
  /// that was dropped, doubled or answered out of order left the two stacks
  /// permanently off by one — and every later pop then had no frame behind it.
  /// A whole-stack message is idempotent: the native side reconciles to it, so
  /// any drift is corrected by the next routing event instead of accumulating.
  /// It also matches the router being mirrored, which is declarative itself.
  static void syncStack({bool force = false}) {
    if (!isActive) {
      return;
    }
    final stack = _mirroredStack();
    final showing = surface();
    final overlay = _overlayPresent;
    // The surface and the overlay are part of the signature, not just the
    // stack: switching tabs, or opening a viewer over the page, leaves the
    // mirrored stack identical and still changes what has to happen natively.
    // The tab is part of the signature and part of the payload: a sync says
    // what *that tab's* stack is, and the native side has to apply it to that
    // tab. Reconciling into whichever tab happens to be selected is how a stack
    // described for the tab you left got pushed into the tab you entered.
    final tab = _activeTab();
    final signature = '${stack.map((frame) => frame['name']).join(',')}|$showing|$overlay|$tab';
    if (!force && signature == _lastSync) {
      return;
    }
    _lastSync = signature;
    _log('sync [$signature] ${_where()}');
    unawaited(_channel.invokeMethod('sync', {'routes': stack, 'surface': showing, 'overlay': overlay, 'tab': tab}));
  }

  /// Reported by `NativeRouteObserver` for every routing change on any of
  /// Immich's navigators. What changed does not matter; the resulting stack
  /// does.
  static void didChangeRoutes() => syncStack();

  /// A push, where the `Route` itself is worth reading before the stack is.
  static void didPush(Route<dynamic> route) {
    final name = route.settings.name;
    if (name != null && route is TransitionRoute && !route.opaque) {
      _overlayRoutes.add(name);
    }
    syncStack();
  }

  static void _onTabsChanged() => syncStack();

  static Future<void> _popFromNative(String? name) async {
    final router = _activeRouter();
    if (router == null) {
      return;
    }
    _log('popFromNative $name before ${_where()}');
    final pop = _applyPop(router, name);
    _pendingPop = pop;
    try {
      await pop;
    } finally {
      if (_pendingPop == pop) {
        _pendingPop = null;
      }
      _log('popFromNative $name after ${_where()}');
    }
  }

  static Future<void> _applyPop(StackRouter router, String? name) async {
    // A dialog or sheet is a pageless route: it is above the page in Dart and
    // has no native frame at all, while the native back button is chrome drawn
    // over the surface and stays tappable behind it. Close that rather than
    // pulling the page out from under it, and re-assert the stack so the frame
    // the native side just dropped comes back.
    if (router.hasPagelessTopRoute) {
      _log('popFromNative $name over a pageless route: closing that instead');
      router.popTop();
      syncStack(force: true);
      return;
    }

    final stack = router.stackData;
    final top = stack.isEmpty ? null : stack.last;
    if (top == null || _shellRoutes.contains(top.name) || (name != null && name != top.name)) {
      // The native side dismissed a frame Dart does not have on top. Popping
      // *something* here is exactly how this went wrong: an unmatched pop
      // reached `TabShellPage`'s `PopScope`, whose callback is
      // `setActiveIndex(0)`, and the whole app quietly moved to the photos tab
      // with nothing on screen explaining why. Say so, and re-assert instead.
      _log('popFromNative $name but dart top is ${top?.name}: ignoring, re-syncing');
      syncStack(force: true);
      return;
    }

    // `pop`, never `maybePop`. `maybePop` consults `PopScope`, which is how an
    // unmatched pop became a tab switch; and `maybePopTop` resolves to the
    // innermost router, which for an empty stack is the `TabsRouter`.
    router.pop();
  }

  /// A frame that has been built and handed to the rasteriser.
  ///
  /// `show` answers only after this, because the native side uses the reply to
  /// decide when to take down the still it is holding over the surface. A
  /// reply on delivery would take it down before there was anything correct
  /// behind it, which is the flash it exists to prevent.
  static Future<void> _renderedFrame() async {
    final binding = WidgetsBinding.instance;
    for (var i = 0; i < 2; i++) {
      final frame = Completer<void>();
      binding.addPostFrameCallback((_) => frame.complete());
      // Nothing guarantees a frame is already scheduled — a tab that is
      // rebuilt to the state it was already in produces no work.
      binding.scheduleFrame();
      await frame.future;
    }
  }

  /// `-immichShellPushRoute <RouteName>[,<RouteName>]` asks Dart to push
  /// routes, so the whole mirror — Dart push, native frame, native pop, Dart
  /// pop — can be exercised without a pointer. Comma-separated names stack on
  /// each other, which is the case where a frame disappears because something
  /// covered it rather than because it was popped. Named routes only; anything
  /// taking an argument would need the argument too.
  static Future<void> _debugPush(String names) async {
    // The active tab's router: pushable routes are declared under each tab now,
    // so the root cannot resolve them by name.
    final router = _activeRouter();
    if (router == null) {
      _log('no router to push $names onto');
      return;
    }
    for (final name in names.split(',')) {
      // By name rather than by path: the generated paths are derived from page
      // names and guessing them is how this went wrong the first time.
      _log('debug push $name');
      // Not awaited: a route's future completes when it is *popped*.
      unawaited(router.push(PageRouteInfo<void>(name)));
      await Future<void>.delayed(const Duration(milliseconds: 900));
    }
  }

  /// What the native shell is covering, in logical pixels.
  ///
  /// Applied over `MediaQuery.padding` for the whole app, so every page that
  /// lays out against `context.padding` — which in Immich is most of them —
  /// stays clear of the native navigation bar and tab bar without knowing
  /// they exist.
  static final insets = ValueNotifier<EdgeInsets?>(null);

  static Future<dynamic> _handle(MethodCall call) async {
    if (call.method == 'insets') {
      final args = (call.arguments as Map).cast<String, Object?>();
      insets.value = EdgeInsets.only(
        top: (args['top']! as num).toDouble(),
        bottom: (args['bottom']! as num).toDouble(),
        left: (args['left']! as num).toDouble(),
        right: (args['right']! as num).toDouble(),
      );
      return null;
    }
    if (call.method == 'debugPush') {
      await _debugPush((call.arguments as Map)['name']! as String);
      return null;
    }
    if (call.method == 'debugPop') {
      // A pop that starts in Dart, as a back button inside a Flutter page
      // would. The native stack should follow without popping twice.
      await _router?.maybePopTop();
      return null;
    }
    if (call.method == 'resync') {
      syncStack(force: true);
      return null;
    }
    if (call.method == 'capture') {
      return _capture();
    }
    if (call.method == 'popFromNative') {
      await _popFromNative((call.arguments as Map?)?['name'] as String?);
      return null;
    }
    if (call.method != 'show') {
      return null;
    }

    // A pop requested moments ago may still be applying. The native container
    // that is being returned to claims the surface on its way in and asks for
    // this route immediately, so answering before the pop has landed would
    // report the outgoing page as settled.
    await _pendingPop;

    final route = (call.arguments as Map?)?['route'] as String?;
    final index = route == null ? -1 : _tabs.indexOf(route);
    // The launch container names no route, and the photos tab is native, so
    // neither reaches a Flutter tab.
    _log('show $route index=$index ${_where()}');
    if (index >= 0) {
      final router = _tabsRouter;
      if (router == null) {
        _log('asked for $route before the tab shell existed');
      } else {
        router.setActiveIndex(index);
      }
    }

    await _renderedFrame();
    _log('show $route settled showing=${surface()} ${_where()}');
    // What Dart is *actually* rendering, which is not the same question as
    // which tab is active: a route pushed above the tab shell covers all four.
    // The native side reveals its surface on this answer, so answering "the tab
    // you asked for" while a pushed route is on top is what put Videos in the
    // Search slot for the length of a swipe-back.
    return {'surface': surface()};
  }

  /// The one thing Dart is drawing, named so the native side can tell whether
  /// the container holding the surface is the right one.
  ///
  /// A pushed route wins over the tab, because it covers the tab shell.
  /// The tab a sync describes, so the native side can apply it to that tab
  /// rather than to whichever one is selected when the message lands.
  static String _activeTab() {
    final index = _tabsRouter?.activeIndex;
    if (index == null || index < 0 || index >= _tabs.length) {
      return '';
    }
    return _tabs[index];
  }

  static String surface() {
    final stack = _mirroredStack();
    if (stack.isNotEmpty) {
      return stack.last['name']!;
    }
    final index = _tabsRouter?.activeIndex;
    if (index == null || index < 0 || index >= _tabs.length) {
      return '';
    }
    return _tabs[index];
  }

  /// Wraps the app so Flutter can hand out a picture of what it is drawing.
  ///
  /// UIKit cannot photograph a Flutter surface: `snapshotView` answers nil for
  /// a Metal layer with nothing committed, and forcing the commit aborts the
  /// process from `_associatedViewControllerForwardsAppearanceCallbacks`. So
  /// Flutter takes the picture instead, and the native side holds it over a
  /// container whose content has moved elsewhere — during an interactive
  /// swipe-back, that still *is* the page being revealed.
  static final captureKey = GlobalKey();

  static Future<Uint8List?> _capture() async {
    final boundary = captureKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
    if (boundary == null) {
      _log('capture: nothing to capture yet');
      return null;
    }
    final started = DateTime.now();
    // Logical pixels, not device pixels: the still is stretched over a
    // container of exactly this size and is on screen for a few hundred
    // milliseconds, so three times the pixels would be three times the cost for
    // nothing.
    final image = await boundary.toImage();
    final data = await image.toByteData(format: ImageByteFormat.png);
    image.dispose();
    _log('capture ${data?.lengthInBytes} bytes in ${DateTime.now().difference(started).inMilliseconds}ms');
    return data?.buffer.asUint8List();
  }
}
