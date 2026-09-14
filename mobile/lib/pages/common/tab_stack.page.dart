import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';

@RoutePage()
class PhotosTabPage extends StatelessWidget {
  const PhotosTabPage({super.key});

  @override
  Widget build(BuildContext context) => const AutoRouter();
}

@RoutePage()
class SearchTabPage extends StatelessWidget {
  const SearchTabPage({super.key});

  @override
  Widget build(BuildContext context) => const AutoRouter();
}

@RoutePage()
class AlbumsTabPage extends StatelessWidget {
  const AlbumsTabPage({super.key});

  @override
  Widget build(BuildContext context) => const AutoRouter();
}

@RoutePage()
class LibraryTabPage extends StatelessWidget {
  const LibraryTabPage({super.key});

  @override
  Widget build(BuildContext context) => const AutoRouter();
}
