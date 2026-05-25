import 'package:flutter/widgets.dart';

class EmbeddedScopeController {
  EmbeddedScopeController._();

  static final instance = EmbeddedScopeController._();

  final ValueNotifier<bool> hideChrome = ValueNotifier<bool>(true);
}

class EmbeddedScope extends InheritedNotifier<ValueNotifier<bool>> {
  EmbeddedScope({super.key, required bool hideChrome, required super.child})
    : super(notifier: EmbeddedScopeController.instance.hideChrome) {
    EmbeddedScopeController.instance.hideChrome.value = hideChrome;
  }

  static bool hideChromeOf(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<EmbeddedScope>()?.notifier?.value ?? false;
  }
}
