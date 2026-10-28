# aud_midi_apple

English | [Deutsch](README.de.md)

CoreMIDI, CoreBluetooth and network session backend for aud_midi on macOS
and iOS. CoreMIDI is reached through FFI and a small C shim, Bluetooth LE
MIDI through CoreBluetooth, the network session of iOS and Bonjour through
their frameworks.

Part of the aud_midi family, see [aud_midi](https://github.com/audmidi/aud_midi).

## Motivation

Dart and Flutter apps should reach the MIDI devices of their users on
macOS and iOS through the same API as on every other platform, without
platform channels or native code of their own, and with timing that a
busy app cannot disturb: input keeps the timestamp CoreMIDI gave it,
output is scheduled by CoreMIDI. Other apps should see the app as a MIDI
device of its own, as virtual endpoints, as a network session and as a
Bluetooth LE peripheral. The backend aims for:

- CoreMIDI ports, virtual endpoints, hotplug, UMP in both directions
- OS timestamps on input, CoreMIDI scheduling on output
- BLE MIDI via CoreBluetooth and the CoreMIDI Bluetooth driver
- `MIDINetworkSession` on iOS, Bonjour browsing and advertising
- Small C shim copies packets off CoreMIDI threads
- Native taps: a C consumer called on CoreMIDI's receive thread
- BLE peripheral through CBPeripheralManager

## Installation

```bash
dart pub add aud_midi_apple
```

iOS apps declare in `Info.plist`: `UIBackgroundModes` with `audio`
(virtual endpoints) and `bluetooth-central` (Bluetooth in the background),
`NSBluetoothAlwaysUsageDescription`, `NSLocalNetworkUsageDescription` and
`NSBonjourServices` with `_apple-midi._udp`. Sandboxed macOS apps need the
entitlements `com.apple.security.device.bluetooth`,
`com.apple.security.network.client` and
`com.apple.security.network.server`.

## Usage

`AppleMidiBackend` (name `coremidi`) implements `MidiBackend` of
[aud_midi_core](https://github.com/audmidi/aud_midi_core). The example
lists the CoreMIDI ports, opens all inputs and plays a MIDI 2.0 note on a
virtual source that other apps can listen to:

```dart
import 'package:aud_midi_apple/aud_midi_apple.dart';
import 'package:aud_midi_core/aud_midi_core.dart';
import 'package:aud_midi_standard/aud_midi_standard.dart';

// Lists the CoreMIDI ports, opens all inputs and plays a MIDI 2.0 note on a
// virtual source that other apps can listen to. In apps, the engine of
// aud_midi_core hosts the backend; this host just prints.
Future<void> main() async {
  final backend = AppleMidiBackend();
  await backend.start(_PrintingHost());

  for (final port in backend.ports) {
    print(
      '${port.id} ${port.direction.name} ${port.name} '
      '(${port.transport.name}, ${port.protocol.name}, ${port.state.name})',
    );
    if (port.isInput) await backend.openPort(port.id);
  }

  final source = await backend.create(
    MidiVirtualPortSpec(
      name: 'aud_midi_apple example',
      direction: MidiDirection.output,
      protocol: MidiProtocol.midi2,
    ),
  );
  // MIDI 2.0 Note On and Note Off of middle C on group 0, channel 0. A
  // virtual source sends at once; the engine schedules for such ports.
  const clock = MidiSystemClock();
  await backend.send(
    source.id,
    MidiUmpPacket(words: const [0x40903c00, 0xc8000000], time: clock.now()),
  );
  await Future<void>.delayed(const Duration(milliseconds: 500));
  await backend.send(
    source.id,
    MidiUmpPacket(words: const [0x40803c00, 0x00000000], time: clock.now()),
  );

  await Future<void>.delayed(const Duration(seconds: 1));
  await backend.stop();
}

final class _PrintingHost implements MidiBackendHost {
  @override
  final MidiClock clock = const MidiSystemClock();

  @override
  void portsChanged(List<MidiPortEvent> events) => events.forEach(print);

  @override
  void received(MidiPortId port, MidiPacket packet) => print('$port $packet');

  @override
  void diagnostic(MidiDiagnostic diagnostic) => print(diagnostic);
}
```

The snippet runs on macOS and iOS only; it is
[example/aud_midi_apple_example.dart](example/aud_midi_apple_example.dart).

On iOS the Bluetooth MIDI device picker of the system pairs and connects a
peripheral; its ports appear afterwards:

```dart
final picker = backend.bluetooth! as MidiBluetoothSystemPicker;
await picker.showSystemDevicePicker(); // CABTMIDICentralViewController
```

## Limitations

- No port reports `cancelPending`: the backend never calls
  `MIDIFlushOutput`, because `MIDIFlushOutput(destination)` delivers a
  System Reset to a virtual destination (see Status), so the engine cancels
  only its own software queue, and packets already handed to CoreMIDI are
  sent.
- `network` is null on macOS: `MIDINetworkSession` does nothing there,
  `defaultSession` is nil. macOS sessions are set up in Audio MIDI Setup
  and appear as ports, and the package's own AppleMIDI can be announced
  with `MidiBonjourAdvertiser`.
- `endpoint` and `functionBlocks` stay empty: `MIDIUMPEndpointManager`
  (macOS 15, iOS 18) may only be used on the main thread and did not list
  the UMP endpoints of other processes in a command-line process.
- On macOS the Bluetooth picker throws `MidiUnsupported`, as
  `showMidiBluetoothPickerNative` does off Apple platforms, which build no
  shim; its `present` parameter is optional.
- A tap that does not return in time leaks its slot and reports a
  diagnostic; the slot is never freed while a call may still touch it. A
  data call that finds the slot busy drops its packets and counts them, so
  the path never takes a lock; `gone` is never dropped.
- The shim refuses protocols other than 1 and 2, because
  `MIDIDestinationCreateWithProtocol` aborts the process for them.
- Not verified: a real BLE-MIDI peripheral (none here; in `dart test` a
  `CBCentralManager` aborts the process for lack of a Bluetooth usage
  description) and a network session with a real peer. Their logic is
  tested with fakes.

## Documentation

- [The plan of the aud_midi family](https://github.com/audmidi/aud_midi_pm/blob/main/doc/2026-Q4/tickets/2026-10-06-aud_midi_01-initial-midi-implementation.md)
- [Guides](doc/guides/)

## How it works

```text
MIDI isolate                     │ native threads
AppleMidiBackend (logic)         │
 ├─ MidiCoreMidi ── FFI ─────────┼─ C shim: run loop thread with all
 │   (ffigen C bindings)         │  clients, receive blocks → ring buffer
 │                               │  → NativeCallable.listener signal
 ├─ MidiAppleBluetoothBackend    │
 │   ├─ MidiCoreBluetooth ── ObjC bindings ── CBCentralManager (queue)
 │   └─ showMidiBluetoothPickerNative ─ FFI ─ ObjC: CABTMIDICentralViewController (iOS)
 └─ MidiAppleNetworkBackend      │
     ├─ MidiAppleNetworkSession ── ObjC bindings ── MIDINetworkSession
     └─ MidiBonjourBrowser ─ FFI ─┼─ C shim: DNS-SD on a dispatch queue
```

- `src/aud_midi_apple.c` owns one CFRunLoop thread on which it creates
  every MIDI client, because CoreMIDI posts notifications to the run loop
  of the creating thread, and a Dart process has none. It keeps a client
  that is never disposed, since disposing the last client may end the
  connection to the MIDI server.
- Two input ports per client (MIDI 1.0 and MIDI 2.0). The receive block
  copies each `MIDIEventPacket` with the source's ref con, timestamp and
  arrival time into a ring buffer and signals Dart; the consumer side is
  lock-free, producers serialise on an `os_unfair_lock`. Overflow drops
  the newest event list and counts it as a `queueOverflow` diagnostic.
- `src/aud_midi_apple_tap.c` holds the tap slots of a client, keyed by
  the ref con of the connected source: an in-flight count and a busy flag
  per slot, `gone` marks, the 128-bit tick conversion and a probe tap for
  the tests. It knows nothing of CoreMIDI, so `scripts/test-native.js`
  runs its test under ASan/UBSan, ThreadSanitizer and, with LLVM from
  Homebrew, RealtimeSanitizer (`node scripts/test-native.js`).
- `src/aud_midi_apple_bluetooth_picker.m` presents the
  `CABTMIDICentralViewController` in a navigation controller with a Done
  button on the main thread from the key window and signals Dart on its
  dismissal; `hook/build.dart` links CoreAudioKit and UIKit on iOS only.
- `stop()` detaches the taps, disconnects and disposes, then the shim
  marks the client closed and waits until no callback is in flight before
  Dart closes the `NativeCallable`.
- Mach ticks become microseconds (`mach_timebase_info`) and then the
  package clock through `MidiClockMapper`, resynced every 10 s and on
  hotplug.
- The pure-Dart logic talks to the native layer only through
  `MidiCoreMidi`, `MidiCoreBluetooth`, `MidiAppleNetworkSession`,
  `MidiBonjourBrowser` and the picker function; the tests replace them by
  fakes. The native implementations are tested against the real system on
  macOS.
- `hook/build.dart` compiles the shim and the Objective-C trampolines
  generated by ffigen with `native_toolchain_c` for macOS and iOS and does
  nothing on other systems. CoreBluetooth is loaded at runtime, not
  linked.

In detail:

- Ports: every CoreMIDI source is an input, every destination an output,
  including the virtual endpoints of other apps and offline devices
  (`MidiPortState.offline`, so a re-plugged device keeps its port ids).
  Ids are `coremidi:<unique id>`; ports are grouped device → entity →
  endpoint with `index`; the transport comes from the driver (USB,
  Bluetooth, network, IAC bus = software, none = virtual); UMP groups
  come from `kMIDIPropertyUMPActiveGroupBitmap`.
- I/O: all ports exchange UMP words in the protocol of their endpoint.
  Each source is connected to the MIDI 1.0 or the MIDI 2.0 input port
  that matches its protocol, so CoreMIDI never translates. Inputs carry
  the CoreMIDI timestamps on the package clock; future packets go to the
  CoreMIDI scheduler.
- Virtual ports (`virtualPorts` is the backend): sources and destinations
  with protocol, unique id, manufacturer, model and groups.
- Hotplug: CoreMIDI notifications → re-enumeration → added, removed and
  changed ports; an open input reconnects when its source comes back.
- Native taps (`MidiNativeTapBackend` of aud_midi_core): `attachNativeTap`
  connects the source when needed and registers the tap in a slot of the
  shim; the receive thread calls it once per `MIDIEventPacket` with the
  UMP words and the timestamp in nanoseconds of the host clock
  (`mach_absolute_time`, converted with `mach_timebase_info` in 128-bit
  integers; 0 becomes the arrival time). The notification thread reports
  `gone` when the source is removed or goes offline, once per gap. A tap
  keeps the source connected without Dart listeners, stays attached while
  the source is away and follows it to its new endpoint; `detachNativeTap`
  returns after the last call of the tap returned.
- Bluetooth (macOS 13, iOS 16): scan for the BLE-MIDI service, connect,
  `MIDIBluetoothDriverActivateAllConnections`, wait for the CoreMIDI
  device, end the CoreBluetooth connection. The activation repeats every
  `activateInterval` (1 s) while waiting, so a peripheral that asks for
  pairing comes online once the user accepted; the CoreMIDI name may
  differ from the advertised one by case or a suffix. On iOS
  `showSystemDevicePicker()` (`MidiBluetoothSystemPicker` of aud_midi_core)
  presents Apple's `CABTMIDICentralViewController`, which pairs and
  connects without these steps; `showMidiBluetoothPickerNative` does the
  presenting, and the `bluetoothPicker` parameter of `AppleMidiBackend`
  replaces it, e.g. in tests.
- Network: `MIDINetworkSession` on iOS; `browse()` through DNS-SD;
  `MidiBonjourAdvertiser` implements `MidiServiceAdvertiser`.

## Status

Before 1.0 — the API may change between minor versions.

Verified on macOS 27 (Apple silicon) with real CoreMIDI, no mocks:

| Check | Result |
| --- | --- |
| Virtual source → input port, MIDI 1.0 and 2.0, SysEx7/8 across packets | words and order unchanged, timestamps exact (0 µs) |
| Output port → virtual destination | words unchanged |
| Scheduled send, 50 notes 10 ms apart, 100 ms ahead | 12–57 µs late over two runs, medians 26 and 30 µs |
| `cancelPending` | no System Reset; the scheduled note still arrives |
| `MIDIFlushOutput` on a virtual destination | System Reset delivered (the reason for the rule above) |
| Hotplug of virtual endpoints | events after about 310–330 ms |
| `stop()` while a burst is in flight | no crash, nothing delivered afterwards |
| Bonjour | register, browse, resolve and lose a service |
| Build hook | dylib for macOS arm64/x64, iOS device and simulator; nothing elsewhere |
| Native tap on a virtual source | every packet with its host time (delivery delay 35 µs), nothing at Dart without a listener, both with one |
| Tap detached under a burst | 2435 calls before, none after the detach returned, no overlapping call |
| `gone` | 290 ms after the virtual source was disposed; the tap survives its return under the same unique id |

Run for real on the iOS 26.2 simulator (iPhone 17 Pro) by a throwaway
Flutter app that depends on the package:

| Check | Result |
| --- | --- |
| Virtual source → input port, MIDI 2.0 with SysEx8 | words unchanged, timestamps exact |
| Scheduled send, 30 notes 10 ms apart | 6–45 µs late, median 11–20 µs |
| `MIDINetworkSession` | enable, change notifications, session ports, Bonjour sees the session, connect, disconnect, state restored |
| CoreBluetooth | central opens, reports "unsupported" (no Bluetooth in the simulator), scan ends empty |

Verified on an iPhone 16 Pro Max with a Roland GO:KEYS over USB in the
keyboard session of ticket 26 of aud_audio:

| Check | Result |
| --- | --- |
| Port offline and back (USB unplugged and replugged while a chord was held) | silent 25 ms after the port went offline; input played again 9 ms after it returned under its id |

Findings that shape the behaviour:

- On iOS the session's `networkName` is nil until the MIDI server set
  the session up, although the SDK declares it non-null, and its port
  follows shortly after enabling; the backend reads both tolerantly.
- `MIDINetworkSession` does nothing on macOS: `defaultSession` is nil.
  There `network` is null; macOS sessions are set up in Audio MIDI Setup
  and appear as ports, and the package's own AppleMIDI can be announced
  with `MidiBonjourAdvertiser`.
- `MIDIFlushOutput(destination)` delivers a System Reset (`0xFF`, as
  UMP `0x10ff0000` for MIDI 1.0 and 2.0) to a virtual destination: always,
  also when nothing was pending, the destination never received anything
  or another process flushed it. A synthesizer app would reset at every
  cancel, so no port supports `cancelPending`. No driver-owned destination
  was online here (IAC bus off, devices unplugged, no network session) and
  none was enabled, so driver destinations follow the same rule.
  `MIDIFlushOutput(0)` drops pending packets without a reset, but for all
  destinations at once.
- CoreMIDI notifications arrive only on the run loop of the thread that
  created the client, about 300 ms after the change; the shim runs that
  run loop itself.
- `MIDIUMPEndpointManager` (macOS 15, iOS 18) may only be used on the
  main thread and did not list the UMP endpoints of other processes in a
  command-line process; `endpoint` and `functionBlocks` stay empty.
- `MIDIDestinationCreateWithProtocol` aborts the process for protocols
  other than 1 and 2; the shim refuses them.

## Contributing

See [doc/guides/develop-guide.md](doc/guides/develop-guide.md).

### Regenerate the bindings

Regenerate the bindings after changing the shim or the configurations
(ffigen 23 still reads YAML, which it deprecates):

```bash
dart run ffigen --config ffigen.yaml       # CoreMIDI, CoreFoundation, shim
dart run ffigen --config ffigen_objc.yaml  # CoreBluetooth, MIDINetworkSession
```

### Run the tests

Tests that change the global network session only run with
`AUD_MIDI_TEST_NETWORK=1`; `AUD_MIDI_REPORT=<file>` writes the measured
loopback timings as JSON. `node scripts/check-notices.js` checks the
license headers and `NOTICES.md`.

## License

MIT — see [LICENSE](LICENSE).
