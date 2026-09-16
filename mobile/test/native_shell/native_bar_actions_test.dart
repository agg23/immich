import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/native_shell/native_bar_actions.dart';
import 'package:immich_mobile/native_shell/native_bar_menu.dart';
import 'package:immich_mobile/native_shell/native_icon.dart';

/// Translation is all-or-nothing, so one unrecognised action silently costs a page
/// its whole native bar.
void main() {
  const menu = NativeBarMenu(
    icon: Icons.more_vert_rounded,
    items: [NativeBarMenuItem(label: 'By filename', icon: Icons.abc_rounded)],
  );

  group('translateAction', () {
    test('reads an icon button', () {
      expect(translateAction(IconButton(icon: const Icon(Icons.search), onPressed: () {}))?.icon, NativeIcon.search);
    });

    test('reads a text button', () {
      expect(translateAction(TextButton(onPressed: () {}, child: const Text('Done')))?.label, 'Done');
    });

    test('sees through the padding bars wrap their actions in', () {
      expect(translateAction(const Padding(padding: EdgeInsets.only(right: 16), child: menu))?.icon,
          NativeIcon.overflow);
      expect(
        translateAction(
          Padding(
            padding: const EdgeInsets.all(4),
            child: IconButton(icon: const Icon(Icons.search), onPressed: () {}),
          ),
        )?.icon,
        NativeIcon.search,
      );
    });

    test('refuses anything it does not recognise', () {
      expect(translateAction(const SizedBox.shrink()), isNull);
      expect(translateAction(const Padding(padding: EdgeInsets.zero, child: SizedBox.shrink())), isNull);
    });
  });

  group('translateActions', () {
    test('translates a padded list', () {
      expect(translateActions(const [Padding(padding: EdgeInsets.only(right: 16), child: menu)]), hasLength(1));
    });

    test('gives up entirely on one bad action', () {
      expect(
        translateActions(const [Padding(padding: EdgeInsets.only(right: 16), child: menu), SizedBox.shrink()]),
        isNull,
      );
    });

    test('names the widget it could not translate, unwrapped', () {
      expect(untranslatableAction(const [Padding(padding: EdgeInsets.zero, child: Placeholder())]),
          contains('Placeholder'));
    });
  });
}
