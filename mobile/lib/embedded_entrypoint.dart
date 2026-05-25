import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui';

import 'package:auto_route/auto_route.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/platform/embedded_ui_api.g.dart' as embedded;
import 'package:immich_mobile/providers/auth.provider.dart';
import 'package:immich_mobile/providers/api.provider.dart';
import 'package:immich_mobile/providers/background_sync.provider.dart';
import 'package:immich_mobile/providers/infrastructure/db.provider.dart';
import 'package:immich_mobile/providers/infrastructure/metadata.provider.dart';
import 'package:immich_mobile/providers/locale_provider.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';
import 'package:immich_mobile/providers/server_info.provider.dart';
import 'package:immich_mobile/providers/theme.provider.dart';
import 'package:immich_mobile/providers/user.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_mobile/services/api.service.dart';
import 'package:immich_mobile/theme/theme_data.dart';
import 'package:immich_mobile/utils/bootstrap.dart';
import 'package:immich_mobile/utils/cache/widgets_binding.dart';
import 'package:immich_mobile/utils/image_url_builder.dart';
import 'package:immich_mobile/utils/migration.dart';
import 'package:immich_mobile/widgets/common/embedded_scope.dart';
import 'package:immich_mobile/wm_executor.dart';
import 'package:immich_ui/immich_ui.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:logging/logging.dart';

final _embeddedLog = Logger('EmbeddedUI');

void _embeddedDebug(String message) {
  debugPrint('[EmbeddedUI] $message');
}

@pragma('vm:entry-point')
void embeddedForegroundEntrypoint() {
  runZonedGuarded(() async {
    try {
      _embeddedDebug('Dart embedded entrypoint starting');
      ImmichWidgetsBinding();
      DartPluginRegistrant.ensureInitialized();
      await EasyLocalization.ensureInitialized();
      final (drift, _) = await Bootstrap.initDomain();
      await initializeDateFormatting();
      await workerManagerPatch.init(dynamicSpawning: true, isolatesCount: max(Platform.numberOfProcessors - 1, 5));
      _embeddedDebug('Worker manager initialized for embedded entrypoint');
      await migrateDatabaseIfNeeded(drift);

      final locale = locales.values.first;
      final container = ProviderContainer(
        overrides: [driftProvider.overrideWith(driftOverride(drift)), localeProvider.overrideWithValue(locale)],
      );

      final restoreError = await _tryRestoreEmbeddedSession(container);
      final initialSync = _runEmbeddedInitialSync(container, restoreError: restoreError);
      _embeddedDebug(
        'Embedded restore complete restoreError=${restoreError == null ? "none" : restoreError.runtimeType}',
      );

      final appRouter = _createEmbeddedRouter();
      final routeObserver = _EmbeddedRouteObserver();
      routeObserver.attach(appRouter);
      final controller = _EmbeddedFlutterController(router: appRouter, routeObserver: routeObserver);
      embedded.EmbeddedFlutterApi.setUp(controller);
      embedded.TimelineFlutterApi.setUp(
        _EmbeddedTimelineController(container, restoreError: restoreError, initialSync: initialSync),
      );

      container.listen(
        authProvider.select((state) => state.isAuthenticated),
        (_, isAuthenticated) => unawaited(_notifyAuthChanged(isAuthenticated)),
        fireImmediately: false,
      );

      runApp(
        UncontrolledProviderScope(
          container: container,
          child: _EmbeddedRoot(
            appRouter: appRouter,
            routeObserver: routeObserver,
            locale: locale,
            restoreError: restoreError,
          ),
        ),
      );

      await embedded.EmbeddedHostApi().onFlutterReady();
    } catch (error, stack) {
      _embeddedLog.severe('Failed to bootstrap embedded foreground entrypoint', error, stack);
      runApp(_EmbeddedBootstrapError(error: error, stack: stack));
      await _notifyFlutterReady();
    }
  }, (error, stack) => _embeddedLog.severe('Uncaught embedded foreground error', error, stack));
}

