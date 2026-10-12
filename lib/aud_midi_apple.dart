// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

/// The macOS and iOS backend of aud_midi: CoreMIDI ports, virtual
/// endpoints, hotplug and scheduled UMP I/O through FFI, Bluetooth LE MIDI
/// through CoreBluetooth, the network session of iOS and Bonjour.
library;

export 'src/apple_midi_backend.dart';
export 'src/bluetooth/midi_apple_bluetooth_backend.dart';
export 'src/bluetooth/midi_bluetooth_picker_native.dart';
export 'src/bluetooth/midi_core_bluetooth.dart';
export 'src/bluetooth/midi_core_bluetooth_native.dart';
export 'src/core_midi/midi_core_midi.dart';
export 'src/core_midi/midi_core_midi_native.dart';
export 'src/core_midi/midi_core_midi_setup.dart';
export 'src/core_midi/midi_mach_timebase.dart';
export 'src/network/midi_apple_network_backend.dart';
export 'src/network/midi_apple_network_session.dart';
export 'src/network/midi_apple_network_session_native.dart';
export 'src/network/midi_bonjour_advertiser.dart';
export 'src/network/midi_bonjour_browser.dart';
export 'src/network/midi_bonjour_browser_native.dart';
