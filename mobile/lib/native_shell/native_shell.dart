import 'dart:async';
import 'dart:io';
import 'dart:ui' show ImageByteFormat;

import 'package:auto_route/auto_route.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

class NativeMenuItem {
  const NativeMenuItem({required this.label, this.symbol, this.onPressed, this.destructive = false});

  final String label;

  /// Null means the symbol table is short, and the whole bar falls back.
  final String? symbol;
  final VoidCallback? onPressed;
  final bool destructive;

  Map<String, Object?> describe() => {
    'label': label,
    if (symbol != null) 'symbol': symbol,
    'enabled': onPressed != null,
    if (destructive) 'destructive': true,
  };

  // `onPressed` is a fresh closure every build, so equality ignores it.
  @override
  bool operator ==(Object other) =>
      other is NativeMenuItem &&
      other.label == label &&
      other.symbol == symbol &&
      other.destructive == destructive &&
      (other.onPressed == null) == (onPressed == null);

  @override
  int get hashCode => Object.hash(label, symbol, destructive, onPressed == null);
}

class NativeBarAction {
  const NativeBarAction({this.symbol, this.label, this.onPressed, this.menu});

  final String? symbol;
  final String? label;
  final VoidCallback? onPressed;

  /// With a menu, UIKit opens it and [onPressed] is never called.
  final List<NativeMenuItem>? menu;

  Map<String, Object?> describe() => {
    if (symbol != null) 'symbol': symbol,
    if (label != null) 'label': label,
    'enabled': menu != null || onPressed != null,
    if (menu != null) 'menu': [for (final item in menu!) item.describe()],
  };

  @override
  bool operator ==(Object other) =>
      other is NativeBarAction &&
      other.symbol == symbol &&
      other.label == label &&
      (other.onPressed == null) == (onPressed == null) &&
      listEquals(other.menu, menu);

  @override
  int get hashCode => Object.hash(symbol, label, onPressed == null, Object.hashAll(menu ?? const []));
}

class NativeShell {
  static const _channel = MethodChannel('immich/shell');

  static bool get isActive => Platform.isIOS;

  static const _tabs = ['photos', 'search', 'albums', 'library'];

  /// A sync that crosses a tab tap names the *previous* tab; comparing against
  /// this is what stops it reversing the tap.
  static String _nativeTab = '';

  static TabsRouter? _tabsRouter;
  static RootStackRouter? _router;
  static bool _handlerInstalled = false;

  static Future<void>? _pendingPop;

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

  static void attach(TabsRouter tabsRouter) {
    if (!isActive || _tabsRouter == tabsRouter) {
      return;
    }
    _tabsRouter?.removeListener(_onTabsChanged);
    _unwatchStacks();
    _tabsRouter = tabsRouter;
    tabsRouter.addListener(_onTabsChanged);
    _watchStacks();
    if (!_handlerInstalled) {
      _handlerInstalled = true;
      _channel.setMethodCallHandler(_handle);
    }
    unawaited(_channel.invokeMethod('ready'));
    unawaited(_channel.invokeMethod('auth', {'signedIn': true}));
    syncStack(force: true);
  }

  static void detach() {
    if (!isActive) {
      return;
    }
    _tabsRouter?.removeListener(_onTabsChanged);
    _unwatchStacks();
    _tabsRouter = null;
    unawaited(_channel.invokeMethod('auth', {'signedIn': false}));
  }

  static void attachRouter(RootStackRouter router) {
    _router = router;
  }

  static RootStackRouter? get debugRouter => _router;

  static void log(String message) {
    // Not `kDebugMode`: the shell only runs at speed in a profile build.
    if (!kReleaseMode) {
      unawaited(_channel.invokeMethod('log', {'text': message}));
    }
  }

  static String _where() {
    final router = _router;
    if (router == null) {
      return 'no-router';
    }
    final root = router.stackData.map((d) => d.name).join(',');
    final segments = router.currentSegments.map((s) => s.name).join('/');
    return 'root=[$root] top=$segments tab=${_tabsRouter?.activeIndex}';
  }

  static List<RouteData> _activeStack() {
    final tabs = _tabsRouter;
    final nested = tabs?.stackRouterOfIndex(tabs.activeIndex);
    return [...?nested?.stackData, ...?_router?.stackData];
  }

