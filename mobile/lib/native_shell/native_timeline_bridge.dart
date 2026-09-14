import 'dart:async';

import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/events.model.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/domain/utils/event_stream.dart';
import 'package:immich_mobile/native_shell/native_shell.dart';
import 'package:immich_mobile/providers/asset_viewer/asset_viewer.provider.dart';
import 'package:immich_mobile/providers/infrastructure/album.provider.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';
import 'package:immich_mobile/providers/user.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_mobile/utils/debug_print.dart';
import 'package:immich_mobile/utils/image_url_builder.dart';
import 'package:openapi/api.dart';

/// Feeds the native timeline from Immich's own timeline query.
///
/// The native grid could have read the drift database directly — the iOS
/// target already links GRDB for the widget extension — but that would fork
/// the query. Buckets, grouping, the merge of local and remote assets and the
/// windowed load are all decisions `TimelineService` already makes, and
/// duplicating them in Swift would mean maintaining two timelines that agree
/// only by accident.
///
/// So Dart stays the source of truth and the native side is a renderer: it
/// asks for a window of assets by flat index, exactly as the Flutter timeline
/// does, and gets back enough to draw a tile. Where the pixels come from is
/// then a native decision — a remote asset is a URL fetched through
/// `URLSessionManager`, which already carries Immich's auth headers, and a
/// local one is a `PHAsset`.
class NativeTimelineBridge {
  NativeTimelineBridge(this._ref);

  final Ref _ref;
  static const _channel = MethodChannel('immich/timeline');

  /// One timeline per session. Session 0 is the grid's, bound from the
  /// provider and never closed.
  ///
  /// Immich's timeline is not one query: a viewer opened from an album, a
  /// person or a search is reading that page's own `TimelineService`, with its
  /// own buckets and its own flat indices. Native needs to name which one it is
  /// asking about, and a number is the smallest thing that can travel over a
  /// channel and still mean a Dart object.
  final Map<int, _Session> _sessions = {};
  int _nextSession = _mainSession + 1;

  static const _mainSession = 0;

  void init() {
    if (!NativeShell.isActive) {
      return;
    }
    _channel.setMethodCallHandler(_handle);
    // `timelineServiceProvider` watches the timeline's user list, which
    // resolves asynchronously after launch — so the provider hands out a
    // throwaway service first and rebuilds with the real one. Reading it once
    // would leave this bridge subscribed to a disposed service and the native
    // grid permanently empty.
    _ref.listen<TimelineService>(
      timelineServiceProvider,
      (_, next) => _bind(_mainSession, next),
      fireImmediately: true,
    );
    _ref.onDispose(dispose);
  }

  /// Register a timeline so native can ask about it, and return its number.
  ///
  /// Keyed by identity, because tapping a tile in the main grid hands back the
  /// very service session 0 is already serving -- a second session for it would
  /// be a second subscription to the same query for no reason.
  int openSession(TimelineService service) {
    for (final entry in _sessions.entries) {
      if (identical(entry.value.service, service)) {
        return entry.key;
      }
    }
    final id = _nextSession++;
    _bind(id, service);
    return id;
  }

  /// Open the native viewer on [service] at [index], which is what the shell
  /// does instead of pushing Immich's Flutter viewer.
  void openViewer(TimelineService service, int index) {
    final session = openSession(service);
    NativeShell.log('viewer: session $session at $index');
    NativeShell.openViewer(session: session, index: index);
  }

  void closeSession(int id) {
    if (id == _mainSession) {
      return;
    }
    unawaited(_sessions.remove(id)?.cancel());
  }

  void _bind(int id, TimelineService service) {
    unawaited(_sessions.remove(id)?.cancel());
    _sessions[id] = _Session(service, (buckets) {
      unawaited(_channel.invokeMethod('invalidate', _describe(id, service, buckets)));
    });
  }

  void dispose() {
    for (final session in _sessions.values) {
      unawaited(session.cancel());
    }
    _sessions.clear();
  }

