import 'dart:async';
import 'dart:io';
import 'dart:ui' show ImageByteFormat;

import 'package:auto_route/auto_route.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:immich_mobile/generated/translations.g.dart';

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
/// One row of a native menu, reduced to what a `UIAction` can be made of.
class NativeMenuItem {
  const NativeMenuItem({required this.label, this.symbol, this.onPressed, this.destructive = false});

  final String label;

  /// An SF Symbol name. Unlike a bar button a menu row is legible without one,
  /// but Immich gives every row an icon, so a missing symbol means the table is
  /// short rather than that the row has no icon -- and the bar falls back.
  final String? symbol;
  final VoidCallback? onPressed;

  /// Drawn in red and pushed into its own section, which is what the Flutter
  /// menu spells with a `Divider` and a red `iconColor`.
  final bool destructive;

  Map<String, Object?> describe() => {
    'label': label,
    if (symbol != null) 'symbol': symbol,
    'enabled': onPressed != null,
    if (destructive) 'destructive': true,
  };
}

/// One app bar action, reduced to what a `UIBarButtonItem` can be made of.
///
/// Declared here rather than beside `NativeAppBar` so the bar widget can import
/// the shell without the shell importing it back.
class NativeBarAction {
  const NativeBarAction({this.symbol, this.label, this.onPressed, this.menu});

  /// An SF Symbol name; null for a text button.
  final String? symbol;
  final String? label;
  final VoidCallback? onPressed;

  /// When set, the button opens a `UIMenu` instead of firing. [onPressed] is
  /// then the Flutter menu's own trigger and is never called: UIKit opens the
  /// menu itself, with no tap to forward.
  final List<NativeMenuItem>? menu;

  Map<String, Object?> describe() => {
    if (symbol != null) 'symbol': symbol,
    if (label != null) 'label': label,
    'enabled': menu != null || onPressed != null,
    if (menu != null) 'menu': [for (final item in menu!) item.describe()],
  };
}

class NativeShell {
  static const _channel = MethodChannel('immich/shell');

  /// Compiled into this fork only. There is no runtime toggle: the native
  /// shell owns the window from `ShellSceneDelegate` outwards, so Flutter
  /// cannot decide at runtime that it wants the window back.
  static bool get isActive => Platform.isIOS;

  /// Names the native side uses, in `AutoTabsRouter`'s order.
  static const _tabs = ['photos', 'search', 'albums', 'library'];

