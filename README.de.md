# aud_midi_apple

Das macOS- und iOS-Backend von aud_midi: CoreMIDI über FFI und einen
kleinen C-Shim, Bluetooth-LE-MIDI über CoreBluetooth, die Netzwerk-Session
von iOS und Bonjour.

Teil der aud_midi-Familie, siehe [aud_midi](https://github.com/audmidi/aud_midi).

## Ziele

- CoreMIDI-Ports, virtuelle Endpoints, Hotplug, UMP in beide Richtungen
- OS-Zeitstempel beim Empfang, CoreMIDI-Scheduling beim Senden
- BLE-MIDI über CoreBluetooth und den Bluetooth-Treiber von CoreMIDI
- `MIDINetworkSession` auf iOS, Bonjour-Suche und -Ankündigung
- Kleiner C-Shim kopiert Pakete von den CoreMIDI-Threads
- Native Taps: ein C-Consumer, den der Receive-Thread von CoreMIDI aufruft
- BLE-Peripheral über CBPeripheralManager

## Stand

`AppleMidiBackend` (Name `coremidi`) implementiert `MidiBackend` aus
[aud_midi_core](https://github.com/audmidi/aud_midi_core):

- Ports: Jede CoreMIDI-Quelle ist ein Eingang, jedes Ziel ein Ausgang,
  auch die virtuellen Endpoints anderer Apps und Geräte, die offline sind
  (`MidiPortState.offline`, so behält ein wieder eingestecktes Gerät seine
  Port-IDs). IDs lauten `coremidi:<unique id>`; Ports sind nach Gerät →
  Entity → Endpoint gruppiert, mit `index`; der Transport ergibt sich aus
  dem Treiber (USB, Bluetooth, Netzwerk, IAC-Bus = software, keiner =
  virtual); UMP-Gruppen kommen aus `kMIDIPropertyUMPActiveGroupBitmap`.
- I/O: Alle Ports tauschen UMP-Wörter im Protokoll ihres Endpoints aus.
  Jede Quelle hängt am MIDI-1.0- oder am MIDI-2.0-Eingangsport, je nach
  ihrem Protokoll, damit CoreMIDI nie übersetzt. Eingänge tragen die
  CoreMIDI-Zeitstempel auf der Paketuhr; künftige Pakete übernimmt der
  CoreMIDI-Scheduler. Kein Port meldet `cancelPending`: Das Backend ruft
  `MIDIFlushOutput` nie auf (siehe unten), die Engine verwirft also nur
  ihre eigene Software-Warteschlange, und Pakete, die schon bei CoreMIDI
  liegen, werden gesendet.
- Virtuelle Ports (`virtualPorts` ist das Backend selbst): Quellen und
  Ziele mit Protokoll, Unique ID, Hersteller, Modell und Gruppen.
- Hotplug: CoreMIDI-Benachrichtigungen → Neu-Aufzählung → hinzugekommene,
  entfernte und geänderte Ports; ein offener Eingang verbindet sich neu,
  wenn seine Quelle zurückkommt.
- Native Taps (`MidiNativeTapBackend` aus aud_midi_core): `attachNativeTap`
  verbindet die Quelle bei Bedarf und trägt den Tap in einen Slot des Shims
  ein; der Receive-Thread ruft ihn je `MIDIEventPacket` mit den UMP-Wörtern
  und dem Zeitstempel in Nanosekunden der Host-Uhr auf
  (`mach_absolute_time`, mit `mach_timebase_info` in 128-Bit-Ganzzahlen
  umgerechnet; 0 wird zur Ankunftszeit). Der Benachrichtigungs-Thread
  meldet `gone`, wenn die Quelle entfernt wird oder offline geht, einmal je
  Lücke. Ein Tap hält die Quelle ohne Dart-Listener verbunden, bleibt
  angehängt, solange die Quelle weg ist, und folgt ihr zu ihrem neuen
  Endpoint; `detachNativeTap` kehrt zurück, nachdem der letzte Aufruf des
  Taps zurückgekehrt ist, und gibt nie einen Slot frei, den ein Aufruf noch
  berühren könnte (bei einem Timeout bleibt er belegt, eine Diagnose meldet
  es). Ein Datenaufruf, der den Slot belegt vorfindet, verwirft seine
  Pakete und zählt sie, der Pfad nimmt also nie ein Lock; `gone` geht nie
  verloren.
- Bluetooth (macOS 13, iOS 16): nach dem BLE-MIDI-Service suchen,
  verbinden, `MIDIBluetoothDriverActivateAllConnections`, auf das
  CoreMIDI-Gerät warten, die CoreBluetooth-Verbindung beenden. Die
  Aktivierung wiederholt sich alle `activateInterval` (1 s), solange
  gewartet wird, damit ein Gerät, das um Kopplung bittet, online kommt,
  sobald der Nutzer zugestimmt hat; der CoreMIDI-Name darf sich vom
  beworbenen durch Groß-/Kleinschreibung oder ein Suffix unterscheiden. Auf
  iOS zeigt `showSystemDevicePicker()` (`MidiBluetoothSystemPicker` aus
  aud_midi_core) Apples `CABTMIDICentralViewController`, der ohne diese
  Schritte koppelt und verbindet; `showMidiBluetoothPickerNative` übernimmt
  das Anzeigen, und der Parameter `bluetoothPicker` von `AppleMidiBackend`
  ersetzt es, etwa in Tests. Auf macOS wirft der Picker `MidiUnsupported`,
  ebenso `showMidiBluetoothPickerNative` außerhalb von Apple-Plattformen,
  die keinen Shim bauen; sein Parameter `present` ist optional.
- Netzwerk: `MIDINetworkSession` auf iOS; `browse()` über DNS-SD;
  `MidiBonjourAdvertiser` implementiert `MidiServiceAdvertiser`.

Geprüft auf macOS 27 (Apple Silicon) mit echtem CoreMIDI, ohne Mocks:

| Prüfung | Ergebnis |
| --- | --- |
| Virtuelle Quelle → Eingangsport, MIDI 1.0 und 2.0, SysEx7/8 über mehrere Pakete | Wörter und Reihenfolge unverändert, Zeitstempel exakt (0 µs) |
| Ausgangsport → virtuelles Ziel | Wörter unverändert |
| Geplantes Senden, 50 Noten im Abstand von 10 ms, 100 ms voraus | 12–57 µs zu spät in zwei Läufen, Mediane 26 und 30 µs |
| `cancelPending` | kein System Reset; die geplante Note kommt trotzdem an |
| `MIDIFlushOutput` auf ein virtuelles Ziel | System Reset geliefert (der Grund für die Regel oben) |
| Hotplug virtueller Endpoints | Ereignisse nach etwa 310–330 ms |
| `stop()` während eines laufenden Bursts | kein Absturz, danach nichts mehr geliefert |
| Bonjour | Dienst anmelden, finden, auflösen und verlieren |
| Build-Hook | dylib für macOS arm64/x64, iOS-Gerät und -Simulator; sonst nichts |
| Nativer Tap an einer virtuellen Quelle | jedes Paket mit seiner Host-Zeit (Lieferverzögerung 35 µs), nichts bei Dart ohne Listener, beides mit einem |
| Tap während eines Bursts gelöst | 2435 Aufrufe davor, keiner nach der Rückkehr des Detach, kein überlappender Aufruf |
| `gone` | 290 ms nach dem Freigeben der virtuellen Quelle; der Tap überlebt ihre Rückkehr unter derselben Unique ID |

Echt ausgeführt im iOS-26.2-Simulator (iPhone 17 Pro) über eine
Wegwerf-Flutter-App, die vom Paket abhängt:

| Prüfung | Ergebnis |
| --- | --- |
| Virtuelle Quelle → Eingangsport, MIDI 2.0 mit SysEx8 | Wörter unverändert, Zeitstempel exakt |
| Geplantes Senden, 30 Noten im Abstand von 10 ms | 6–45 µs zu spät, Median 11–20 µs |
| `MIDINetworkSession` | aktivieren, Änderungsbenachrichtigungen, Session-Ports, Bonjour findet die Session, verbinden, trennen, Zustand wiederhergestellt |
| CoreBluetooth | Central öffnet, meldet „unsupported“ (kein Bluetooth im Simulator), Suche endet leer |

Geprüft auf einem iPhone 16 Pro Max mit einem Roland GO:KEYS über USB in
der Keyboard-Session von Ticket 26 von aud_audio:

| Prüfung | Ergebnis |
| --- | --- |
| Port offline und zurück (USB während eines gehaltenen Akkords ab- und wieder angesteckt) | still 25 ms, nachdem der Port offline ging; Eingabe spielte wieder 9 ms, nachdem er unter seiner ID zurückkam |

Nicht geprüft: ein echtes BLE-MIDI-Peripheriegerät (keins vorhanden; in
`dart test` bricht ein `CBCentralManager` den Prozess mangels
Bluetooth-Nutzungsbeschreibung ab) und eine Netzwerk-Session mit echtem
Gegenüber. Ihre Logik ist mit Fakes getestet.

Erkenntnisse, die das Verhalten bestimmen:

- Auf iOS ist `networkName` der Session nil, bis der MIDI-Server die
  Session eingerichtet hat, obwohl das SDK es als nicht-null deklariert,
  und ihr Port folgt kurz nach dem Aktivieren; das Backend liest beides
  tolerant.
- `MIDINetworkSession` tut auf macOS nichts: `defaultSession` ist nil.
  Dort ist `network` null; macOS-Sessions richtet man im
  Audio-MIDI-Setup ein, sie erscheinen als Ports, und das eigene AppleMIDI
  des Pakets lässt sich mit `MidiBonjourAdvertiser` ankündigen.
- `MIDIFlushOutput(destination)` liefert einem virtuellen Ziel einen
  System Reset (`0xFF`, als UMP `0x10ff0000` bei MIDI 1.0 und 2.0): immer,
  auch wenn nichts anstand, das Ziel nie etwas empfangen hat oder ein
  anderer Prozess es auslöst. Eine Synthesizer-App würde bei jedem Abbruch
  zurückgesetzt, deshalb unterstützt kein Port `cancelPending`. Hier war
  kein treibereigenes Ziel online (IAC-Bus aus, Geräte ausgesteckt, keine
  Netzwerk-Session), und keins wurde aktiviert; treibereigene Ziele folgen
  daher derselben Regel. `MIDIFlushOutput(0)` verwirft anstehende Pakete
  ohne Reset, aber für alle Ziele zugleich.
- CoreMIDI-Benachrichtigungen kommen nur auf dem Run Loop des Threads an,
  der den Client erzeugt hat, etwa 300 ms nach der Änderung; der Shim
  betreibt diesen Run Loop selbst.
- `MIDIUMPEndpointManager` (macOS 15, iOS 18) darf nur auf dem
  Haupt-Thread benutzt werden und listete in einem Kommandozeilenprozess
  die UMP-Endpoints anderer Prozesse nicht; `endpoint` und
  `functionBlocks` bleiben leer.
- `MIDIDestinationCreateWithProtocol` bricht den Prozess bei anderen
  Protokollen als 1 und 2 ab; der Shim weist sie zurück.

## Installation

```bash
dart pub add aud_midi_apple
```

iOS-Apps tragen in `Info.plist` ein: `UIBackgroundModes` mit `audio`
(virtuelle Endpoints) und `bluetooth-central` (Bluetooth im Hintergrund),
`NSBluetoothAlwaysUsageDescription`, `NSLocalNetworkUsageDescription` und
`NSBonjourServices` mit `_apple-midi._udp`. Sandboxed macOS-Apps brauchen
die Entitlements `com.apple.security.device.bluetooth`,
`com.apple.security.network.client` und
`com.apple.security.network.server`.

## Dokumentation

- [Der Plan der aud_midi-Familie](https://github.com/audmidi/aud_midi_pm/blob/main/doc/2026-Q4/tickets/2026-10-06-aud_midi_01-initial-midi-implementation.md)
- [Guides](doc/guides/)

## Code-Beispiele

```dart
import 'package:aud_midi_apple/aud_midi_apple.dart';
import 'package:aud_midi_core/aud_midi_core.dart';
import 'package:aud_midi_standard/aud_midi_standard.dart';

Future<void> main() async {
  final backend = AppleMidiBackend();
  await backend.start(_PrintingHost());

  for (final port in backend.ports.where((port) => port.isInput)) {
    await backend.openPort(port.id);
  }

  final source = await backend.create(
    MidiVirtualPortSpec(
      name: 'aud_midi_apple example',
      direction: MidiDirection.output,
      protocol: MidiProtocol.midi2,
    ),
  );
  const clock = MidiSystemClock();
  await backend.send(
    source.id,
    MidiUmpPacket(words: const [0x40903c00, 0xc8000000], time: clock.now()),
  );
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

Auf iOS koppelt und verbindet der Bluetooth-MIDI-Gerätepicker des Systems
ein Peripheriegerät; seine Ports erscheinen danach:

```dart
final picker = backend.bluetooth! as MidiBluetoothSystemPicker;
await picker.showSystemDevicePicker(); // CABTMIDICentralViewController
```

Das vollständige Beispiel steht in [example/aud_midi_apple_example.dart](example/aud_midi_apple_example.dart).

## Funktionsweise

```text
MIDI-Isolate                     │ native Threads
AppleMidiBackend (Logik)         │
 ├─ MidiCoreMidi ── FFI ─────────┼─ C-Shim: Run-Loop-Thread mit allen
 │   (ffigen-C-Bindings)         │  Clients, Receive-Blocks → Ringpuffer
 │                               │  → Signal über NativeCallable.listener
 ├─ MidiAppleBluetoothBackend    │
 │   ├─ MidiCoreBluetooth ── ObjC-Bindings ── CBCentralManager (Queue)
 │   └─ showMidiBluetoothPickerNative ─ FFI ─ ObjC: CABTMIDICentralViewController (iOS)
 └─ MidiAppleNetworkBackend      │
     ├─ MidiAppleNetworkSession ── ObjC-Bindings ── MIDINetworkSession
     └─ MidiBonjourBrowser ─ FFI ─┼─ C-Shim: DNS-SD auf einer Dispatch-Queue
```

- `src/aud_midi_apple.c` betreibt einen CFRunLoop-Thread, auf dem er jeden
  MIDI-Client erzeugt, denn CoreMIDI schickt Benachrichtigungen an den Run
  Loop des erzeugenden Threads, und ein Dart-Prozess hat keinen. Er hält
  einen Client, der nie freigegeben wird, weil das Freigeben des letzten
  Clients die Verbindung zum MIDI-Server beenden kann.
- Zwei Eingangsports je Client (MIDI 1.0 und MIDI 2.0). Der Receive-Block
  kopiert jedes `MIDIEventPacket` mit dem Ref-Con der Quelle, Zeitstempel
  und Ankunftszeit in einen Ringpuffer und signalisiert Dart; die
  Leseseite ist lock-frei, die Schreiber reihen sich an einem
  `os_unfair_lock` an. Bei Überlauf fällt die neueste Event-Liste weg und
  zählt als `queueOverflow`-Diagnose.
- `src/aud_midi_apple_tap.c` hält die Tap-Slots eines Clients, adressiert
  über den Ref-Con der verbundenen Quelle: je Slot ein Zähler der laufenden
  Aufrufe und ein Belegt-Flag, `gone`-Markierungen, die
  128-Bit-Tick-Umrechnung und ein Probe-Tap für die Tests. Er weiß nichts
  von CoreMIDI, deshalb lässt `scripts/test-native.js` seinen Test unter
  ASan/UBSan, ThreadSanitizer und, mit LLVM aus Homebrew,
  RealtimeSanitizer laufen (`node scripts/test-native.js`).
- `src/aud_midi_apple_bluetooth_picker.m` zeigt den
  `CABTMIDICentralViewController` in einem Navigation-Controller mit
  Fertig-Button auf dem Haupt-Thread vom Key Window aus und signalisiert
  Dart beim Schließen; `hook/build.dart` linkt CoreAudioKit und UIKit nur
  auf iOS.
- `stop()` löst die Taps, trennt und gibt frei, dann markiert der Shim den
  Client als geschlossen und wartet, bis kein Callback mehr läuft, bevor
  Dart den `NativeCallable` schließt.
- Mach-Ticks werden zu Mikrosekunden (`mach_timebase_info`) und dann über
  `MidiClockMapper` zur Paketuhr, neu abgeglichen alle 10 s und bei
  Hotplug.
- Die reine Dart-Logik spricht nur über `MidiCoreMidi`,
  `MidiCoreBluetooth`, `MidiAppleNetworkSession`, `MidiBonjourBrowser` und
  die Picker-Funktion mit der nativen Schicht; die Tests ersetzen sie durch
  Fakes. Die nativen
  Implementierungen werden auf macOS gegen das echte System getestet.
- `hook/build.dart` übersetzt den Shim und die von ffigen erzeugten
  Objective-C-Trampoline mit `native_toolchain_c` für macOS und iOS und
  tut auf anderen Systemen nichts. CoreBluetooth wird zur Laufzeit
  geladen, nicht gelinkt.

Die Bindings nach Änderungen am Shim oder an den Konfigurationen neu
erzeugen (ffigen 23 liest YAML noch, erklärt es aber für veraltet):

```bash
dart run ffigen --config ffigen.yaml       # CoreMIDI, CoreFoundation, Shim
dart run ffigen --config ffigen_objc.yaml  # CoreBluetooth, MIDINetworkSession
```

Tests, die die globale Netzwerk-Session ändern, laufen nur mit
`AUD_MIDI_TEST_NETWORK=1`; `AUD_MIDI_REPORT=<Datei>` schreibt die
gemessenen Loopback-Zeiten als JSON. `node scripts/check-notices.js` prüft
die Lizenz-Header und `NOTICES.md`.

## Mitwirken

Siehe [doc/guides/develop-guide.md](doc/guides/develop-guide.md).
