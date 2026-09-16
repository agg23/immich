import 'package:auto_route/auto_route.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/native_shell/native_icon.dart';
import 'package:immich_mobile/routing/router.dart';

/// The one place tab order is written down; the index is identity across the channel.
enum NativeTab {
  photos,
  search,
  albums,
  library;

  String get id => name;

  PageRouteInfo get route => switch (this) {
    NativeTab.photos => const PhotosTabRoute(),
    NativeTab.search => const SearchTabRoute(),
    NativeTab.albums => const AlbumsTabRoute(),
    NativeTab.library => const LibraryTabRoute(),
  };

  PageInfo get page => switch (this) {
    NativeTab.photos => PhotosTabRoute.page,
    NativeTab.search => SearchTabRoute.page,
    NativeTab.albums => AlbumsTabRoute.page,
    NativeTab.library => LibraryTabRoute.page,
  };

  PageInfo get rootPage => switch (this) {
    NativeTab.photos => MainTimelineRoute.page,
    NativeTab.search => SearchRoute.page,
    NativeTab.albums => AlbumsRoute.page,
    NativeTab.library => LibraryRoute.page,
  };

  /// Search rebuilds its query state on every visit.
  bool get maintainRootState => this != NativeTab.search;

  NativeIcon get icon => switch (this) {
    NativeTab.photos => NativeIcon.photos,
    NativeTab.search => NativeIcon.search,
    NativeTab.albums => NativeIcon.albums,
    NativeTab.library => NativeIcon.library,
  };

  /// Context-free: the native tab bar is built outside the widget tree.
  String get label => switch (this) {
    NativeTab.photos => StaticTranslations.instance.photos,
    NativeTab.search => StaticTranslations.instance.search,
    NativeTab.albums => StaticTranslations.instance.albums,
    NativeTab.library => StaticTranslations.instance.library$,
  };

  Map<String, Object?> describe() => {'id': id, 'label': label, 'icon': icon.name};

  static NativeTab? byId(String? id) => id == null ? null : values.asNameMap()[id];

  static NativeTab? at(int? index) => index != null && index >= 0 && index < values.length ? values[index] : null;

  static List<PageRouteInfo> get routes => [for (final tab in values) tab.route];
}

/// Routes the native shell draws itself, which the mirrored stack must not contain.
Set<String> get nativeShellRoutes => {
  SplashScreenRoute.name,
  LoginRoute.name,
  ChangePasswordRoute.name,
  TabShellRoute.name,
  for (final tab in NativeTab.values) ...[tab.page.name, tab.rootPage.name],
};
