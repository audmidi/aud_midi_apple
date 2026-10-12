// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

@TestOn('mac-os')
library;

import 'dart:ffi';

import 'package:aud_midi_apple/aud_midi_apple.dart';
import 'package:aud_midi_core/aud_midi_core.dart';
import 'package:test/test.dart';

void main() {
  // Returns a presenter that answers [status] through the native callback.
  MidiBluetoothPickerPresenter answering(int status) => (done) {
    done.asFunction<void Function(int)>()(status);
    return 0;
  };

  group('showMidiBluetoothPickerNative()', () {
    test('is unsupported on macOS', () async {
      await expectLater(
        showMidiBluetoothPickerNative(),
        throwsA(isA<MidiUnsupported>()),
      );
    });

    test('completes when the picker is dismissed', () async {
      await showMidiBluetoothPickerNative(present: answering(0));
    });

    test('throws when no view controller can present it', () async {
      await expectLater(
        showMidiBluetoothPickerNative(present: answering(-4)),
        throwsA(isA<MidiUnsupported>()),
      );
    });
  });
}
