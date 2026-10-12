# Changelog

## Unreleased

### Added

- Add native taps on CoreMIDI's receive thread

- Tap slots in the C shim with a count of calls in flight and a busy flag instead of a lock; a detach returns after the last call

- Timestamps in ns of the host clock, converted in 128-bit integers; GONE when a source disappears or goes offline

- AppleMidiBackend implements MidiNativeTapBackend; native tests under ASan/UBSan, RealtimeSanitizer and ThreadSanitizer; NOTICES and the notices check

- Add the iOS Bluetooth MIDI picker and the review fixes

- MidiBluetooth.showSystemDevicePicker presents CABTMIDICentralViewController on iOS

- The Bluetooth connect repeats the activation while it waits and matches names loosely; a timeout says what did not appear

- A tap slot leaked by a timed-out detach no longer hides a new tap of the same ref con

- Add review fixes of ticket 26

- README.de.md carries the native-tap additions of README.md

- Both READMEs document showSystemDevicePicker, activateInterval, bluetoothPicker and showMidiBluetoothPickerNative

- The USB offline and hot-plug path verified on the iPhone 16 Pro Max with a Roland GO:KEYS

- Bluetooth names match exactly first, then by prefix, by content only from three characters on

- stop() detaches the taps through detachNativeTap, so a leaked slot reports a diagnostic

- attachNativeTap resolves its target in _tapTarget and throws once

- aud_midi_apple_timebase reads the cached timebase; check-notices.js compares file URLs and uses node: imports

- test/native/aud_midi_apple_tap_test.dart runs scripts/test-native.js

- aud_midi_core ^0.2.0

- Add independent constraints on the aud_midi packages

## 0.1.0 - 2026-10-07

### Added

- Add boilerplate
- Add package dependencies

### Changed

- Upgrade dependencies
- Move the plan to aud_midi_pm
- Rename the PM repo to aud_midi_pm and move the plan there
- Use git dependencies and set publish_to none
- Implement the CoreMIDI backend for macOS and iOS
- Reference the aud_midi packages on pub.dev and the audmidi organization
- Plan BLE peripheral support

## 0.0.0 - 2026-10-06

- Initial boilerplate
