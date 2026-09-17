import 'package:flutter/material.dart';
import 'package:immich_mobile/native_shell/native_shell.dart';

/// Tells the native shell which palette Flutter is wearing, whenever it changes.
class NativeShellTheme extends StatelessWidget {
  const NativeShellTheme({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (NativeShell.isActive) {
      NativeShell.setTheme(Theme.of(context).colorScheme);
    }
    return child;
  }
}