  Future<dynamic> _handle(MethodCall call) async {
    switch (call.method) {
      case 'open':
        _open((call.arguments as Map?)?['session'] as int? ?? _mainSession);
        return null;
      case 'closeSession':
        closeSession((call.arguments as Map)['session']! as int);
        return null;
      case 'assets':
        final args = (call.arguments as Map).cast<String, Object?>();
        return _assets(args['session'] as int? ?? _mainSession, args['index']! as int, args['count']! as int);
      case 'debugOpenViewer':
        await _debugOpenViewer((call.arguments as Map?)?['timeline'] as String? ?? 'main');
        return null;
      case 'debugPushAlbum':
        await _debugPushAlbum();
        return null;
      case 'debugScroll':
        final offset = ((call.arguments as Map?)?['offset'] as num?)?.toDouble() ?? 600;
        NativeShell.log('debug scroll: to $offset');
        EventStream.shared.emit(ScrollToOffsetEvent(offset));
        return null;
      default:
        dPrint(() => 'native timeline: unhandled ${call.method}');
        return null;
    }
  }

  /// Open Immich's own asset viewer, the way tapping a tile does.
  ///
  /// This lives here rather than with the other debug hooks because the route
  /// takes a `TimelineService`, and this is the object that has one. It is the
  /// only way to reach the Flutter viewer from a script, and the Flutter viewer
  /// is the route that exposed the mirror pushing a native frame for a
  /// non-opaque overlay.
  Future<void> _debugOpenViewer(String which) async {
    final router = NativeShell.debugRouter;
    NativeShell.log('debug viewer: which=$which router=${router != null}');
    if (router == null) {
      return;
    }
    // `-immichShellViewerTimeline favorite` opens on a timeline that is not the
    // grid's, which is the case the sessions exist for: a viewer opened from an
    // album, a person or a search is reading that page's own service. Without
    // it the only reachable path is the one where the session number happens to
    // be 0 and every routing mistake is invisible.
    final service = which == 'main' ? _sessions[_mainSession]?.service : _debugTimeline(which);
    if (service == null) {
      NativeShell.log('debug viewer: no $which timeline to open');
      return;
    }
    // The same preparation the tile's `onTap` does. Immich's viewer asserts on
    // a null current asset; the native one does not, but this hook has to take
    // the same path a tap takes or it is not testing the tap.
    // A freshly built service has not finished its first bucket query, so it
    // has no assets to preload and asking for one throws a `RangeError` rather
    // than answering empty. A page that opens the viewer has always loaded its
    // timeline already; this hook is the only caller that has not.
    final assets = service.totalAssets > 0 ? await service.loadAssets(0, 1) : const <BaseAsset>[];
    if (assets.isNotEmpty) {
      _ref.read(assetViewerProvider.notifier).reset();
      _ref.read(assetViewerProvider.notifier).setAsset(assets.first);
    }
    NativeShell.log('debug viewer: $which has ${service.totalAssets}, pushing');
    unawaited(router.push(AssetViewerRoute(initialIndex: 0, timelineService: service)));
  }

  /// Open an album, the way tapping one on the albums tab does.
  ///
  /// Here for the same reason [_debugOpenViewer] is: the route takes a
  /// `RemoteAlbum` and this is the object with a `Ref` to fetch one with.
  /// `_debugPush` can only push routes that need no arguments, which is why
  /// every page that takes one — album, person, place, activities — has been
  /// unreachable from a script, and why the pages most worth looking at are
  /// the ones that have only ever been checked by reading them.
  Future<void> _debugPushAlbum() async {
    final router = NativeShell.debugRouter;
    if (router == null) {
      NativeShell.log('debug album: no router');
      return;
    }
    final albums = await _ref.read(remoteAlbumServiceProvider).getAll();
    if (albums.isEmpty) {
      NativeShell.log('debug album: no albums to open');
      return;
    }
    // The biggest one, because the page has to be able to scroll: a two-photo
    // album is shorter than the viewport, so its header cannot collapse and a
    // scroll-driven behaviour has nothing to happen in. The first album the
    // service returned had two photos and looked, from the log alone, like a
    // threshold that never fired.
    final album = albums.reduce((a, b) => b.assetCount > a.assetCount ? b : a);
    NativeShell.log('debug album: pushing ${album.name}, ${album.assetCount} assets (${albums.length} albums)');
    unawaited(router.push(RemoteAlbumRoute(album: album)));
  }
  /// A second, genuinely different timeline, built the way a page builds its
  /// own. Not disposed: this is a debug hook and the session outlives the call.
  TimelineService? _debugTimeline(String which) {
    final user = _ref.read(currentUserProvider);
    if (user == null) {
      return null;
    }
    final factory = _ref.read(timelineFactoryProvider);
    return switch (which) {
      'favorite' => factory.favorite(user.id),
      'video' => factory.video(user.id),
      _ => factory.recentlyAdded(user.id),
    };
  }

