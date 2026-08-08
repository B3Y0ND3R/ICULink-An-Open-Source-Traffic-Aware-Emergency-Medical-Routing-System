import 'dart:async';
import 'package:flutter/foundation.dart';

/// Recovers a stream that errors out by substituting a fallback value and
/// continuing to listen, instead of leaving the stream in a terminated/
/// errored state that a plain `.handleError()` would produce.
///
/// `Stream.handleError()` is commonly mistaken for a value-recovering
/// operator (like `Future.catchError`), but its callback's return value is
/// discarded — the error still propagates to listeners as an error event.
/// Any `.listen()` call that (like everywhere in this app) only supplies an
/// `onData` callback silently drops that error, leaving the UI stuck on
/// whatever state it was last in — typically an infinite loading spinner.
/// This extension actually converts the error into a data event.
extension RecoverableStream<T> on Stream<T> {
  Stream<T> recoverWith(T Function() fallback, {String? logLabel}) {
    return transform(
      StreamTransformer<T, T>.fromHandlers(
        handleError: (error, stackTrace, sink) {
          if (logLabel != null) {
            debugPrint('$logLabel error: $error');
          }
          sink.add(fallback());
        },
      ),
    );
  }
}
