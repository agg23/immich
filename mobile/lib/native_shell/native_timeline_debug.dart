import 'dart:async';

import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/native_shell/native_shell.dart';
import 'package:immich_mobile/native_shell/native_shell_debug.dart';
import 'package:immich_mobile/providers/asset_viewer/asset_viewer.provider.dart';
import 'package:immich_mobile/providers/infrastructure/album.provider.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';
import 'package:immich_mobile/providers/user.provider.dart';
import 'package:immich_mobile/routing/router.dart';

/// Opens real screens over real data from a launch argument. See [NativeShellDebug].
abstract final class NativeTimelineDebug {
  static const _mainSession = 0;

  static Future<bool> handle(
    MethodCall call,
    Ref ref, {
    required TimelineService? Function(int session) sessionService,
  }) async {
    if (!NativeShellDebug.enabled || !call.method.startsWith('debug')) {
      return false;
    }
    switch (call.method) {
      case 'debugOpenViewer':
        await _openViewer(ref, (call.arguments as Map?)?['timeline'] as String? ?? 'main', sessionService);
      case 'debugPushAlbum':
        await _pushAlbum(ref);
      default:
        return false;
    }
    return true;
  }

  static Future<void> _openViewer(Ref ref, String which, TimelineService? Function(int session) sessionService) async {
    final router = NativeShell.debugRouter;
    NativeShell.log('debug viewer: which=$which router=${router != null}');
    if (router == null) {
      return;
    }
    final service = which == 'main' ? sessionService(_mainSession) : _timeline(ref, which);
    if (service == null) {
      NativeShell.log('debug viewer: no $which timeline to open');
      return;
    }
    final assets = service.totalAssets > 0 ? await service.loadAssets(0, 1) : const <BaseAsset>[];
    if (assets.isNotEmpty) {
      ref.read(assetViewerProvider.notifier).reset();
      ref.read(assetViewerProvider.notifier).setAsset(assets.first);
    }
    NativeShell.log('debug viewer: $which has ${service.totalAssets}, pushing');
    unawaited(router.push(AssetViewerRoute(initialIndex: 0, timelineService: service)));
  }

  static Future<void> _pushAlbum(Ref ref) async {
    final router = NativeShell.debugRouter;
    if (router == null) {
      NativeShell.log('debug album: no router');
      return;
    }
    final albums = await ref.read(remoteAlbumServiceProvider).getAll();
    if (albums.isEmpty) {
      NativeShell.log('debug album: no albums to open');
      return;
    }
    final album = albums.reduce((a, b) => b.assetCount > a.assetCount ? b : a);
    NativeShell.log('debug album: pushing ${album.name}, ${album.assetCount} assets (${albums.length} albums)');
    unawaited(router.push(RemoteAlbumRoute(album: album)));
  }

  static TimelineService? _timeline(Ref ref, String which) {
    final user = ref.read(currentUserProvider);
    if (user == null) {
      return null;
    }
    final factory = ref.read(timelineFactoryProvider);
    return switch (which) {
      'favorite' => factory.favorite(user.id),
      'video' => factory.video(user.id),
      _ => factory.recentlyAdded(user.id),
    };
  }
}
