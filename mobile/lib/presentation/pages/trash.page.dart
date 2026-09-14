import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/native_shell/native_bar_menu.dart';
import 'package:immich_mobile/native_shell/native_sliver_app_bar.dart';
import 'package:immich_mobile/presentation/widgets/bottom_sheet/trash_bottom_sheet.widget.dart';
import 'package:immich_mobile/presentation/widgets/timeline/timeline.widget.dart';
import 'package:immich_mobile/providers/infrastructure/action.provider.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';
import 'package:immich_mobile/providers/server_info.provider.dart';
import 'package:immich_mobile/providers/user.provider.dart';
import 'package:immich_mobile/widgets/common/confirm_dialog.dart';
import 'package:immich_mobile/widgets/common/immich_toast.dart';

@RoutePage()
class TrashPage extends StatelessWidget {
  const TrashPage({super.key});

  @override
  Widget build(BuildContext context) {
    return ProviderScope(
      overrides: [
        timelineServiceProvider.overrideWith((ref) {
          final user = ref.watch(currentUserProvider);
          if (user == null) {
            throw Exception('User must be logged in to access trash');
          }

          final timelineService = ref.watch(timelineFactoryProvider).trash(user.id);
          ref.onDispose(timelineService.dispose);
          return timelineService;
        }),
      ],
      // The menu has to be *built* here rather than wrapped in a widget of its
      // own, which is what it used to be. A bar reads its actions as data, so a
      // `_TrashKebabMenu()` in `actions:` is opaque to it — and the ref the menu
      // needs is this scope's, not the one outside it, so the `Consumer` has to
      // be inside the `ProviderScope` rather than around it.
      child: Consumer(
        builder: (context, ref, child) => Timeline(
          appBar: NativeSliverAppBar.plain(
            title: context.t.trash,
            floating: true,
            snap: true,
            pinned: true,
            centerTitle: true,
            elevation: 0,
            actions: [
              NativeBarMenu(
                icon: Icons.more_vert_rounded,
                items: [
                  NativeBarMenuItem(
                    label: context.t.restore_all,
                    icon: Icons.restore_outlined,
                    onPressed: () => _confirmAndRun(
                      context,
                      ref,
                      title: context.t.restore_all,
                      content: context.t.assets_restore_confirmation,
                      action: ref.read(actionProvider.notifier).restoreAllTrash,
                      successMsg: (count) => context.t.assets_restored_count(count: count),
                    ),
                  ),
                  NativeBarMenuItem(
                    label: context.t.empty_trash,
                    icon: Icons.delete_forever_outlined,
                    destructive: true,
                    onPressed: () => _confirmAndRun(
                      context,
                      ref,
                      title: context.t.empty_trash,
                      content: context.t.empty_trash_confirmation,
                      action: ref.read(actionProvider.notifier).emptyTrash,
                      successMsg: (count) => context.t.assets_permanently_deleted_count(count: count),
                    ),
                  ),
                ],
              ),
            ],
          ),
          topSliverWidgetHeight: 24,
          topSliverWidget: SliverPadding(
            padding: const EdgeInsets.all(16.0),
            sliver: SliverToBoxAdapter(
              child: Text(
                context.t.trash_page_info(days: ref.watch(serverInfoProvider.select((v) => v.serverConfig.trashDays))),
              ),
            ),
          ),
          bottomSheet: const TrashBottomBar(),
        ),
      ),
    );
  }
}

Future<void> _confirmAndRun(
  BuildContext context,
  WidgetRef ref, {
  required String title,
  required String content,
  required Future<ActionResult> Function(String userId) action,
  required String Function(int count) successMsg,
}) async {
  await showDialog<bool>(
    context: context,
    builder: (_) => ConfirmDialog(
      title: title,
      content: content,
      onOk: () async {
        final user = ref.read(currentUserProvider);
        if (user == null) {
          return;
        }
        final result = await action(user.id);
        if (!context.mounted) {
          return;
        }
        ImmichToast.show(
          context: context,
          msg: result.success ? successMsg(result.count) : context.t.scaffold_body_error_occurred,
          toastType: result.success ? ToastType.success : ToastType.error,
        );
      },
    ),
  );
}
