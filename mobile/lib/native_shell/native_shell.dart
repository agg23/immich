import 'dart:async';
import 'dart:io';
import 'dart:ui' show ImageByteFormat;

import 'package:auto_route/auto_route.dart';
import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:immich_mobile/native_shell/native_bar_registry.dart';
import 'package:immich_mobile/native_shell/native_icon.dart';
import 'package:immich_mobile/native_shell/native_shell_debug.dart';
import 'package:immich_mobile/routing/tabs.dart';

class NativeMenuItem {
  const NativeMenuItem({required this.label, this.icon, this.onPressed, this.destructive = false});

  final String label;

  /// Null means the icon vocabulary is short, and the whole bar falls back.
  final NativeIcon? icon;
  final VoidCallback? onPressed;
  final bool destructive;

  Map<String, Object?> describe() => {
    'label': label,
    if (icon != null) 'icon': icon!.name,
    'enabled': onPressed != null,
    if (destructive) 'destructive': true,
  };

  // `onPressed` is a fresh closure every build, so equality ignores it.
  @override
  bool operator ==(Object other) =>
      other is NativeMenuItem &&
      other.label == label &&
      other.icon == icon &&
      other.destructive == destructive &&
      (other.onPressed == null) == (onPressed == null);

  @override
  int get hashCode => Object.hash(label, icon, destructive, onPressed == null);
}

class NativeBarAction {
  const NativeBarAction({this.icon, this.label, this.onPressed, this.menu});

  final NativeIcon? icon;
  final String? label;
  final VoidCallback? onPressed;

  /// With a menu, the platform opens it and [onPressed] is never called.
  final List<NativeMenuItem>? menu;

  Map<String, Object?> describe() => {
    if (icon != null) 'icon': icon!.name,
    if (label != null) 'label': label,
    'enabled': menu != null || onPressed != null,
    if (menu != null) 'menu': [for (final item in menu!) item.describe()],
  };

  @override
  bool operator ==(Object other) =>
      other is NativeBarAction &&
      other.icon == icon &&
      other.label == label &&
      (other.onPressed == null) == (onPressed == null) &&
      listEquals(other.menu, menu);

  @override
  int get hashCode => Object.hash(icon, label, onPressed == null, Object.hashAll(menu ?? const []));
}

class NativeShell {
  static const _channel = MethodChannel('immich/shell');

  static bool get isActive => Platform.isIOS;

  /// A sync that crosses a tab tap names the *previous* tab; comparing against
  /// this is what stops it reversing the tap.
  static String _nativeTab = '';

  static TabsRouter? _tabsRouter;
  static RootStackRouter? _router;
  static bool _handlerInstalled = false;

  static Future<void>? _pendingPop;

  static final _shellRoutes = nativeShellRoutes;

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
    // Must land before `auth` flips the native root over to the shell.
    unawaited(
      _channel.invokeMethod('ready', {
        'tabs': [for (final tab in NativeTab.values) tab.describe()],
      }),
    );
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

  /// The stack a scripted push lands on, which is not always the root.
  static StackRouter? get debugActiveRouter => _activeRouter();

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
    final index = NativeTab.byId(tab)?.index;
    return tabs == null || index == null ? null : tabs.stackRouterOfIndex(index);
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
          _bars[data.name]?.describe(data.name) ??
              {'name': data.name, 'title': null, 'actions': const [], 'hero': false},
    ];
  }

  /// An `opaque: false` layer given a native frame plays both transitions at once.
  static final _overlayRoutes = <String>{};

  static bool get _overlayPresent {
    final stack = _activeStack().where((data) => !_shellRoutes.contains(data.name));
    return stack.isNotEmpty && _overlayRoutes.contains(stack.last.name);
  }

  static final _bars = NativeBarRegistry(onChanged: _syncAfterFrame);

  @visibleForTesting
  static NativeBarRegistry get bars => _bars;

  static void publishBar(
    String route, {
    required String title,
    required List<NativeBarAction> actions,
    bool hero = false,
  }) => _bars.publish(route, NativeBar(title: title, actions: actions, hero: hero));

  static void clearBar(String route) => _bars.clear(route);

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

  static Map<String, Object?>? _lastSync;

  static const _sameSync = DeepCollectionEquality();

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
    // Structural, not stringified: `Map.toString` is not a uniqueness contract.
    if (!force && _sameSync.equals(payload, _lastSync)) {
      return;
    }
    _lastSync = payload;
    log('sync $payload ${_where()}');
    if (claimTab) {
      _nativeTab = tab;
    }
    unawaited(_channel.invokeMethod('sync', payload));
  }

  /// A threshold, not a stream: the fade between the two states is native.
  static void setBarCollapsed(String route, {required bool collapsed}) {
    if (!isActive || !_bars.setCollapsed(route, collapsed: collapsed)) {
      return;
    }
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
      log('watching ${NativeTab.at(tabs.activeIndex)?.id} stack');
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
      default:
        if (!await NativeShellDebug.handle(call, router: _router, tabs: _tabsRouter)) {
          log('unhandled native call ${call.method}');
        }
    }
    return null;
  }

  static void _barAction(Map<String, Object?> args) {
    final route = args['route']! as String;
    final index = args['index']! as int;
    final item = args['item'] as int? ?? -1;
    final what = 'barAction $route #$index${item < 0 ? '' : ' row $item'}';
    final hit = _bars.resolve(route: route, index: index, item: item);
    if (hit == null) {
      log('$what: gone, re-syncing');
      syncStack(force: true);
      return;
    }
    log(what);
    NativeBarRegistry.handlerFor(hit)?.call();
  }

  static Future<Map<String, Object?>> _show(String? route) async {
    await _pendingPop;

    final tab = NativeTab.byId(route);
    log('show $route index=${tab?.index ?? -1} ${_where()}');
    if (tab != null) {
      final router = _tabsRouter;
      if (router == null) {
        log('asked for $route before the tab shell existed');
      } else {
        _nativeTab = tab.id;
        router.setActiveIndex(tab.index);
      }
    }

    await _renderedFrame();
    log('show $route settled showing=${surface()} ${_where()}');
    return {'surface': surface()};
  }

  static String _activeTab() => NativeTab.at(_tabsRouter?.activeIndex)?.id ?? '';

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
