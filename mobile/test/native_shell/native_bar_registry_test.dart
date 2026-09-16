import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/native_shell/native_bar_registry.dart';
import 'package:immich_mobile/native_shell/native_icon.dart';
import 'package:immich_mobile/native_shell/native_shell.dart';

/// Whether a republish is worth a channel call, and what a late tap resolves to.
void main() {
  late int changes;
  late NativeBarRegistry registry;

  setUp(() {
    changes = 0;
    registry = NativeBarRegistry(onChanged: () => changes++);
  });

  NativeBar barWith(List<NativeBarAction> actions, {String title = 'Album'}) =>
      NativeBar(title: title, actions: actions);

  group('publish', () {
    test('announces a new bar', () {
      registry.publish('AlbumRoute', barWith(const [NativeBarAction(icon: NativeIcon.edit)]));
      expect(changes, 1);
    });

    test('stays quiet when an identical bar is republished', () {
      for (var i = 0; i < 3; i++) {
        registry.publish('AlbumRoute', barWith([NativeBarAction(icon: NativeIcon.edit, onPressed: () {})]));
      }
      expect(changes, 1);
    });

    test('announces a bar whose action became disabled', () {
      registry.publish('AlbumRoute', barWith([NativeBarAction(icon: NativeIcon.edit, onPressed: () {})]));
      registry.publish('AlbumRoute', barWith(const [NativeBarAction(icon: NativeIcon.edit)]));
      expect(changes, 2);
    });

    test('announces a title change', () {
      registry.publish('AlbumRoute', barWith(const [], title: 'Trip'));
      registry.publish('AlbumRoute', barWith(const [], title: 'Trip 2024'));
      expect(changes, 2);
    });
  });

  group('clear', () {
    test('announces a bar that existed', () {
      registry.publish('AlbumRoute', barWith(const []));
      registry.clear('AlbumRoute');
      expect(changes, 2);
      expect(registry['AlbumRoute'], isNull);
    });

    test('stays quiet for a route that never published', () {
      registry.clear('AlbumRoute');
      expect(changes, 0);
    });
  });

  group('setCollapsed', () {
    test('reports only the crossings', () {
      expect(registry.setCollapsed('AlbumRoute', collapsed: true), isTrue);
      expect(registry.setCollapsed('AlbumRoute', collapsed: true), isFalse);
      expect(registry.setCollapsed('AlbumRoute', collapsed: false), isTrue);
    });

    test('forgets the state with the bar, so a rebuilt route re-reports', () {
      registry.publish('AlbumRoute', barWith(const []));
      registry.setCollapsed('AlbumRoute', collapsed: true);
      registry.clear('AlbumRoute');
      expect(registry.setCollapsed('AlbumRoute', collapsed: true), isTrue);
    });
  });

  group('resolve', () {
    test('finds a plain action', () {
      registry.publish('AlbumRoute', barWith(const [NativeBarAction(icon: NativeIcon.edit)]));
      final hit = registry.resolve(route: 'AlbumRoute', index: 0, item: -1);
      expect(hit?.action.icon, NativeIcon.edit);
      expect(hit?.row, isNull);
    });

    test('finds a menu row', () {
      registry.publish(
        'AlbumRoute',
        barWith(const [
          NativeBarAction(
            icon: NativeIcon.overflow,
            menu: [NativeMenuItem(label: 'Edit'), NativeMenuItem(label: 'Delete', destructive: true)],
          ),
        ]),
      );
      expect(registry.resolve(route: 'AlbumRoute', index: 0, item: 1)?.row?.label, 'Delete');
    });

    test('returns nothing for a tap on a bar that has moved on', () {
      registry.publish('AlbumRoute', barWith(const [NativeBarAction(icon: NativeIcon.edit)]));
      expect(registry.resolve(route: 'AlbumRoute', index: 3, item: -1), isNull);
      expect(registry.resolve(route: 'GoneRoute', index: 0, item: -1), isNull);
    });

    test('returns nothing for a menu row that has moved on', () {
      registry.publish(
        'AlbumRoute',
        barWith(const [
          NativeBarAction(icon: NativeIcon.overflow, menu: [NativeMenuItem(label: 'Edit')]),
        ]),
      );
      expect(registry.resolve(route: 'AlbumRoute', index: 0, item: 4), isNull);
    });
  });

  group('handlerFor', () {
    test('fires the row, not the action behind it', () {
      var action = false;
      var row = false;
      registry.publish(
        'AlbumRoute',
        barWith([
          NativeBarAction(
            icon: NativeIcon.overflow,
            onPressed: () => action = true,
            menu: [NativeMenuItem(label: 'Edit', onPressed: () => row = true)],
          ),
        ]),
      );

      NativeBarRegistry.handlerFor(registry.resolve(route: 'AlbumRoute', index: 0, item: 0)!)?.call();
      expect(row, isTrue);
      expect(action, isFalse);
    });

    test('a disabled row does not fall through to its action', () {
      var action = false;
      registry.publish(
        'AlbumRoute',
        barWith([
          NativeBarAction(
            icon: NativeIcon.overflow,
            onPressed: () => action = true,
            menu: const [NativeMenuItem(label: 'Edit')],
          ),
        ]),
      );

      NativeBarRegistry.handlerFor(registry.resolve(route: 'AlbumRoute', index: 0, item: 0)!)?.call();
      expect(action, isFalse);
    });
  });
}