Future<void> _notifyFlutterReady() async {
  try {
    await embedded.EmbeddedHostApi().onFlutterReady();
  } catch (error, stack) {
    _embeddedLog.warning('Unable to notify native host that embedded Flutter is ready', error, stack);
  }
}

Future<void> _notifyAuthChanged(bool isAuthenticated) async {
  try {
    await embedded.EmbeddedHostApi().onAuthChanged(isAuthenticated);
  } catch (error, stack) {
    _embeddedLog.warning('Unable to notify native host about auth change', error, stack);
  }
}

RootStackRouter _createEmbeddedRouter() {
  return RootStackRouter.build(
    routes: [
      NamedRouteDef(
        name: _EmbeddedBlankRoute.name,
        path: '/',
        builder: (_, _) => const _EmbeddedBlankPage(),
        initial: true,
      ),
      ..._embeddedAllowedRoutes,
      RedirectRoute(path: '*', redirectTo: '/'),
    ],
  );
}

final _embeddedAllowedRoutes = [
  CustomRoute(
    page: SettingsRoute.page,
    transitionsBuilder: TransitionsBuilders.noTransition,
    duration: Duration.zero,
    reverseDuration: Duration.zero,
  ),
  AutoRoute(page: LoginRoute.page),
  AutoRoute(page: ChangePasswordRoute.page),
  AutoRoute(page: TabShellRoute.page),
  AutoRoute(page: SettingsSubRoute.page),
  AutoRoute(page: SyncStatusRoute.page),
];

class _EmbeddedBlankRoute extends PageRouteInfo<void> {
  const _EmbeddedBlankRoute() : super(name);

  static const name = 'EmbeddedBlankRoute';
}

class _EmbeddedBlankPage extends StatelessWidget {
  const _EmbeddedBlankPage();

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

class _EmbeddedFlutterController extends embedded.EmbeddedFlutterApi {
  _EmbeddedFlutterController({required this.router, required this.routeObserver});

  final RootStackRouter router;
  final _EmbeddedRouteObserver routeObserver;

  @override
  Future<void> navigateTo(String routeName, Map<String, Object?> args) async {
    final route = _routeFromEmbeddedRequest(routeName, args);
    await router.replaceAll(
      [route],
      updateExistingRoutes: false,
      onFailure: (failure) => _embeddedLog.severe('Embedded navigation to $routeName failed: $failure'),
    );
    routeObserver.notifyRouteState();
  }

  @override
  Future<bool> maybePop() async {
    if (!router.canPop(ignoreParentRoutes: true)) {
      routeObserver.notifyRouteState();
      return false;
    }

    await router.maybePop();
    routeObserver.notifyRouteState();
    return true;
  }

  @override
  Future<void> resetToRoot() async {
    await router.replaceAll(
      [const _EmbeddedBlankRoute()],
      updateExistingRoutes: false,
      onFailure: (failure) => _embeddedLog.severe('Embedded reset failed: $failure'),
    );
    routeObserver.notifyRouteState();
  }

  @override
  void setEmbeddedMode(bool hideChrome) {
    EmbeddedScopeController.instance.hideChrome.value = hideChrome;
  }
}

PageRouteInfo _routeFromEmbeddedRequest(String routeName, Map<String, Object?> args) {
  if (args.isNotEmpty) {
    throw PlatformException(
      code: 'embedded-route-args-unsupported',
      message: 'Embedded route $routeName does not support prototype arguments: $args',
    );
  }

  return switch (routeName) {
    '/settings' => const SettingsRoute(),
    '/login' => const LoginRoute(),
    _ => throw PlatformException(
      code: 'embedded-route-not-allowed',
      message: 'Embedded Flutter route is not allowlisted: $routeName',
    ),
  };
}

class _EmbeddedRouteObserver extends AutoRouterObserver {
  _EmbeddedRouteObserver();

  static _EmbeddedRouteObserver? _current;

  String? _lastTitle;
  bool? _lastCanPop;
  bool _hasPendingNotification = false;