  /// The tab the native side last said it had selected.
  ///
  /// A sync always names a tab, but naming one is not the same as asking for
  /// it. Most syncs are Dart reporting a stack that happens to belong to the
  /// current tab; only a few are Dart having changed the tab itself. Without
  /// the difference, a sync sent while a tab tap is still travelling to Dart
  /// arrives naming the *previous* tab and reverses the tap.
  ///
  /// Comparing against this separates the two: a tab that matches what native
  /// last announced is a report, and anything else is Dart asserting a change.
  static String _nativeTab = '';

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
  /// Resolved through [StaticTranslations] rather than held as literals. The
  /// mirror builds its frames without a `BuildContext`, and the titles still
  /// have to be the app's own: an English string table on the way to a native
  /// navigation bar would un-localise every page it touched.
  ///
  /// Only routes whose header carries nothing but a title belong here, and only
  /// where losing that header costs nothing. The five cover-photo pages used to
  /// be in this table and should never have been: their header is a 300pt Ken
  /// Burns crossfade over one of the user's own photos, and suppressing it threw
  /// the photo away to show a title that was already there. They publish a hero
  /// bar instead, which floats over the photo rather than replacing it — see
  /// [publishBar] and [setBarCollapsed]. What is left is a genuinely plain
  /// header.
  static final nativeTitledRoutes = <String, String Function(Translations t)>{
    'LocalAlbumsRoute': (t) => t.on_this_device,
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
    _unwatchStacks();
    _tabsRouter = tabsRouter;
    // A tab change moves the surface as surely as a push does, and not every
    // one of them comes from the native tab bar — Immich navigates to the
    // photos tab from several places. The router says so directly; the route
    // observer does not.
    tabsRouter.addListener(_onTabsChanged);
    _watchStacks();
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
    _unwatchStacks();
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
  static void log(String message) {
    // Not `kDebugMode`: the shell only runs at full speed in a profile build, so
    // the diagnostics have to survive one. Volume is a handful of lines per
    // navigation, not per frame.
    if (!kReleaseMode) {
      unawaited(_channel.invokeMethod('log', {'text': message}));
    }
  }

  /// A bar's actions as one string, for the sync signature.
  ///
  /// Menus are spelled out rather than counted, for the same reason the buttons
  /// carry their symbols: a menu whose rows changed but whose length did not is
  /// a menu that would keep firing the old callbacks.
  static String _describeActions(List<Object?> actions) => actions
      .map((raw) {
        final action = raw! as Map;
        final menu = action['menu'] as List?;
        final head = action['symbol'] ?? action['label'];
        return menu == null ? '$head' : '$head{${menu.map((i) => (i! as Map)['label']).join('/')}}';
      })
      .join('+');

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

  /// The stack belonging to a named tab, for instructions that name one.
  ///
  /// Addressed rather than active, for the reason every other message here is:
  /// a tab tap changes the native selection before Dart hears about it, so
  /// "the tab that is selected now" and "the tab this message is about" are not
  /// reliably the same tab.
  static StackRouter? _routerForTab(String tab) {
    final tabs = _tabsRouter;
    final index = _tabs.indexOf(tab);
    if (tabs == null || index < 0) {
      return null;
    }
    return tabs.stackRouterOfIndex(index);
  }

  /// Tapping the tab you are already on returns that tab to its root.
  ///
  /// Standard on iOS and UIKit does not do it for you — a re-tap of the
  /// selected tab is just a selection that did not change. Dart owns the stack,
  /// so it pops and the native side follows through the sync that results,
  /// which is the same path a back button takes and needs no second animation.
  static Future<void> _popToRoot(String tab) async {
    final router = _routerForTab(tab);
    if (router == null || router.stackData.length <= 1) {
      return;
    }
    log('popToRoot $tab depth=${router.stackData.length}');
    router.popUntilRoot();
    syncStack();
  }

  static List<Map<String, Object?>> _mirroredStack() {
    if (_router == null) {
      return const [];
    }
    return [
      for (final data in _activeStack())
        if (!_shellRoutes.contains(data.name) && !_overlayRoutes.contains(data.name))
          {
            'name': data.name,
            // A published bar wins: it carries the page's own title and its
            // actions. [nativeTitledRoutes] is the older mechanism, still
            // holding the sliver-shaped pages that have no [NativeAppBar] yet.
            'title': _bars[data.name]?.title ?? nativeTitledRoutes[data.name]?.call(StaticTranslations.instance),
            'actions': [for (final action in _bars[data.name]?.actions ?? const <NativeBarAction>[]) action.describe()],
            'hero': _bars[data.name]?.hero ?? false,
          },
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

  /// Native bars published by the pages currently mounted, keyed by route.
  ///
  /// A page's header is built by the page and can change with its state — the
  /// memories filter flips its own icon — so this is written on every build of
  /// a [NativeAppBar] and read when the stack is described. Cleared on dispose,
  /// because a frame that is gone must not keep a bar alive for the next route
  /// that happens to share its name.
  static final _bars = <String, ({String title, List<NativeBarAction> actions, bool hero})>{};

  /// [hero] marks a page whose header is a cover photo rather than chrome.
  /// Its bar floats over the page instead of sitting above it, so the native
  /// side draws it transparent and keeps the title back until the photo has
  /// scrolled away. See [setBarCollapsed].
  static void publishBar(
    String route, {
    required String title,
    required List<NativeBarAction> actions,
    bool hero = false,
  }) {
    final existing = _bars[route];
    if (existing != null &&
        existing.title == title &&
        existing.hero == hero &&
        _sameActions(existing.actions, actions)) {
      return;
    }
    _bars[route] = (title: title, actions: actions, hero: hero);
    _syncAfterFrame();
  }

  /// Open the native asset viewer over whatever is showing.
  ///
  /// Not a mirrored frame, and deliberately: `AssetViewerRoute` is intercepted
  /// by [NativeViewerGuard] and never pushed under the shell, so Dart's stack
  /// is the same before and after and [_mirroredStack] has nothing new to say.
  /// The alternative -- pushing the route and mirroring it -- would have had to
  /// reconcile a frame for a route that declares `opaque: false`, which is a
  /// layer over the page below rather than a frame on top of it.
  static void openViewer({required int session, required int index}) {
    unawaited(_channel.invokeMethod('openViewer', {'session': session, 'index': index}));
  }

  /// A page that kept its Flutter header, and what stopped it translating.
  static void logFallback(String route, String reason) => log('bar fallback $route: $reason');

  static void clearBar(String route) {
    _collapsed.remove(route);
    if (_bars.remove(route) != null) {
      _syncAfterFrame();
    }
  }

  /// Compared on what the native side can see. The callbacks are new closures
  /// on every build, so comparing those would resync on every frame.
  /// A menu changes with its page: an album gains "leave album" the moment it
  /// is shared, and the row that was at index 3 is now at index 4. A stale
  /// native menu would fire the wrong callback, so the rows are part of a bar's
  /// identity rather than decoration on it.
  static bool _sameMenu(List<NativeMenuItem>? a, List<NativeMenuItem>? b) {
    if (a == null || b == null) {
      return a == b;
    }
    if (a.length != b.length) {
      return false;
    }
    for (var i = 0; i < a.length; i++) {
      if (a[i].label != b[i].label ||
          a[i].symbol != b[i].symbol ||
          a[i].destructive != b[i].destructive ||
          (a[i].onPressed == null) != (b[i].onPressed == null)) {
        return false;
      }
    }
    return true;
  }

  static bool _sameActions(List<NativeBarAction> a, List<NativeBarAction> b) {
    if (a.length != b.length) {
      return false;
    }
    for (var i = 0; i < a.length; i++) {
      if (a[i].symbol != b[i].symbol ||
          a[i].label != b[i].label ||
          (a[i].onPressed == null) != (b[i].onPressed == null) ||
          !_sameMenu(a[i].menu, b[i].menu)) {
        return false;
      }
    }
    return true;
  }

  /// A bar is published from `didChangeDependencies`, which is inside a build.
  /// Sending from there would describe a stack that is still being built.
  static bool _syncScheduled = false;

  static void _syncAfterFrame() {
    if (_syncScheduled) {
      return;
    }
    _syncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _syncScheduled = false;
      syncStack(force: true);
    });
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
    _watchStacks();
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
    // Whether the native side should act on the tab or merely file it. See
    // [_nativeTab]: a tap that has not reached Dart yet must not be undone by a
    // sync that predates it.
    final claimTab = tab.isNotEmpty && tab != _nativeTab;
    final signature =
        '${stack.map((frame) => '${frame['name']}:${frame['title']}:${_describeActions(frame['actions']! as List)}${frame['hero']! as bool ? ':hero' : ''}').join(',')}'
        '|$showing|$overlay|$tab|$claimTab';
    if (!force && signature == _lastSync) {
      return;
    }
    _lastSync = signature;
    log('sync [$signature] ${_where()}');
    if (claimTab) {
      // Asserted once. Native applies it and the two sides agree from here, so
      // a later native tap is the only thing that moves the tab again.
      _nativeTab = tab;
    }
    unawaited(
      _channel.invokeMethod('sync', {
        'routes': stack,
        'surface': showing,
        'overlay': overlay,
        'tab': tab,
        'claimTab': claimTab,
      }),
    );
  }

  /// Which hero pages have their photo showing, so the same message is not
  /// sent twice on the way through a scroll.
  static final _collapsed = <String, bool>{};

  /// Tell the native bar whether the cover photo has scrolled away.
  ///
  /// A threshold rather than a stream. The bar has two states — transparent
  /// over the photo, opaque with a title once it has gone — so it only needs
  /// to hear about the crossing, and the fade between them is a native
  /// animation. Publishing the scroll offset every frame instead would put a
  /// hundred-odd platform messages a second behind one drag to say something
  /// the bar could not use.
  ///
  /// Not part of the sync: this changes while a page sits still on the stack,
  /// and rebuilding the whole mirrored stack to carry one bool would make a
  /// scroll gesture look like a routing event.
  static void setBarCollapsed(String route, {required bool collapsed}) {
    if (!isActive || _collapsed[route] == collapsed) {
      return;
    }
    _collapsed[route] = collapsed;
    log('bar $route ${collapsed ? 'collapsed' : 'expanded'}');
    unawaited(_channel.invokeMethod('barCollapsed', {'route': route, 'collapsed': collapsed}));
  }
  /// Reported by `NativeRouteObserver` for every routing change on any of
  /// Immich's navigators. What changed does not matter; the resulting stack
  /// does.
  ///
  static void didChangeRoutes() => syncStack();

  /// A push, where the `Route` itself is worth reading before the stack is.
  static void didPush(Route<dynamic> route) {
    final name = route.settings.name;
    if (name != null && route is TransitionRoute && !route.opaque) {
      _overlayRoutes.add(name);
    }
    syncStack();
  }

  static void _onTabsChanged() {
    // A tab that has just become current may have built its stack router for
    // the first time.
    _watchStacks();
    syncStack();
  }

  /// Every tab's stack router, so a push is heard from the router rather than
  /// from the `Navigator` over it.
  static final _stackRouters = <StackRouter>{};

  /// Subscribe to each tab's stack.
  ///
  /// `NativeRouteObserver` cannot be the only signal, and the reason is the
  /// shell's own arrangement: on the photos tab the Flutter surface is parked
  /// behind the native grid, so that tab's subtree is not rendering, so its
  /// nested `Navigator` has not been built — and an observer of a `Navigator`
  /// that does not exist hears nothing. A push made from a channel callback
  /// while that tab is front (a deep link, a share intent, the debug hook) then
  /// reached Dart's route stack and never reached the native one, with no way
  /// out: the sync creates the container, the container makes Flutter render,
  /// and rendering is what the missing sync was waiting for.
  ///
  /// The stack router notifies on its own, without a frame. [attach] already
  /// says this about the tabs router — "the router says so directly; the route
  /// observer does not" — and this is the same fact one level down.
  /// Called from every sync rather than once at [attach], because at attach
  /// time the tab shell is still being built and none of the nested routers
  /// exist yet — subscribing once there is subscribing to nothing. Cheap: a set
  /// lookup per sync, and only the active tab's, so a tab nobody has opened is
  /// not forced into existence to be listened to.
  static void _watchStacks() {
    final tabs = _tabsRouter;
    if (tabs == null) {
      return;
    }
    final stack = tabs.stackRouterOfIndex(tabs.activeIndex);
    if (stack != null && _stackRouters.add(stack)) {
      log('watching ${_tabs[tabs.activeIndex]} stack');
      stack.addListener(didChangeRoutes);
    }
  }

  /// Drop those subscriptions, for a tab shell that is going away.
  ///
  /// Signing out and back in builds a new `TabShellRoute`, and with it four
  /// new stack routers. Without this the old ones keep a listener into a
  /// shell that is now mirroring a different stack entirely.
  static void _unwatchStacks() {
    for (final stack in _stackRouters) {
      stack.removeListener(didChangeRoutes);
    }
    _stackRouters.clear();
  }

  static Future<void> _popFromNative(String? name) async {
    final router = _activeRouter();
    if (router == null) {
      return;
    }
    log('popFromNative $name before ${_where()}');
    final pop = _applyPop(router, name);
    _pendingPop = pop;
    try {
      await pop;
    } finally {
      if (_pendingPop == pop) {
        _pendingPop = null;
      }
      log('popFromNative $name after ${_where()}');
    }
  }

  static Future<void> _applyPop(StackRouter router, String? name) async {
    // A dialog or sheet is a pageless route: it is above the page in Dart and
    // has no native frame at all, while the native back button is chrome drawn
    // over the surface and stays tappable behind it. Close that rather than
    // pulling the page out from under it, and re-assert the stack so the frame
    // the native side just dropped comes back.
    if (router.hasPagelessTopRoute) {
      log('popFromNative $name over a pageless route: closing that instead');
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
      log('popFromNative $name but dart top is ${top?.name}: ignoring, re-syncing');
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
      log('no router to push $names onto');
      return;
    }
    for (final name in names.split(',')) {
      // By name rather than by path: the generated paths are derived from page
      // names and guessing them is how this went wrong the first time.
      log('debug push $name onto ${router.current.name}');
      // Not awaited: a route's future completes when it is *popped*. Wrapped
      // twice, because the two ways this can fail look identical from outside
      // and both are silent: `push` throws synchronously for a name the router
      // cannot resolve, and returns a failed future for one a guard refuses.
      // This hook spent an afternoon looking like a routing bug for want of
      // either message.
      try {
        unawaited(
          router
              .push(PageRouteInfo<void>(name))
              .then((_) {}, onError: (Object error) => log('debug push $name refused: $error')),
        );
      } catch (error) {
        log('debug push $name threw: $error');
      }
      await Future<void>.delayed(const Duration(milliseconds: 900));
      log('debug push $name left ${router.stackData.map((d) => d.name).join('/')}');
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
    if (call.method == 'debugTab') {
      // A tab change that starts in Dart, which is the direction the native
      // side had no way to hear about. Not routed through [_routerForTab]: the
      // point is to go through the app's own navigation, as 'view in timeline'
      // does.
      final tab = (call.arguments as Map)['tab']! as String;
      final index = _tabs.indexOf(tab);
      if (index >= 0) {
        log('debugTab $tab');
        _tabsRouter?.setActiveIndex(index);
        syncStack(force: true);
      }
      return null;
    }
    if (call.method == 'barAction') {
      final args = (call.arguments as Map).cast<String, Object?>();
      final route = args['route']! as String;
      final index = args['index']! as int;
      final actions = _bars[route]?.actions ?? const <NativeBarAction>[];
      if (index < 0 || index >= actions.length) {
        // The bar the tap was meant for is already gone. Re-assert rather than
        // firing whatever now sits at that index.
        log('barAction $route #$index but the bar has ${actions.length}');
        syncStack(force: true);
        return null;
      }
      final item = args['item'] as int? ?? -1;
      final menu = actions[index].menu;
      if (item < 0) {
        log('barAction $route #$index');
        actions[index].onPressed?.call();
        return null;
      }
      if (menu == null || item >= menu.length) {
        // The menu was rebuilt between opening and choosing. Firing whatever
        // now sits at that index is the one outcome worse than doing nothing.
        log('barAction $route #$index row $item but the menu has ${menu?.length}');
        syncStack(force: true);
        return null;
      }
      log('barAction $route #$index row $item (${menu[item].label})');
      menu[item].onPressed?.call();
      return null;
    }
    if (call.method == 'popToRoot') {
      await _popToRoot((call.arguments as Map)['tab']! as String);
      return null;
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
    log('show $route index=$index ${_where()}');
    if (index >= 0) {
      final router = _tabsRouter;
      if (router == null) {
        log('asked for $route before the tab shell existed');
      } else {
        // Native chose this tab, so a sync naming it is a report rather than a
        // request to change back.
        _nativeTab = route!;
        router.setActiveIndex(index);
      }
    }

    await _renderedFrame();
    log('show $route settled showing=${surface()} ${_where()}');
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
      return stack.last['name']! as String;
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
      log('capture: nothing to capture yet');
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
    log('capture ${data?.lengthInBytes} bytes in ${DateTime.now().difference(started).inMilliseconds}ms');
    return data?.buffer.asUint8List();
  }
}