  /// `open` is a signal, not a query: it says the native grid is ready, and
  /// the answer comes back as an `invalidate` like every other update.
  ///
  /// It was a query first, and that was a race. Dart binds to the timeline
  /// during app startup while the native grid loads a moment later, so the
  /// reply was computed before the first bucket emission and *delivered after*
  /// it — wiping 2425 sections the grid had already been given. A reply
  /// carries the state at the time of the call; a push carries the state at
  /// the time of the push, which is the only one worth acting on.
  void _open(int id) {
    final session = _sessions[id];
    if (session == null || session.lastBuckets.isEmpty) {
      return;
    }
    unawaited(_channel.invokeMethod('invalidate', _describe(id, session.service, session.lastBuckets)));
  }

  Map<String, Object?> _describe(int id, TimelineService service, List<Bucket> buckets) => {
    'session': id,
    // Summed from the buckets rather than read from `service.totalAssets`:
    // the bucket stream fires before the service has finished reloading its
    // buffer, so its own count lags by one emission.
    'total': buckets.fold<int>(0, (sum, bucket) => sum + bucket.assetCount),
    'buckets': [
      for (final bucket in buckets)
        {
          'count': bucket.assetCount,
          // Non-time buckets exist for the ungrouped timeline; the native grid
          // renders those as a section with no header.
          if (bucket is TimeBucket) 'date': bucket.date.millisecondsSinceEpoch,
        },
    ],
  };

  Future<List<Map<String, Object?>>> _assets(int id, int index, int count) async {
    final service = _sessions[id]?.service;
    if (service == null || count <= 0) {
      return const [];
    }
    final clamped = count.clamp(0, service.totalAssets - index);
    if (clamped <= 0) {
      return const [];
    }
    final assets = await service.loadAssets(index, clamped);
    return assets.map(_describeAsset).toList();
  }

  Map<String, Object?> _describeAsset(BaseAsset asset) {
    final remoteId = asset.remoteId;
    return {
      'name': asset.name,
      'localId': asset.localId,
      'remoteId': remoteId,
      'isVideo': asset.isVideo,
      'durationMs': asset.durationMs,
      'createdAt': asset.createdAt.millisecondsSinceEpoch,
      'isFavorite': asset.isFavorite,
      // Built here rather than natively so the native side never has to know
      // about the server endpoint, the size enum or the edited flag.
      if (remoteId != null) 'thumbUrl': getThumbnailUrlForRemoteId(remoteId),
      if (remoteId != null) 'previewUrl': getThumbnailUrlForRemoteId(remoteId, type: AssetMediaSize.preview),
      // The untouched upload. The server re-encodes thumbnails and previews, so
      // this is the only URL that can still carry a gain map.
      if (remoteId != null) 'originalUrl': getOriginalUrlForRemoteId(remoteId),
    };
  }
}

/// One registered timeline, and what has been said about it so far.
class _Session {
  _Session(this.service, void Function(List<Bucket>) publish) {
    _buckets = service.watchBuckets().listen((buckets) {
      // A rebound service's stream opens empty, so forwarding it would clear
      // the native grid and refill it a moment later — a visible flash of an
      // empty timeline on launch. An emptying that is real is reported by the
      // next emission.
      //
      // Not right for production: deleting the last asset would leave the grid
      // showing stale sections until something else changed. The honest fix is
      // for the bridge to distinguish "no data yet" from "no data", which the
      // bucket stream does not currently say.
      if (buckets.isEmpty && lastBuckets.isNotEmpty) {
        return;
      }
      lastBuckets = buckets;
      publish(buckets);
    });
  }

  final TimelineService service;
  late final StreamSubscription<List<Bucket>> _buckets;

  /// The last buckets forwarded, so an `open` that arrives after the first
  /// push answers with the same data rather than an empty timeline.
  List<Bucket> lastBuckets = const [];

  Future<void> cancel() => _buckets.cancel();
}

final nativeTimelineBridgeProvider = Provider<NativeTimelineBridge>((ref) => NativeTimelineBridge(ref));
