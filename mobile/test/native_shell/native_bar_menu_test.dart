import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/native_shell/native_bar_menu.dart';

import '../widget_tester_extensions.dart';

/// That a declared menu renders, fires, and refuses to translate rather than badly.
void main() {
  const trigger = Icons.more_vert_rounded;

  Future<void> open(WidgetTester tester, List<NativeBarMenuItem> items) async {
    await tester.pumpConsumerWidget(NativeBarMenu(icon: trigger, items: items));
    await tester.tap(find.byIcon(trigger));
    await tester.pumpAndSettle();
  }

  group('NativeBarMenu', () {
    testWidgets('renders a row per item and fires the one tapped', (tester) async {
      var edited = false;
      await open(tester, [
        NativeBarMenuItem(label: 'Edit album', icon: Icons.edit, onPressed: () => edited = true),
        const NativeBarMenuItem(label: 'Options', icon: Icons.settings),
      ]);

      expect(find.text('Edit album'), findsOneWidget);
      expect(find.text('Options'), findsOneWidget);

      await tester.tap(find.text('Edit album'));
      await tester.pumpAndSettle();
      expect(edited, isTrue);
    });

    testWidgets('separates a destructive row', (tester) async {
      await open(tester, [
        const NativeBarMenuItem(label: 'Options', icon: Icons.settings),
        const NativeBarMenuItem(label: 'Delete album', icon: Icons.delete, destructive: true),
      ]);

      expect(find.byType(Divider), findsOneWidget);
    });

    test('describes itself for the native bar', () {
      const menu = NativeBarMenu(
        icon: trigger,
        items: [NativeBarMenuItem(label: 'Delete album', icon: Icons.delete, destructive: true)],
      );

      expect(menu.untranslatable(), isNull);
      expect(menu.describe()?.menu?.single.destructive, isTrue);
    });

    test('refuses to translate a row it has no icon token for', () {
      const menu = NativeBarMenu(
        icon: trigger,
        items: [NativeBarMenuItem(label: 'Mystery', icon: Icons.abc)],
      );

      expect(menu.describe(), isNull);
      expect(menu.untranslatable(), contains('no icon token for menu row'));
    });
  });
}
