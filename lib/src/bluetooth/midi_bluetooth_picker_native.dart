// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:async';
import 'dart:ffi';

import 'package:aud_midi_core/aud_midi_core.dart';

import '../native/aud_midi_apple_bindings.g.dart' as native;

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
/// queue. Throws a `MidiUnsupported` on macOS or when no view controller can
/// present the picker. [present] replaces the shim in tests.
Future<void> showMidiBluetoothPickerNative({
  MidiBluetoothPickerPresenter present =
      native.aud_midi_apple_show_bluetooth_picker,
}) {
  const unsupported = MidiUnsupported('Bluetooth MIDI device picker');
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
  if (present(callable.nativeFunction) != 0) {
    callable.close();
    return Future.error(unsupported);
  }
  return completer.future;
}
