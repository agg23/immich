import 'dart:async';

import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/native_shell/native_shell.dart';
import 'package:immich_mobile/providers/asset_viewer/asset_viewer.provider.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';
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

  TimelineService? _service;
  StreamSubscription<List<Bucket>>? _buckets;
  /// The last buckets forwarded, so an `open` that arrives after the first
  /// push answers with the same data rather than an empty timeline.
  List<Bucket> _lastBuckets = const [];

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
    _ref.listen<TimelineService>(timelineServiceProvider, (_, next) => _bind(next), fireImmediately: true);
    _ref.onDispose(dispose);
  }

  void _bind(TimelineService service) {
    _service = service;
    unawaited(_buckets?.cancel());
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
      if (buckets.isEmpty && _lastBuckets.isNotEmpty) {
        return;
      }
      _lastBuckets = buckets;
      unawaited(_channel.invokeMethod('invalidate', _describe(service, buckets)));
    });
  }

  void dispose() {
    unawaited(_buckets?.cancel());
    _buckets = null;
  }

  Future<dynamic> _handle(MethodCall call) async {
    switch (call.method) {
      case 'open':
        _open();
        return null;
      case 'assets':
        final args = (call.arguments as Map).cast<String, Object?>();
        return _assets(args['index']! as int, args['count']! as int);
      case 'debugOpenViewer':
        await _debugOpenViewer();
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
  Future<void> _debugOpenViewer() async {
    final service = _service;
    final router = NativeShell.debugRouter;
    if (service == null || router == null) {
      dPrint(() => 'native timeline: nothing to open the viewer with');
      return;
    }
    final assets = await service.loadAssets(0, 1);
    if (assets.isEmpty) {
      dPrint(() => 'native timeline: no asset to open');
      return;
    }
    // The same preparation the tile's `onTap` does. The viewer asserts on a
    // null current asset, so pushing the route alone is not opening it.
    _ref.read(assetViewerProvider.notifier).reset();
    _ref.read(assetViewerProvider.notifier).setAsset(assets.first);
    unawaited(router.push(AssetViewerRoute(initialIndex: 0, timelineService: service)));
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
  void _open() {
    final service = _service;
    if (service == null || _lastBuckets.isEmpty) {
      return;
    }
    unawaited(_channel.invokeMethod('invalidate', _describe(service, _lastBuckets)));
  }

  Map<String, Object?> _describe(TimelineService service, List<Bucket> buckets) => {
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

  Future<List<Map<String, Object?>>> _assets(int index, int count) async {
    final service = _service;
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
    };
  }
}

final nativeTimelineBridgeProvider = Provider<NativeTimelineBridge>((ref) => NativeTimelineBridge(ref));
