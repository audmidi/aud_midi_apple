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
