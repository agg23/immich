import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/native_shell/native_root_gate.dart';
import 'package:immich_mobile/native_shell/native_shell.dart';
import 'package:immich_mobile/routing/tabs.dart';

/// Which roots Dart leaves to the shell, and when it is allowed to build its own.
void main() {
  const grid = Key('grid');

  Widget gate({required bool active}) => MaterialApp(
    home: NativeRootGate(tab: NativeTab.photos, active: active, child: const SizedBox(key: grid)),
  );

  tearDown(() => NativeShell.nativeRoots.value = null);

  group('isNative', () {
    test('every root while the shell has not answered', () {
      expect(NativeRootGate.isNative(NativeTab.photos, null), isTrue);
      expect(NativeRootGate.isNative(NativeTab.albums, null), isTrue);
    });

    test('only the roots the shell named', () {
      expect(NativeRootGate.isNative(NativeTab.photos, {'photos'}), isTrue);
      expect(NativeRootGate.isNative(NativeTab.albums, {'photos'}), isFalse);
    });

    test('none when the shell named none', () {
      expect(NativeRootGate.isNative(NativeTab.photos, const {}), isFalse);
    });
  });

  group('widget', () {
    testWidgets('builds the page when the shell is not active', (tester) async {
      await tester.pumpWidget(gate(active: false));
      expect(find.byKey(grid), findsOneWidget);
    });

    testWidgets('holds the page back until the shell answers, then follows the answer', (tester) async {
      await tester.pumpWidget(gate(active: true));
      expect(find.byKey(grid), findsNothing);

      NativeShell.nativeRoots.value = const {};
      await tester.pump();
      expect(find.byKey(grid), findsOneWidget);

      NativeShell.nativeRoots.value = {'photos'};
      await tester.pump();
      expect(find.byKey(grid), findsNothing);
    });
  });
}