  void attach(RootStackRouter router) {
    _current = this;
    _attachedRouter = router;
    router.addListener(notifyRouteState);
  }

  @override
  void didPush(Route route, Route? previousRoute) {
    notifyRouteState();
  }

  @override
  void didPop(Route route, Route? previousRoute) {
    notifyRouteState();
  }

  @override
  void didRemove(Route route, Route? previousRoute) {
    notifyRouteState();
  }

  @override
  void didChangeTabRoute(TabPageRoute route, TabPageRoute previousRoute) {
    notifyRouteState();
  }

  @override
  void didInitTabRoute(TabPageRoute route, TabPageRoute? previousRoute) {
    notifyRouteState();
  }

  @override
  void didReplace({Route? newRoute, Route? oldRoute}) {
    notifyRouteState();
  }

  void notifyRouteState() {
    if (_hasPendingNotification) {
      return;
    }
    _hasPendingNotification = true;
    scheduleMicrotask(_sendRouteState);
  }

  void _sendRouteState() {
    _hasPendingNotification = false;
    final router = _currentRouter;
    if (router == null || !router.hasEntries) {
      _send(canPop: false, title: '');
      return;
    }

    final topRoute = router.topRoute;
    _send(canPop: router.canPop(ignoreParentRoutes: true), title: _titleFor(topRoute));
  }

  RootStackRouter? get _currentRouter => _current == this ? _attachedRouter : null;

  RootStackRouter? _attachedRouter;

  void _send({required bool canPop, required String title}) {
    if (_lastCanPop == canPop && _lastTitle == title) {
      return;
    }

    _lastCanPop = canPop;
    _lastTitle = title;
    unawaited(_notifyRouteStateChanged(canPop: canPop, title: title));
  }
}

String _titleFor(RouteData routeData) {
  return switch (routeData.name) {
    SettingsSubRoute.name => (routeData.argsAs<SettingsSubRouteArgs>().section.title).tr(),
    SyncStatusRoute.name => 'sync_status'.tr(),
    LoginRoute.name => 'login'.tr(),
    ChangePasswordRoute.name => 'change_password'.tr(),
    TabShellRoute.name => '',
    SettingsRoute.name => 'settings'.tr(),
    _EmbeddedBlankRoute.name => '',
    _ => routeData.name,
  };
}

Future<void> _notifyRouteStateChanged({required bool canPop, required String title}) async {
  try {
    await embedded.EmbeddedHostApi().onRouteStateChanged(canPop, title);
  } catch (error, stack) {
    _embeddedLog.warning('Unable to notify native host about embedded route state', error, stack);
  }
}

class _EmbeddedTimelineController extends embedded.TimelineFlutterApi {
  _EmbeddedTimelineController(this.container, {required this.restoreError, required this.initialSync});

  final ProviderContainer container;
  final Object? restoreError;
  final Future<void> initialSync;

  @override
  Future<List<embedded.TimelineBucket>> loadBuckets() async {
    final (service, users) = await _readReadyTimelineService();
    final buckets = await _readInitialBuckets(service, users);
    final totalAssets = buckets.fold<int>(0, (total, bucket) => total + bucket.assetCount);
    final message =
        'Native timeline loadBuckets users=${users.length} buckets=${buckets.length} totalAssets=$totalAssets serviceTotal=${service.totalAssets}';
    _embeddedLog.info(message);
    _embeddedDebug(message);
    var offset = 0;
    return [
      for (final bucket in buckets)
        embedded.TimelineBucket(
          offset: offset,
          count: bucket.assetCount,
          epochMilliseconds: bucket is TimeBucket ? bucket.date.millisecondsSinceEpoch : null,
        )..also((_) => offset += bucket.assetCount),
    ];
  }

