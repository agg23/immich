import 'dart:async';
import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/events.model.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/domain/utils/event_stream.dart';
import 'package:immich_mobile/native_shell/native_shell.dart';
import 'package:immich_mobile/native_shell/native_timeline_debug.dart';
import 'package:immich_mobile/native_shell/native_timeline_window.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';
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

  /// Declared here so both platforms page identically.
  static const pageSize = 120;

  void init() {
    if (!NativeShell.isActive) {
      return;
    }
    _channel.setMethodCallHandler(_handle);
    // Listened, not read: the provider hands out a throwaway service first. On the
    // *container*, not `_ref`: the router owns this bridge, `inLockedViewProvider`
    // reads the router, and the viewer scopes `timelineServiceProvider` — a `ref`
    // dependency here would make that read trip Riverpod's scoping assertion. The
    // main session is the root service by definition, so the container is also right.
    final main = _ref.container.listen<TimelineService>(
      timelineServiceProvider,
      (_, next) => _bind(_mainSession, next),
      fireImmediately: true,
    );
    _ref.onDispose(main.close);
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

  TimelineService? _sessionService(int id) => _sessions[id]?.service;

  void _bind(int id, TimelineService service) {
    unawaited(_sessions.remove(id)?.cancel());
    late final _Session session;
    session = _Session(service, () {
      unawaited(_channel.invokeMethod('invalidate', _describe(id, session)));
    });
    _sessions[id] = session;
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
      case 'window':
        final args = (call.arguments as Map).cast<String, Object?>();
        return _window(args['session'] as int? ?? _mainSession, args['start']! as int, args['count']! as int);
      default:
        if (!await NativeTimelineDebug.handle(call, _ref, sessionService: _sessionService)) {
          dPrint(() => 'native timeline: unhandled ${call.method}');
        }
        return null;
    }
  }

  /// A signal, not a query: a reply would carry the state at the time of the call.
  void _open(int id) {
    final session = _sessions[id];
    if (session == null || session.sections.isEmpty) {
      return;
    }
    unawaited(_channel.invokeMethod('invalidate', _describe(id, session)));
  }

  Map<String, Object?> _describe(int id, _Session session) => {
    'session': id,
    'generation': session.generation,
    'total': session.sections.total,
    'pageSize': pageSize,
    'sections': session.sections.describe(),
  };

  /// Stamped with the generation it was served from, so a window crossing an
  /// invalidation is discarded rather than drawn at stale indices.
  Future<Map<String, Object?>> _window(int id, int start, int count) async {
    final session = _sessions[id];
    if (session == null) {
      return {'session': id, 'generation': -1, 'start': start, 'assets': const []};
    }
    final generation = session.generation;
    final window = clampWindow(start: start, count: count, total: session.sections.total);
    final started = DateTime.now();
    final assets = window.count == 0
        ? const <BaseAsset>[]
        : await session.service.loadAssets(window.start, window.count);
    final took = DateTime.now().difference(started).inMilliseconds;
    if (took > 200) {
      NativeShell.log('timeline: window $id@${window.start}+${window.count} took ${took}ms');
    }
    return {
      'session': id,
      // Re-read: an invalidation may have landed while the load was in flight.
      'generation': session.generation == generation ? generation : -1,
      'start': window.start,
      'assets': [for (final asset in assets) _describeAsset(asset)],
    };
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
      if (remoteId != null && asset.isVideo) 'playbackUrl': getPlaybackUrlForRemoteId(remoteId),
    };
  }
}

/// Not driven straight off the bucket stream: [TimelineService] reloads its buffer
/// on that same stream and raises its total only afterwards, so buckets published
/// on arrival name assets it cannot yet hand over.
class _Session {
  _Session(this.service, this._publish) {
    _buckets = service.watchBuckets().listen(_onBuckets);
    // Shared by every timeline, so it is a hint to re-check, not a signal about this one.
    _reloads = EventStream.shared.listen<TimelineReloadEvent>((_) => _publishIfServable());
  }

  final TimelineService service;
  final void Function() _publish;

  late final StreamSubscription<List<Bucket>> _buckets;
  late final StreamSubscription<TimelineReloadEvent> _reloads;

  /// A window answered from an older generation is discarded rather than drawn.
  int generation = 0;

  TimelineSections sections = TimelineSections.empty;

  TimelineSections? _pending;

  void _onBuckets(List<Bucket> buckets) {
    if (buckets.isEmpty && !sections.isEmpty) {
      return;
    }
    _pending = TimelineSections.fromBuckets(buckets);
    _publishIfServable();
  }

  /// Until the service can serve every claimed index, the platform keeps drawing
  /// the previous generation: stale but coherent.
  void _publishIfServable() {
    final pending = _pending;
    if (pending == null || pending.total != service.totalAssets) {
      return;
    }
    _pending = null;
    sections = pending;
    generation++;
    _publish();
  }

  Future<void> cancel() async {
    await _buckets.cancel();
    await _reloads.cancel();
  }
}

final nativeTimelineBridgeProvider = Provider<NativeTimelineBridge>((ref) => NativeTimelineBridge(ref));
