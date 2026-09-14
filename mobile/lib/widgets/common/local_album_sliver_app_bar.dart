import 'package:flutter/material.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/native_shell/native_sliver_app_bar.dart';

class LocalAlbumsSliverAppBar extends StatelessWidget {
  const LocalAlbumsSliverAppBar({super.key});

  @override
  Widget build(BuildContext context) {
    return NativeSliverAppBar(
      title: context.t.on_this_device,
      floating: true,
      pinned: true,
      snap: false,
      backgroundColor: context.colorScheme.surfaceContainer,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(5))),
      centerTitle: true,
    );
  }
}
