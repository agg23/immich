import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/routing/tabs.dart';

/// Tab order is identity across the channel, and the shell-route set derives from it.
void main() {
  group('NativeTab', () {
    test('ids round-trip, and an unknown id is not a tab', () {
      for (final tab in NativeTab.values) {
        expect(NativeTab.byId(tab.id), tab);
      }
      expect(NativeTab.byId('nope'), isNull);
      expect(NativeTab.byId(null), isNull);
    });

    test('index lookup refuses anything off the end', () {
      expect(NativeTab.at(0), NativeTab.values.first);
      expect(NativeTab.at(NativeTab.values.length), isNull);
      expect(NativeTab.at(-1), isNull);
      expect(NativeTab.at(null), isNull);
    });

    test('routes are declared in tab order', () {
      expect(NativeTab.routes.length, NativeTab.values.length);
      for (final (index, tab) in NativeTab.values.indexed) {
        expect(NativeTab.routes[index].routeName, tab.page.name);
      }
    });

    test('describes itself with everything the native tab bar needs', () {
      for (final tab in NativeTab.values) {
        expect(tab.describe(), {'id': tab.id, 'label': tab.label, 'icon': tab.icon.name});
      }
    });
  });

  group('nativeShellRoutes', () {
    test('covers every tab container and tab root', () {
      for (final tab in NativeTab.values) {
        expect(nativeShellRoutes, contains(tab.page.name));
        expect(nativeShellRoutes, contains(tab.rootPage.name));
      }
    });

    test('covers the pre-auth roots and the tab shell', () {
      expect(nativeShellRoutes, containsAll(['SplashScreenRoute', 'LoginRoute', 'TabShellRoute']));
    });

    test('does not swallow a pushed route', () {
      // The mirrored stack is everything *not* in here.
      expect(nativeShellRoutes, isNot(contains('RemoteAlbumRoute')));
      expect(nativeShellRoutes, isNot(contains('AssetViewerRoute')));
    });
  });
}
