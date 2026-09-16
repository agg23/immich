import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/native_shell/native_icon.dart';

/// A token with no platform case draws nothing and only logs, so nothing but this
/// catches it.
void main() {
  test('every token has an iOS symbol', () {
    final swift = File('ios/Runner/NativeShell/ShellIcon.swift').readAsStringSync();
    final cases = RegExp(r'^\s*case (\w+)$', multiLine: true).allMatches(swift).map((m) => m.group(1)!).toSet();

    expect(cases, isNotEmpty, reason: 'ShellIcon.swift moved or changed shape');
    for (final icon in NativeIcon.values) {
      expect(cases, contains(icon.name), reason: 'ShellIcon has no case for ${icon.name}');
    }
  });

  test('every iOS symbol maps to a token', () {
    final swift = File('ios/Runner/NativeShell/ShellIcon.swift').readAsStringSync();
    final mapped = RegExp(r'case \.(\w+): "').allMatches(swift).map((m) => m.group(1)!).toSet();
    final tokens = NativeIcon.values.map((i) => i.name).toSet();

    expect(mapped.difference(tokens), isEmpty, reason: 'ShellIcon maps tokens Dart no longer declares');
  });
}
