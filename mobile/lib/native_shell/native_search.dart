import 'dart:async';

import 'package:immich_mobile/native_shell/native_shell.dart';

/// The search tab's text field when the platform draws it.
///
/// Submit-driven, matching the Flutter field it replaces: nothing is searched
/// until the keyboard's search key, and an empty submit clears.
abstract final class NativeSearch {
  static bool get isActive => NativeShell.isActive;

  static final _submitted = StreamController<String>.broadcast();

  /// A stream, not a value: submitting the same text twice is two searches.
  static Stream<String> get submitted => _submitted.stream;

  static String? _placeholder;

  /// The hint follows the selected search type, which is still Flutter's own UI.
  static void setPlaceholder(String placeholder) {
    if (!isActive || _placeholder == placeholder) {
      return;
    }
    _placeholder = placeholder;
    NativeShell.sendSearch(placeholder: placeholder);
  }

  static void setText(String text) {
    if (isActive) {
      NativeShell.sendSearch(text: text);
    }
  }

  static void handleSubmitted(String text) => _submitted.add(text);
}
