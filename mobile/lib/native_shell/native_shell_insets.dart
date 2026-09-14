import 'package:flutter/material.dart';
import 'package:immich_mobile/native_shell/native_shell.dart';

class NativeShellInsets extends StatelessWidget {
  const NativeShellInsets({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!NativeShell.isActive) {
      return child;
    }
    return ValueListenableBuilder<EdgeInsets?>(
      valueListenable: NativeShell.insets,
      builder: (context, insets, _) {
        if (insets == null) {
          return child;
        }
        final media = MediaQuery.of(context);
        return MediaQuery(
          data: media.copyWith(padding: insets, viewPadding: insets),
          child: child,
        );
      },
    );
  }
}