  @override
  Future<List<embedded.AssetMeta>> loadAssets(int offset, int count) async {
    final (service, users) = await _readReadyTimelineService();
    await _waitForTimelineTotal(service, offset + count);
    final assets = await service.loadAssets(offset, count);
    final message =
        'Native timeline loadAssets users=${users.length} offset=$offset count=$count returned=${assets.length}';
    _embeddedLog.info(message);
    _embeddedDebug(message);
    return assets.map(_toAssetMeta).toList(growable: false);
  }

  @override
  Future<embedded.ServerConfig> serverConfig() async {
    _ensureTimelineReady();
    return embedded.ServerConfig(
      endpoint: Store.get(StoreKey.serverEndpoint),
      token: Store.get(StoreKey.accessToken),
      customHeaders: ApiService.getRequestHeaders(),
    );
  }

  @override
  void setFavorite(List<String> ids, bool value) {
    _embeddedLog.info('Native timeline favorite request outside minimal grid scope: ${ids.length} assets');
  }

  @override
  Future<String> thumbnailUrl(String assetId, String? thumbhash, bool edited) async {
    _ensureTimelineReady();
    final url = getThumbnailUrlForRemoteId(assetId, thumbhash: thumbhash, edited: edited);
    _embeddedLog.fine('Native timeline thumbnailUrl assetId=$assetId edited=$edited hasThumbhash=${thumbhash != null}');
    return url;
  }

  @override
  void delete(List<String> ids) {
    _embeddedLog.info('Native timeline delete request outside minimal grid scope: ${ids.length} assets');
  }

  Future<(TimelineService, List<String>)> _readReadyTimelineService() async {
    _ensureTimelineReady();
    await _waitForInitialSync();
    final users = await container.read(timelineUsersProvider.future);
    if (users.isEmpty) {
      _embeddedLog.warning('Native timeline users resolved to an empty list');
    }
    return (container.read(timelineServiceProvider), users);
  }

  Future<void> _waitForInitialSync() async {
    try {
      await initialSync.timeout(const Duration(seconds: 10));
    } on TimeoutException {
      _embeddedLog.warning('Native timeline initial sync wait timed out; loading current database snapshot');
    }
  }

  Future<List<Bucket>> _readInitialBuckets(TimelineService service, List<String> users) async {
    final buckets = await service.watchBuckets().first;
    final totalAssets = buckets.fold<int>(0, (total, bucket) => total + bucket.assetCount);

    if (totalAssets > 0 || users.isEmpty) {
      return buckets;
    }

    _embeddedLog.info('Native timeline first bucket emission was empty for ${users.length} users; waiting briefly');
    try {
      return await service
          .watchBuckets()
          .firstWhere((buckets) {
            return buckets.fold<int>(0, (total, bucket) => total + bucket.assetCount) > 0;
          })
          .timeout(const Duration(seconds: 2));
    } on TimeoutException {
      _embeddedLog.info('Native timeline bucket wait timed out; treating empty timeline as final for now');
      return buckets;
    }
  }

