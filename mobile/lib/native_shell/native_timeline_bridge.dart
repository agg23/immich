import 'dart:async';

import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/native_shell/native_shell.dart';
import 'package:immich_mobile/providers/asset_viewer/asset_viewer.provider.dart';
import 'package:immich_mobile/providers/infrastructure/album.provider.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';
import 'package:immich_mobile/providers/user.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_mobile/utils/debug_print.dart';
import 'package:immich_mobile/utils/image_url_builder.dart';
import 'package:openapi/api.dart';

class NativeTimelineBridge {
  NativeTimelineBridge(this._ref);

  final Ref _ref;
  static const _channel = MethodChannel('immich/timeline');

  final Map<int, _Session> _sessions = {};
  int _nextSession = _mainSession + 1;

  static const _mainSession = 0;

  void init() {
    if (!NativeShell.isActive) {
      return;
    }
    _channel.setMethodCallHandler(_handle);
    // Listened, not read: the provider hands out a throwaway service first.
    _ref.listen<TimelineService>(
      timelineServiceProvider,
      (_, next) => _bind(_mainSession, next),
      fireImmediately: true,
    );
    _ref.onDispose(dispose);
  }

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
      default:
        dPrint(() => 'native timeline: unhandled ${call.method}');
        return null;
    }
  }

  Future<void> _debugOpenViewer(String which) async {
    final router = NativeShell.debugRouter;
    NativeShell.log('debug viewer: which=$which router=${router != null}');
    if (router == null) {
      return;
    }
    final service = which == 'main' ? _sessions[_mainSession]?.service : _debugTimeline(which);
    if (service == null) {
      NativeShell.log('debug viewer: no $which timeline to open');
      return;
    }
    final assets = service.totalAssets > 0 ? await service.loadAssets(0, 1) : const <BaseAsset>[];
    if (assets.isNotEmpty) {
      _ref.read(assetViewerProvider.notifier).reset();
      _ref.read(assetViewerProvider.notifier).setAsset(assets.first);
    }
    NativeShell.log('debug viewer: $which has ${service.totalAssets}, pushing');
    unawaited(router.push(AssetViewerRoute(initialIndex: 0, timelineService: service)));
  }

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
    final album = albums.reduce((a, b) => b.assetCount > a.assetCount ? b : a);
    NativeShell.log('debug album: pushing ${album.name}, ${album.assetCount} assets (${albums.length} albums)');
    unawaited(router.push(RemoteAlbumRoute(album: album)));
  }

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

  /// A signal, not a query: a reply would carry the state at the time of the call.
  void _open(int id) {
    final session = _sessions[id];
    if (session == null || session.lastBuckets.isEmpty) {
      return;
    }
    unawaited(_channel.invokeMethod('invalidate', _describe(id, session.service, session.lastBuckets)));
  }

  Map<String, Object?> _describe(int id, TimelineService service, List<Bucket> buckets) => {
    'session': id,
    'total': buckets.fold<int>(0, (sum, bucket) => sum + bucket.assetCount),
    'buckets': [
      for (final bucket in buckets)
        {'count': bucket.assetCount, if (bucket is TimeBucket) 'date': bucket.date.millisecondsSinceEpoch},
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
      if (remoteId != null) 'thumbUrl': getThumbnailUrlForRemoteId(remoteId),
      if (remoteId != null) 'previewUrl': getThumbnailUrlForRemoteId(remoteId, type: AssetMediaSize.preview),
      if (remoteId != null) 'originalUrl': getOriginalUrlForRemoteId(remoteId),
    };
  }
}

class _Session {
  _Session(this.service, void Function(List<Bucket>) publish) {
    _buckets = service.watchBuckets().listen((buckets) {
      if (buckets.isEmpty && lastBuckets.isNotEmpty) {
        return;
      }
      lastBuckets = buckets;
      publish(buckets);
    });
  }

  final TimelineService service;
  late final StreamSubscription<List<Bucket>> _buckets;

  List<Bucket> lastBuckets = const [];

  Future<void> cancel() => _buckets.cancel();
}

final nativeTimelineBridgeProvider = Provider<NativeTimelineBridge>((ref) => NativeTimelineBridge(ref));
