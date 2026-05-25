import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/platform/embedded_ui_api.g.dart',
    swiftOut: 'ios/Runner/EmbeddedUI/EmbeddedUI.g.swift',
    swiftOptions: SwiftOptions(includeErrorClass: false),
    dartOptions: DartOptions(),
    dartPackageName: 'immich_mobile',
  ),
)
class TimelineBucket {
  final int offset;
  final int count;
  final int? epochMilliseconds;

  const TimelineBucket({required this.offset, required this.count, this.epochMilliseconds});
}

class AssetMeta {
  final String id;
  final String? remoteId;
  final String? localId;
  final int createdAtEpochMilliseconds;
  final bool isFavorite;
  final bool isVideo;
  final bool isEdited;
  final String? thumbhash;

  const AssetMeta({
    required this.id,
    required this.createdAtEpochMilliseconds,
    required this.isFavorite,
    required this.isVideo,
    required this.isEdited,
    this.remoteId,
    this.localId,
    this.thumbhash,
  });
}

class ServerConfig {
  final String endpoint;
  final String token;
  final Map<String, String> customHeaders;

  const ServerConfig({required this.endpoint, required this.token, required this.customHeaders});
}

@HostApi()
abstract class EmbeddedHostApi {
  void onFlutterReady();

  void onRequestPop();

  void onAuthChanged(bool isAuthenticated);

  void onRouteStateChanged(bool canPop, String title);
}

@FlutterApi()
abstract class EmbeddedFlutterApi {
  @async
  void navigateTo(String routeName, Map<String, Object?> args);

  @async
  bool maybePop();

  void setEmbeddedMode(bool hideChrome);

  @async
  void resetToRoot();
}

@HostApi()
abstract class TimelineHostApi {
  void onTimelineChanged();

  void onAssetsChanged(List<String> assetIds);
}

@FlutterApi()
abstract class TimelineFlutterApi {
  @async
  List<TimelineBucket> loadBuckets();

  @async
  List<AssetMeta> loadAssets(int offset, int count);

  @async
  String thumbnailUrl(String assetId, String? thumbhash, bool edited);

  @async
  ServerConfig serverConfig();

  void setFavorite(List<String> ids, bool value);

  void delete(List<String> ids);
}
