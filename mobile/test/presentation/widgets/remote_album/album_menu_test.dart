import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/native_shell/native_bar_menu.dart';
import 'package:immich_mobile/presentation/widgets/remote_album/album_menu.dart';

import '../../../widget_tester_extensions.dart';

void main() {
  Future<List<NativeBarMenuItem>> rows(
    WidgetTester tester,
    List<NativeBarMenuItem> Function(BuildContext context) build,
  ) async {
    late List<NativeBarMenuItem> items;
    await tester.pumpConsumerWidget(
      Builder(
        builder: (context) {
          items = build(context);
          return const SizedBox.shrink();
        },
      ),
    );
    return items;
  }

  void noop() {}

  group('remoteAlbumMenuItems', () {
    testWidgets('offers nothing when nothing is available', (tester) async {
      expect(await rows(tester, (c) => remoteAlbumMenuItems(c)), isEmpty);
    });

    testWidgets('offers a row per callback, in menu order', (tester) async {
      final items = await rows(
        tester,
        (c) => remoteAlbumMenuItems(
          c,
          onEditAlbum: noop,
          onAddPhotos: noop,
          onAddUsers: noop,
          onLeaveAlbum: noop,
          onToggleAlbumOrder: noop,
          onCreateSharedLink: noop,
          onShowOptions: noop,
          onDeleteAlbum: noop,
        ),
      );

      expect(items.map((i) => i.icon), [
        Icons.edit,
        Icons.add_a_photo,
        Icons.group_add,
        Icons.person_remove_rounded,
        Icons.swap_vert_rounded,
        Icons.link,
        Icons.settings,
        Icons.delete,
      ]);
      expect(items.every((i) => i.label.isNotEmpty), isTrue);
    });

    testWidgets('withholds every row whose callback is null', (tester) async {
      final items = await rows(tester, (c) => remoteAlbumMenuItems(c, onShowOptions: noop));

      expect(items.map((i) => i.icon), [Icons.settings]);
    });

    testWidgets('fires the callback the row was given', (tester) async {
      var deleted = false;
      final items = await rows(tester, (c) => remoteAlbumMenuItems(c, onDeleteAlbum: () => deleted = true));

      items.single.onPressed!();
      expect(deleted, isTrue);
    });

    testWidgets('marks deleting the album, and only that, destructive', (tester) async {
      final items = await rows(
        tester,
        (c) => remoteAlbumMenuItems(c, onEditAlbum: noop, onLeaveAlbum: noop, onDeleteAlbum: noop),
      );

      expect(items.where((i) => i.destructive).map((i) => i.icon), [Icons.delete]);
    });
  });
}
