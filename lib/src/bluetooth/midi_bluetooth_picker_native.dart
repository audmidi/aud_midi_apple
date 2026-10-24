// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import '../native/aud_midi_apple_bindings.g.dart' as native;
import 'midi_apple_bluetooth_backend.dart';

/// Presents the native picker and calls `done` with its result; returns 0 or
/// the error of a picker that cannot be shown.
typedef MidiBluetoothPickerPresenter =
    int Function(Pointer<NativeFunction<Void Function(Int32)>> done);

// .............................................................................
/// Shows Apple's Bluetooth MIDI device picker
/// (`CABTMIDICentralViewController`) on the main thread of iOS and completes
/// once the user dismissed it.
///
/// Works from any isolate: the shim dispatches the presentation to the main
/// queue. Throws [MidiAppleBluetoothBackend.pickerUnsupported] on macOS or
/// when no view controller can present the picker, and off Apple platforms,
/// which build no shim (ticket 38). [present] replaces the shim in tests.
Future<void> showMidiBluetoothPickerNative({
  MidiBluetoothPickerPresenter? present,
}) {
  const unsupported = MidiAppleBluetoothBackend.pickerUnsupported;
  final presenter =
      present ??
      (Platform.isIOS || Platform.isMacOS
          ? native.aud_midi_apple_show_bluetooth_picker
          : null);
  if (presenter == null) return Future.error(unsupported);
  final completer = Completer<void>();
  late final NativeCallable<Void Function(Int32)> callable;
  callable = NativeCallable<Void Function(Int32)>.listener((int status) {
    callable.close();
    if (status == 0) {
      completer.complete();
    } else {
      completer.completeError(unsupported);
    }
  });
  if (presenter(callable.nativeFunction) != 0) {
    callable.close();
    return Future.error(unsupported);
  }
  return completer.future;
}