  void _ensureTimelineReady() {
    final isAuthenticated = container.read(authProvider).isAuthenticated;
    final currentUser = container.read(currentUserProvider);

    if (isAuthenticated && currentUser != null) {
      return;
    }

    final restoreError = this.restoreError;
    if (restoreError != null) {
      throw PlatformException(
        code: 'embedded-timeline-auth-unavailable',
        message: 'Native timeline requires a restored Immich login. Embedded session restore failed: $restoreError',
      );
    }

    throw PlatformException(
      code: 'embedded-timeline-auth-unavailable',
      message: 'Native timeline requires authenticated embedded provider state.',
    );
  }
}

Future<void> _waitForTimelineTotal(TimelineService service, int minimumTotal) async {
  if (minimumTotal <= 0 || service.totalAssets >= minimumTotal) {
    return;
  }

  for (var attempt = 0; attempt < 20; attempt++) {
    await Future<void>.delayed(const Duration(milliseconds: 25));
    if (service.totalAssets >= minimumTotal) {
      return;
    }
  }

  _embeddedLog.warning(
    'Native timeline service totalAssets=${service.totalAssets} did not reach requested minimum=$minimumTotal before loadAssets',
  );
}

extension _Also<T> on T {
  T also(void Function(T value) action) {
    action(this);
    return this;
  }
}

embedded.AssetMeta _toAssetMeta(BaseAsset asset) {
  return embedded.AssetMeta(
    id: asset.remoteId ?? asset.localId ?? asset.heroTag,
    remoteId: asset.remoteId,
    localId: asset.localId,
    createdAtEpochMilliseconds: asset.createdAt.millisecondsSinceEpoch,
    isFavorite: asset.isFavorite,
    isVideo: asset.isVideo,
    isEdited: asset.isEdited,
    thumbhash: asset is RemoteAsset ? asset.thumbHash : null,
  );
}

Future<Object?> _tryRestoreEmbeddedSession(ProviderContainer container) async {
  try {
    _embeddedDebug('Restoring embedded session');
    await _restoreEmbeddedSession(container);
    _embeddedDebug('Embedded session restore succeeded');
    return null;
  } catch (error, stack) {
    _embeddedLog.warning('Embedded session restore failed; continuing unauthenticated for prototype', error, stack);
    _embeddedDebug('Embedded session restore failed: $error');
    return error;
  }
}

Future<void> _runEmbeddedInitialSync(ProviderContainer container, {required Object? restoreError}) async {
  if (restoreError != null || !container.read(authProvider).isAuthenticated) {
    _embeddedLog.info('Skipping embedded initial sync because auth is unavailable');
    _embeddedDebug('Skipping embedded initial sync because auth is unavailable');
    return;
  }

  try {
    final serverVersion = await container.read(apiServiceProvider).serverInfoApi.getServerVersion();
    _embeddedDebug(
      'Embedded pre-sync serverVersion=${serverVersion == null ? "<null>" : "${serverVersion.major}.${serverVersion.minor}.${serverVersion.patch_}"}',
    );
    _embeddedLog.info('Starting embedded initial remote sync');
    _embeddedDebug('Starting embedded initial remote sync');
    final syncSuccess = await container.read(backgroundSyncProvider).syncRemote();
    _embeddedLog.info('Embedded initial remote sync completed success=$syncSuccess');
    _embeddedDebug('Embedded initial remote sync completed success=$syncSuccess');
  } catch (error, stack) {
    _embeddedLog.warning(
      'Embedded initial remote sync failed; native timeline will use current database snapshot',
      error,
      stack,
    );
    _embeddedDebug('Embedded initial remote sync failed: $error');
  }
}

Future<void> _restoreEmbeddedSession(ProviderContainer container) async {
  final serverUrl = Store.tryGet(StoreKey.serverUrl);
  final endpoint = Store.tryGet(StoreKey.serverEndpoint);
  final accessToken = Store.tryGet(StoreKey.accessToken);

  if (serverUrl == null || endpoint == null || accessToken == null) {
    throw StateError(
      'Missing stored Immich login. Run the normal Flutter app and log in before using the SwiftUI prototype.',
    );
  }

  _embeddedDebug('Embedded restore has stored endpoint=${endpoint.isNotEmpty} token=${accessToken.isNotEmpty}');
  await container.read(authProvider.notifier).setOpenApiServiceEndpoint();
  final didRestore = await container.read(authProvider.notifier).saveAuthInfo(accessToken: accessToken);
  if (!didRestore) {
    throw StateError('Stored Immich login could not be restored for the embedded SwiftUI prototype.');
  }

  if (container.read(currentUserProvider) == null) {
    throw StateError('Embedded session restore succeeded, but currentUserProvider did not resolve a user.');
  }

  await container.read(serverInfoProvider.notifier).getServerInfo();
  final currentUser = container.read(currentUserProvider);
  _embeddedDebug(
    'Embedded restore currentUser=${currentUser?.id ?? "<null>"} authenticated=${container.read(authProvider).isAuthenticated}',
  );
}

class _EmbeddedRoot extends StatelessWidget {
  const _EmbeddedRoot({
    required this.appRouter,
    required this.routeObserver,
    required this.locale,
    required this.restoreError,
  });