  static StackRouter? _activeRouter() {
    final root = _router;
    if (root == null) {
      return null;
    }
    if (root.stackData.any((d) => !_shellRoutes.contains(d.name))) {
      return root;
    }
    final tabs = _tabsRouter;
    return tabs?.stackRouterOfIndex(tabs.activeIndex) ?? root;
  }

  static StackRouter? _routerForTab(String tab) {
    final tabs = _tabsRouter;
    final index = _tabs.indexOf(tab);
    return tabs == null || index < 0 ? null : tabs.stackRouterOfIndex(index);
  }

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
            'title': _bars[data.name]?.title,
            'actions': [for (final action in _bars[data.name]?.actions ?? const <NativeBarAction>[]) action.describe()],
            'hero': _bars[data.name]?.hero ?? false,
          },
    ];
  }

  /// An `opaque: false` layer given a native frame plays both transitions at once.
  static final _overlayRoutes = <String>{};

  static bool get _overlayPresent {
    final stack = _activeStack().where((data) => !_shellRoutes.contains(data.name));
    return stack.isNotEmpty && _overlayRoutes.contains(stack.last.name);
  }

  static final _bars = <String, ({String title, List<NativeBarAction> actions, bool hero})>{};

  static void publishBar(
    String route, {
    required String title,
    required List<NativeBarAction> actions,
    bool hero = false,
  }) {
    final existing = _bars[route];
    if (existing != null && existing.title == title && existing.hero == hero && listEquals(existing.actions, actions)) {
      return;
    }
    _bars[route] = (title: title, actions: actions, hero: hero);
    _syncAfterFrame();
  }

  static void clearBar(String route) {
    _collapsed.remove(route);
    if (_bars.remove(route) != null) {
      _syncAfterFrame();
    }
  }

  static void logFallback(String route, String reason) => log('bar fallback $route: $reason');

  static void openViewer({required int session, required int index}) {
    unawaited(_channel.invokeMethod('openViewer', {'session': session, 'index': index}));
  }

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

  static void syncStack({bool force = false}) {
    if (!isActive) {
      return;
    }
    _watchStacks();
    final tab = _activeTab();
    final claimTab = tab.isNotEmpty && tab != _nativeTab;
    final payload = {
      'routes': _mirroredStack(),
      'surface': surface(),
      'overlay': _overlayPresent,
      'tab': tab,
      'claimTab': claimTab,
    };
    final signature = payload.toString();
    if (!force && signature == _lastSync) {
      return;
    }
    _lastSync = signature;
    log('sync $signature ${_where()}');
    if (claimTab) {
      _nativeTab = tab;
    }
    unawaited(_channel.invokeMethod('sync', payload));
  }

  static final _collapsed = <String, bool>{};

  /// A threshold, not a stream: the fade between the two states is native.
  static void setBarCollapsed(String route, {required bool collapsed}) {
    if (!isActive || _collapsed[route] == collapsed) {
      return;
    }
    _collapsed[route] = collapsed;
    log('bar $route ${collapsed ? 'collapsed' : 'expanded'}');
    unawaited(_channel.invokeMethod('barCollapsed', {'route': route, 'collapsed': collapsed}));
  }

  static void didChangeRoutes() => syncStack();

  static void didPush(Route<dynamic> route) {
    final name = route.settings.name;
    if (name != null && route is TransitionRoute && !route.opaque) {
      _overlayRoutes.add(name);
    }
    syncStack();
  }

  static void _onTabsChanged() {
    _watchStacks();
    syncStack();
  }

  static final _stackRouters = <StackRouter>{};

  /// The photos tab's surface is parked behind the native grid, so its `Navigator`
  /// is never built and an observer of it would miss every push.
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
    if (router.hasPagelessTopRoute) {
      log('popFromNative $name over a pageless route: closing that instead');
      router.popTop();
      syncStack(force: true);
      return;
    }

    final top = router.stackData.lastOrNull;
    if (top == null || _shellRoutes.contains(top.name) || (name != null && name != top.name)) {
      // An unmatched pop reaches `TabShellPage`'s `PopScope`: `setActiveIndex(0)`.
      log('popFromNative $name but dart top is ${top?.name}: ignoring, re-syncing');
      syncStack(force: true);
      return;
    }

    // `pop`, never `maybePop`: that consults the `PopScope` above.
    router.pop();
  }

  static Future<void> _renderedFrame() async {
    final binding = WidgetsBinding.instance;
    for (var i = 0; i < 2; i++) {
      final frame = Completer<void>();
      binding.addPostFrameCallback((_) => frame.complete());
      // Nothing guarantees a frame is scheduled; an unchanged rebuild produces none.
      binding.scheduleFrame();
      await frame.future;
    }
  }

  static Future<void> _debugPush(String names) async {
    final router = _activeRouter();
    if (router == null) {
      log('no router to push $names onto');
      return;
    }
    for (final name in names.split(',')) {
      log('debug push $name onto ${router.current.name}');
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

  static final insets = ValueNotifier<EdgeInsets?>(null);

  static Future<dynamic> _handle(MethodCall call) async {
    final args = call.arguments as Map?;
    switch (call.method) {
      case 'insets':
        insets.value = EdgeInsets.only(
          top: (args!['top']! as num).toDouble(),
          bottom: (args['bottom']! as num).toDouble(),
          left: (args['left']! as num).toDouble(),
          right: (args['right']! as num).toDouble(),
        );
      case 'resync':
        syncStack(force: true);
      case 'capture':
        return _capture();
      case 'barAction':
        _barAction(args!.cast<String, Object?>());
      case 'popToRoot':
        await _popToRoot(args!['tab']! as String);
      case 'popFromNative':
        await _popFromNative(args?['name'] as String?);
      case 'show':
        return _show(args?['route'] as String?);

      case 'debugPush':
        await _debugPush(args!['name']! as String);
      case 'debugPop':
        await _router?.maybePopTop();
      case 'debugTab':
        final index = _tabs.indexOf(args!['tab']! as String);
        if (index >= 0) {
          _tabsRouter?.setActiveIndex(index);
          syncStack(force: true);
        }
    }
    return null;
  }

  static void _barAction(Map<String, Object?> args) {
    final route = args['route']! as String;
    final index = args['index']! as int;
    final item = args['item'] as int? ?? -1;
    final action = _bars[route]?.actions.elementAtOrNull(index);
    final row = item < 0 ? null : action?.menu?.elementAtOrNull(item);
    final what = 'barAction $route #$index${item < 0 ? '' : ' row $item'}';
    if (action == null || (item >= 0 && row == null)) {
      log('$what: gone, re-syncing');
      syncStack(force: true);
      return;
    }
    log(what);
    // Not `row?.onPressed ?? action.onPressed`: a disabled row would fall through.
    (row != null ? row.onPressed : action.onPressed)?.call();
  }

  static Future<Map<String, Object?>> _show(String? route) async {
    await _pendingPop;

    final index = route == null ? -1 : _tabs.indexOf(route);
    log('show $route index=$index ${_where()}');
    if (index >= 0) {
      final router = _tabsRouter;
      if (router == null) {
        log('asked for $route before the tab shell existed');
      } else {
        _nativeTab = route!;
        router.setActiveIndex(index);
      }
    }

    await _renderedFrame();
    log('show $route settled showing=${surface()} ${_where()}');
    return {'surface': surface()};
  }

  static String _activeTab() {
    final index = _tabsRouter?.activeIndex;
    return index == null || index < 0 || index >= _tabs.length ? '' : _tabs[index];
  }

  static String surface() => _mirroredStack().lastOrNull?['name'] as String? ?? _activeTab();

  static final captureKey = GlobalKey();

  static Future<Uint8List?> _capture() async {
    final boundary = captureKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
    if (boundary == null) {
      log('capture: nothing to capture yet');
      return null;
    }
    final started = DateTime.now();
    final image = await boundary.toImage();
    final data = await image.toByteData(format: ImageByteFormat.png);
    image.dispose();
    log('capture ${data?.lengthInBytes} bytes in ${DateTime.now().difference(started).inMilliseconds}ms');
    return data?.buffer.asUint8List();
  }
}