  final RootStackRouter appRouter;
  final _EmbeddedRouteObserver routeObserver;
  final Locale locale;
  final Object? restoreError;

  @override
  Widget build(BuildContext context) {
    return EasyLocalization(
      supportedLocales: locales.values.toList(),
      path: translationsPath,
      useFallbackTranslations: true,
      fallbackLocale: locale,
      startLocale: locale,
      assetLoader: const CodegenLoader(),
      child: _EmbeddedApp(appRouter: appRouter, routeObserver: routeObserver, restoreError: restoreError),
    );
  }
}

class _EmbeddedApp extends ConsumerStatefulWidget {
  const _EmbeddedApp({required this.appRouter, required this.routeObserver, required this.restoreError});

  final RootStackRouter appRouter;
  final _EmbeddedRouteObserver routeObserver;
  final Object? restoreError;

  @override
  ConsumerState<_EmbeddedApp> createState() => _EmbeddedAppState();
}

class _EmbeddedAppState extends ConsumerState<_EmbeddedApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    unawaited(
      FlutterLocalNotificationsPlugin().initialize(const InitializationSettings(iOS: DarwinInitializationSettings())),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    Intl.defaultLocale = context.locale.toLanguageTag();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final immichTheme = ref.watch(immichThemeProvider);
    final themeMode = ref.watch(appConfigProvider.select((config) => config.theme.mode));
    final locale = ref.watch(localeProvider);

    ThemeData embeddedTheme(ThemeData base) {
      return base.copyWith(
        appBarTheme: base.appBarTheme.copyWith(
          toolbarHeight: 0,
          elevation: 0,
          backgroundColor: Colors.transparent,
          surfaceTintColor: Colors.transparent,
        ),
      );
    }

    return EmbeddedScope(
      hideChrome: true,
      child: MaterialApp.router(
        title: 'Immich Embedded',
        debugShowCheckedModeBanner: true,
        localizationsDelegates: context.localizationDelegates,
        supportedLocales: context.supportedLocales,
        locale: context.locale,
        themeMode: themeMode,
        darkTheme: embeddedTheme(getThemeData(colorScheme: immichTheme.dark, locale: locale)),
        theme: embeddedTheme(getThemeData(colorScheme: immichTheme.light, locale: locale)),
        builder: (context, child) => ImmichTranslationProvider(
          translations: ImmichTranslations(submit: 'submit'.tr(), password: 'password'.tr()),
          child: ImmichThemeProvider(
            colorScheme: Theme.of(context).colorScheme,
            child: _EmbeddedAuthDebugBanner(restoreError: widget.restoreError, child: child ?? const SizedBox.shrink()),
          ),
        ),
        routerConfig: widget.appRouter.config(
          includePrefixMatches: false,
          navigatorObservers: () => [widget.routeObserver],
        ),
      ),
    );
  }
}

class _EmbeddedAuthDebugBanner extends StatelessWidget {
  const _EmbeddedAuthDebugBanner({required this.restoreError, required this.child});

  final Object? restoreError;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final restoreError = this.restoreError;
    if (restoreError == null) {
      return child;
    }

    return Column(
      children: [
        Material(
          color: Theme.of(context).colorScheme.errorContainer,
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Text(
                'Prototype unauthenticated mode: $restoreError',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer, fontSize: 12),
              ),
            ),
          ),
        ),
        Expanded(child: child),
      ],
    );
  }
}

class _EmbeddedBootstrapError extends StatelessWidget {
  const _EmbeddedBootstrapError({required this.error, required this.stack});

  final Object error;
  final StackTrace stack;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: true,
      home: Scaffold(
        backgroundColor: Colors.red.shade900,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: SingleChildScrollView(
              child: Text(
                'Embedded SwiftUI prototype failed to start.\n\n$error\n\n$stack',
                style: const TextStyle(color: Colors.white, fontSize: 13),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
