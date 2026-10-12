// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:typed_data';

import 'package:aud_midi_apple/aud_midi_apple.dart';
import 'package:aud_midi_core/aud_midi_core.dart';
import 'package:aud_midi_standard/aud_midi_standard.dart';
import 'package:test/test.dart';

void main() {
  late _FakeCoreMidi coreMidi;
  late _FakeCentral central;
  late _FakeSession session;
  late _Host host;
  late AppleMidiBackend backend;

  MidiCoreMidiEndpoint endpoint(
    int ref, {
    String name = '',
    String driverOwner = '',
    bool isOffline = false,
    int protocol = 1,
  }) => (
    ref: ref,
    uniqueId: ref * 10,
    name: name,
    displayName: name,
    manufacturer: 'Maker',
    model: 'Model',
    driverOwner: driverOwner,
    isOffline: isOffline,
    isPrivate: false,
    protocol: protocol,
    groupBitmap: null,
  );

  MidiCoreMidiDevice device(
    int ref, {
    required String name,
    required String driverOwner,
    required List<MidiCoreMidiEndpoint> sources,
    List<MidiCoreMidiEndpoint> destinations = const [],
    bool isOffline = false,
  }) => (
    ref: ref,
    uniqueId: ref * 10,
    name: name,
    manufacturer: 'Maker',
    model: 'Model',
    driverOwner: driverOwner,
    isOffline: isOffline,
    entities: [(name: name, sources: sources, destinations: destinations)],
  );

  const usb = 'com.apple.AppleMIDIUSBDriver';
  const bluetooth = 'com.apple.AppleMIDIBluetoothDriver';
  final keysIn = endpoint(11, name: 'Keys In', driverOwner: usb);
  final keysOut = endpoint(12, name: 'Keys Out', driverOwner: usb, protocol: 2);
  final appOut = endpoint(21, name: 'App Out');

  MidiCoreMidiSnapshot snapshot({
    List<MidiCoreMidiDevice> devices = const [],
    List<MidiCoreMidiEndpoint> sources = const [],
  }) => (
    devices: [
      device(
        1,
        name: 'Keys',
        driverOwner: usb,
        sources: [keysIn],
        destinations: [keysOut],
      ),
      ...devices,
    ],
    sources: [keysIn, appOut, ...sources],
    destinations: [keysOut],
  );

  const keysInId = MidiPortId('coremidi:110');
  const keysOutId = MidiPortId('coremidi:120');
  const appOutId = MidiPortId('coremidi:210');

  MidiUmpPacket ump(List<int> words, MidiTime time) =>
      MidiUmpPacket(words: words, time: time);

  void signal(int bits) => coreMidi.signal!(bits);

  void notify(int messageId) {
    coreMidi.notifications.add((messageId: messageId, values: [7, 9, 0, 0, 0]));
    signal(MidiCoreMidi.notificationsSignal);
  }

  setUp(() async {
    coreMidi = _FakeCoreMidi()..setup = snapshot();
    central = _FakeCentral();
    session = _FakeSession();
    host = _Host();
    backend = AppleMidiBackend(
      coreMidi: coreMidi,
      coreBluetooth: central,
      networkSession: session,
      bonjourBrowser: _FakeBrowser.new,
      clientName: 'test',
      resyncInterval: const Duration(milliseconds: 1),
      bluetoothTimeout: const Duration(milliseconds: 20),
    );
    await backend.start(host);
    coreMidi.calls.clear();
  });

  tearDown(() => backend.stop());

  group('AppleMidiBackend', () {
    group('start(host)', () {
      test('opens the client and lists the ports', () async {
        expect(
          backend.ports.map((p) => p.id),
          equals([keysInId, keysOutId, appOutId]),
        );
        expect(backend.devices.single.name, 'Keys');
        expect(coreMidi.openedAs, 'test');
        await Future<void>.delayed(const Duration(milliseconds: 5));
        await expectLater(backend.start(host), throwsA(isA<StateError>()));
      });

      test('throws when CoreMIDI refuses the client', () async {
        final other = AppleMidiBackend(
          coreMidi: _FakeCoreMidi()..failures['open'] = -10830,
        );
        await expectLater(
          other.start(host),
          throwsA(isA<MidiNativeError>().having((e) => e.code, 'code', -10830)),
        );
        expect(other.ports, isEmpty);
        await other.stop();
        await expectLater(other.openPort(keysInId), throwsA(isA<StateError>()));
      });
    });

    group('stop()', () {
      test('disconnects inputs, disposes own ports and closes', () async {
        await backend.openPort(keysInId);
        await backend.create(
          MidiVirtualPortSpec(name: 'Own', direction: MidiDirection.output),
        );
        coreMidi
          ..calls.clear()
          ..failures['MIDIPortDisconnectSource'] = -1
          ..failures['MIDIEndpointDispose'] = -1;
        await backend.stop();
        expect(coreMidi.calls, equals(['dispose 500', 'close']));
        expect(backend.ports, isEmpty);
        await backend.stop();
        expect(coreMidi.calls, equals(['dispose 500', 'close']));
      });

      test('ignores signals that arrive afterwards', () async {
        final lateSignal = coreMidi.signal!;
        await backend.stop();
        coreMidi.packets.add(_packet(1, 0));
        lateSignal(MidiCoreMidi.packetsSignal);
        expect(coreMidi.packets, hasLength(1));
      });
    });

    group('openPort(port), closePort(port)', () {
      test('connect and disconnect an input once', () async {
        await backend.openPort(keysInId);
        await backend.openPort(keysInId);
        await backend.closePort(keysInId);
        await backend.closePort(keysInId);
        expect(coreMidi.calls, equals(['connect 11 1 1', 'disconnect 11 1']));
      });

      test('need no native call for outputs', () async {
        await backend.openPort(keysOutId);
        await backend.closePort(keysOutId);
        expect(coreMidi.calls, isEmpty);
      });

      test('throw for unknown ports', () async {
        for (final call in [backend.openPort, backend.closePort]) {
          await expectLater(
            call(const MidiPortId('coremidi:1')),
            throwsA(isA<MidiPortGone>()),
          );
        }
      });

      test('pass native errors on', () async {
        coreMidi.failures['MIDIPortConnectSource'] = -10842;
        await expectLater(
          backend.openPort(keysInId),
          throwsA(isA<MidiNativeError>()),
        );
      });
    });

    group('send(port, packet)', () {
      test('sends now or schedules on the mach clock', () async {
        final now = host.clock.now();
        await backend.send(keysOutId, ump([0x40903c00, 0xc8000000], now));
        await backend.send(
          keysOutId,
          ump([0x40803c00, 0], now + const Duration(microseconds: 500)),
        );
        expect(
          coreMidi.calls,
          equals([
            'send 12 2 0 40903c00 c8000000',
            'send 12 2 500000 40803c00 00000000',
          ]),
        );
      });

      test('emits from own virtual sources', () async {
        final own = await backend.create(
          MidiVirtualPortSpec(name: 'Own', direction: MidiDirection.output),
        );
        coreMidi.calls.clear();
        await backend.send(own.id, ump([0x20903c64], host.clock.now()));
        expect(coreMidi.calls, equals(['emit 500 1 0 20903c64']));
      });

      test('refuses bytes, inputs and unknown ports', () async {
        final own = await backend.create(
          MidiVirtualPortSpec(name: 'Own In', direction: MidiDirection.input),
        );
        await expectLater(
          backend.send(
            keysOutId,
            MidiBytesPacket(bytes: MidiBytes([0x90]), time: MidiTime.zero),
          ),
          throwsA(isA<ArgumentError>()),
        );
        for (final port in [keysInId, own.id]) {
          await expectLater(
            backend.send(port, ump([0x20903c64], MidiTime.zero)),
            throwsA(isA<MidiUnsupported>()),
          );
        }
        await expectLater(
          backend.send(const MidiPortId('x:1'), ump([0], MidiTime.zero)),
          throwsA(isA<MidiPortGone>()),
        );
      });
    });

    group('cancelPending(port)', () {
      test('never flushes CoreMIDI', () async {
        final own = await backend.create(
          MidiVirtualPortSpec(name: 'Own', direction: MidiDirection.output),
        );
        coreMidi.calls.clear();
        await backend.cancelPending(keysOutId);
        await backend.cancelPending(own.id);
        expect(coreMidi.calls, isEmpty);
        expect(
          backend.ports.where((p) => p.capabilities.cancelPending),
          isEmpty,
        );
      });

      test('throws for inputs and unknown ports', () async {
        await expectLater(
          backend.cancelPending(keysInId),
          throwsA(isA<MidiUnsupported>()),
        );
        await expectLater(
          backend.cancelPending(const MidiPortId('coremidi:1')),
          throwsA(isA<MidiPortGone>()),
        );
      });
    });

    group('create(spec), remove(port)', () {
      test('create a source with its description', () async {
        final port = await backend.create(
          MidiVirtualPortSpec(
            name: 'Own',
            direction: MidiDirection.output,
            protocol: MidiProtocol.midi2,
            uniqueId: 4242,
            groups: const [0, 3],
            manufacturer: 'Audanika',
            model: 'Test',
          ),
        );
        expect(
          coreMidi.calls,
          equals(['createSource Own 2', 'describe 500 4242 Audanika Test 9']),
        );
        expect(port.id, const MidiPortId('coremidi:4242'));
        expect(port.isOwn, isTrue);
        expect(port.isVirtual, isTrue);
        expect(port.transport, MidiTransport.virtual);
        expect(port.groups.map((g) => g.group), equals([0, 3]));
        expect(
          port.capabilities,
          const MidiPortCapabilities(ump: true, sysEx8: true),
        );
        expect(host.events, equals([MidiPortAdded(port: port)]));
        expect(backend.ports.last, port);
        await backend.remove(port.id);
        expect(coreMidi.calls.last, 'dispose 500');
        expect(host.events.last, MidiPortRemoved(port: port));
      });

      test('create a destination that delivers once open', () async {
        final port = await backend.create(
          MidiVirtualPortSpec(name: 'Own In', direction: MidiDirection.input),
        );
        expect(
          coreMidi.calls,
          equals([
            'createDestination Own In 1 1',
            'describe 500 null null null null',
          ]),
        );
        expect(port.capabilities.timestampsIn, isTrue);
        coreMidi.packets.add(_packet(1, 2000));
        signal(MidiCoreMidi.packetsSignal);
        expect(host.packets, isEmpty);
        await backend.openPort(port.id);
        coreMidi.packets.add(_packet(1, 2000));
        signal(MidiCoreMidi.packetsSignal);
        expect(host.packets.single.port, port.id);
        await backend.closePort(port.id);
        coreMidi.packets.add(_packet(1, 2000));
        signal(MidiCoreMidi.packetsSignal);
        expect(host.packets, hasLength(1));
      });

      test('disposes the endpoint when the description fails', () async {
        coreMidi.failures['MIDIObjectSetIntegerProperty'] = -10843;
        await expectLater(
          backend.create(
            MidiVirtualPortSpec(
              name: 'Own',
              direction: MidiDirection.output,
              uniqueId: 110,
            ),
          ),
          throwsA(isA<MidiNativeError>()),
        );
        expect(coreMidi.calls.last, 'dispose 500');
        expect(host.events, isEmpty);
      });

      test('remove only own ports', () async {
        await expectLater(
          backend.remove(keysInId),
          throwsA(isA<MidiUnsupported>()),
        );
        await expectLater(
          backend.remove(const MidiPortId('coremidi:1')),
          throwsA(isA<MidiPortGone>()),
        );
      });
    });

    group('received packets', () {
      test('arrive with their time on the package clock', () async {
        await backend.openPort(keysInId);
        coreMidi.packets.addAll([_packet(1, 3000000), _packet(99, 0)]);
        coreMidi.dropped = 3;
        signal(MidiCoreMidi.packetsSignal);
        expect(host.packets, hasLength(1));
        final received = host.packets.single;
        expect(received.port, keysInId);
        expect(
          received.packet,
          ump([0x20903c64], const MidiTime(1000000 + 3000)),
        );
        expect(
          host.diagnostics.single,
          MidiDiagnostic(
            kind: MidiDiagnosticKind.queueOverflow,
            count: 3,
            cause: 'The CoreMIDI receive buffer was full',
            time: host.clock.now(),
          ),
        );
      });
    });

    group('notifications', () {
      test('report hotplug as port events', () {
        coreMidi.setup = snapshot(sources: [endpoint(31, name: 'New')]);
        notify(MidiCoreMidi.objectAdded);
        expect(host.events.single, isA<MidiPortAdded>());
        expect(host.events.single.port.name, 'New');
        notify(MidiCoreMidi.propertyChanged);
        expect(host.events, hasLength(1));
      });

      test('report driver errors as diagnostics', () {
        notify(MidiCoreMidi.ioError);
        notify(5);
        expect(host.events, isEmpty);
        expect(host.diagnostics.single.kind, MidiDiagnosticKind.nativeError);
        expect(
          host.diagnostics.single.cause,
          'CoreMIDI I/O error 9 of device 7',
        );
      });
    });

    group('supportsNativeTap, attachNativeTap, detachNativeTap', () {
      const tap = MidiNativeTap(function: 0x10, user: 0x20);

      test('connect the source for the tap alone', () async {
        expect(backend.supportsNativeTap(keysInId), isTrue);
        expect(backend.supportsNativeTap(keysOutId), isFalse);
        expect(
          backend.supportsNativeTap(const MidiPortId('coremidi:1')),
          isFalse,
        );
        await backend.attachNativeTap(keysInId, tap);
        expect(
          coreMidi.calls,
          equals(['connect 11 1 1', 'attachTap 1 11 16 32 false']),
        );
        expect(coreMidi.taps, {1: tap});
        // Packets of a tapped source without a listener stay with the tap.
        coreMidi.packets.add(_packet(1, 2000));
        signal(MidiCoreMidi.packetsSignal);
        expect(host.packets, isEmpty);
        coreMidi.calls.clear();
        await backend.detachNativeTap(keysInId);
        await backend.detachNativeTap(keysInId);
        expect(coreMidi.calls, equals(['detachTap 1', 'disconnect 11 1']));
        expect(coreMidi.taps, isEmpty);
      });

      test('share the source with a listener', () async {
        await backend.openPort(keysInId);
        coreMidi.calls.clear();
        await backend.attachNativeTap(keysInId, tap);
        expect(coreMidi.calls, equals(['attachTap 1 11 16 32 true']));
        coreMidi.calls.clear();
        await backend.closePort(keysInId);
        expect(coreMidi.calls, equals(['setTapRing 1 false']));
        coreMidi.calls.clear();
        await backend.openPort(keysInId);
        expect(coreMidi.calls, equals(['setTapRing 1 true']));
        coreMidi.packets.add(_packet(1, 2000));
        signal(MidiCoreMidi.packetsSignal);
        expect(host.packets.single.port, keysInId);
        coreMidi.calls.clear();
        await backend.detachNativeTap(keysInId);
        expect(coreMidi.calls, equals(['detachTap 1']));
        await backend.closePort(keysInId);
        expect(coreMidi.calls, equals(['detachTap 1', 'disconnect 11 1']));
      });

      test('tap own destinations', () async {
        final port = await backend.create(
          MidiVirtualPortSpec(name: 'Own In', direction: MidiDirection.input),
        );
        final source = await backend.create(
          MidiVirtualPortSpec(name: 'Own Out', direction: MidiDirection.output),
        );
        expect(backend.supportsNativeTap(port.id), isTrue);
        expect(backend.supportsNativeTap(source.id), isFalse);
        coreMidi.calls.clear();
        await backend.attachNativeTap(port.id, tap);
        expect(coreMidi.calls, equals(['attachTap 1 500 16 32 false']));
        await backend.openPort(port.id);
        await backend.closePort(port.id);
        await backend.detachNativeTap(port.id);
        expect(
          coreMidi.calls,
          equals([
            'attachTap 1 500 16 32 false',
            'setTapRing 1 true',
            'setTapRing 1 false',
            'detachTap 1',
          ]),
        );
        await expectLater(
          backend.attachNativeTap(source.id, tap),
          throwsA(isA<ArgumentError>()),
        );
        await backend.detachNativeTap(source.id);
      });

      test('throw for unknown ports, outputs and a second tap', () async {
        const unknown = MidiPortId('coremidi:1');
        await expectLater(
          backend.attachNativeTap(unknown, tap),
          throwsA(isA<MidiPortGone>()),
        );
        await expectLater(
          backend.detachNativeTap(unknown),
          throwsA(isA<MidiPortGone>()),
        );
        await expectLater(
          backend.attachNativeTap(keysOutId, tap),
          throwsA(isA<ArgumentError>()),
        );
        await backend.detachNativeTap(keysOutId);
        await backend.attachNativeTap(keysInId, tap);
        await expectLater(
          backend.attachNativeTap(keysInId, tap),
          throwsA(isA<StateError>()),
        );
      });

      test('disconnect again when the shim refuses the tap', () async {
        coreMidi.failures['aud_midi_apple_tap_attach'] = -2;
        await expectLater(
          backend.attachNativeTap(keysInId, tap),
          throwsA(isA<MidiNativeError>()),
        );
        expect(coreMidi.calls.last, 'disconnect 11 1');
        await backend.openPort(keysInId);
        coreMidi.failures['aud_midi_apple_tap_attach'] = -2;
        coreMidi.calls.clear();
        await expectLater(
          backend.attachNativeTap(keysInId, tap),
          throwsA(isA<MidiNativeError>()),
        );
        // The source was connected again, with the next ref con.
        expect(coreMidi.calls, equals(['attachTap 2 11 16 32 true']));
      });

      test('report a tap that did not return', () async {
        await backend.attachNativeTap(keysInId, tap);
        coreMidi.tapLeaks = true;
        await backend.detachNativeTap(keysInId);
        expect(host.diagnostics.single.port, keysInId);
        expect(host.diagnostics.single.cause, contains('leaks'));
      });

      test('survive the source and follow it to a new endpoint', () async {
        await backend.attachNativeTap(keysInId, tap);
        coreMidi
          ..calls.clear()
          ..setup = (devices: [], sources: [], destinations: []);
        backend.refresh();
        expect(coreMidi.calls, isEmpty);
        expect(backend.supportsNativeTap(keysInId), isFalse);
        const moved = (
          ref: 41,
          uniqueId: 110,
          name: 'Keys In',
          displayName: 'Keys In',
          manufacturer: 'Maker',
          model: 'Model',
          driverOwner: '',
          isOffline: false,
          isPrivate: false,
          protocol: 1,
          groupBitmap: null,
        );
        coreMidi.setup = (devices: [], sources: [moved], destinations: []);
        backend.refresh();
        expect(
          coreMidi.calls,
          equals(['disconnect 11 1', 'connect 41 1 1', 'setTapSource 1 41']),
        );
        coreMidi
          ..calls.clear()
          ..setup = (devices: [], sources: [], destinations: []);
        backend.refresh();
        // The tap of a vanished port can still be detached.
        await backend.detachNativeTap(keysInId);
        expect(coreMidi.calls, equals(['detachTap 1', 'disconnect 41 1']));
      });

      test('leave on stop', () async {
        await backend.attachNativeTap(keysInId, tap);
        coreMidi.calls.clear();
        await backend.stop();
        expect(
          coreMidi.calls,
          equals(['detachTap 1', 'disconnect 11 1', 'close']),
        );
        await expectLater(
          backend.attachNativeTap(keysInId, tap),
          throwsA(isA<StateError>()),
        );
      });
    });

    group('refresh()', () {
      test('reconnects open inputs whose endpoint changed', () async {
        await backend.openPort(keysInId);
        coreMidi.calls.clear();
        const moved = (
          ref: 41,
          uniqueId: 110,
          name: 'Keys In',
          displayName: 'Keys In',
          manufacturer: 'Maker',
          model: 'Model',
          driverOwner: '',
          isOffline: false,
          isPrivate: false,
          protocol: 2,
          groupBitmap: null,
        );
        coreMidi.setup = (devices: [], sources: [moved], destinations: []);
        backend.refresh();
        expect(coreMidi.calls, equals(['disconnect 11 1', 'connect 41 2 1']));
        coreMidi.calls.clear();
        backend.refresh();
        expect(coreMidi.calls, isEmpty);
        coreMidi.setup = (devices: [], sources: [], destinations: []);
        backend.refresh();
        expect(coreMidi.calls, isEmpty);
        coreMidi
          ..setup = snapshot()
          ..failures['MIDIPortDisconnectSource'] = -1
          ..failures['MIDIPortConnectSource'] = -10842;
        backend.refresh();
        expect(host.diagnostics.single.port, keysInId);
        expect(
          host.diagnostics.single.cause,
          'MIDIPortConnectSource failed with -10842',
        );
      });
    });

    group('capabilities', () {
      test('describe CoreMIDI with Bluetooth and the iOS session', () {
        expect(
          backend.capabilities,
          MidiCapabilities(
            virtualPorts: MidiVirtualPortSupport.dynamicPorts,
            bleScan: true,
            network: {MidiNetworkSupport.osSession},
            ump: true,
            scheduling: MidiSchedulingSupport.hardware,
          ),
        );
        central.denied = true;
        expect(
          backend.capabilities.missingPermissions,
          equals({MidiPermission.bluetooth}),
        );
      });

      test('lack Bluetooth and network where unavailable', () async {
        final other = AppleMidiBackend(
          coreMidi: _FakeCoreMidi()..bluetoothDriverAvailable = false,
          networkSession: _FakeSession()..isAvailable = false,
        );
        expect(other.capabilities.bleScan, isFalse);
        expect(other.capabilities.network, isEmpty);
        expect(other.capabilities.missingPermissions, isEmpty);
        expect(other.bluetooth, isNull);
        expect(other.network, isNull);
      });
    });

    group('AppleMidiBackend()', () {
      test('creates the native layers lazily', () {
        final native = AppleMidiBackend();
        expect(native.ports, isEmpty);
        expect(native.clientName, 'aud_midi');
        expect(native.resyncInterval, const Duration(seconds: 10));
      });
    });

    group('virtualPorts, name, clientName', () {
      test('describe the backend', () {
        expect(backend.virtualPorts, same(backend));
        expect(backend.name, 'coremidi');
        expect(backend.clientName, 'test');
        expect(backend.resyncInterval, const Duration(milliseconds: 1));
        expect(backend.bluetoothTimeout, const Duration(milliseconds: 20));
      });
    });

    group('bluetooth', () {
      test('connects a peripheral that CoreMIDI lists at once', () async {
        final bluetoothDevice = device(
          5,
          name: 'Pads',
          driverOwner: bluetooth,
          sources: [endpoint(51, name: 'Pads', driverOwner: bluetooth)],
        );
        coreMidi.onActivate = () {
          coreMidi.setup = snapshot(devices: [bluetoothDevice]);
          notify(MidiCoreMidi.objectAdded);
        };
        central.replyName = 'Pads';
        final ble = backend.bluetooth!;
        expect(backend.bluetooth, same(ble));
        final ports = await ble.connect('p1');
        expect(ports.map((p) => p.name), equals(['Pads']));
        expect(ports.single.transport, MidiTransport.bluetoothLe);
        await ble.disconnect('p1');
        expect(coreMidi.calls, contains('bluetooth disconnect p1'));
      });

      test('waits for the CoreMIDI device', () async {
        central.replyName = '';
        final connecting = backend.bluetooth!.connect(
          'p1',
          timeout: const Duration(seconds: 2),
        );
        await pumpEventQueue();
        coreMidi.setup = snapshot(
          devices: [
            device(
              6,
              name: 'Old',
              driverOwner: bluetooth,
              isOffline: true,
              sources: [endpoint(61, driverOwner: bluetooth, isOffline: true)],
            ),
            device(
              7,
              name: 'Any',
              driverOwner: bluetooth,
              sources: [endpoint(71, name: 'Any', driverOwner: bluetooth)],
            ),
          ],
        );
        notify(MidiCoreMidi.objectAdded);
        expect((await connecting).single.name, 'Any');
      });

      test('gives up when the device does not appear', () async {
        await expectLater(
          backend.bluetooth!.connect(
            'p1',
            timeout: const Duration(milliseconds: 30),
          ),
          throwsA(isA<MidiNativeError>().having((e) => e.code, 'code', -10842)),
        );
      });

      test('fails waiting connections on stop', () async {
        central.replyName = 'Never';
        final connecting = expectLater(
          backend.bluetooth!.connect('p1'),
          throwsA(isA<StateError>()),
        );
        await pumpEventQueue();
        await backend.stop();
        await connecting;
      });
    });

    group('network', () {
      test('reports the ports of the session endpoints', () async {
        final network = backend.network!;
        expect(backend.network, same(network));
        session
          ..source = 11
          ..destination = 12;
        final connection = await network.connect(
          const MidiNetworkHostInfo(name: 'S', address: 'a', port: 5004),
        );
        expect(connection.portIds, equals([keysInId, keysOutId]));
        await backend.stop();
        expect(session.observing, isFalse);
      });
    });
  });
}

// #############################################################################
MidiCoreMidiPacket _packet(int refCon, int timestamp) => (
  refCon: refCon,
  protocol: 1,
  timestamp: timestamp,
  arrival: timestamp,
  words: Uint32List.fromList([0x20903c64]),
);

String _hex(Uint32List words) =>
    words.map((w) => w.toRadixString(16).padLeft(8, '0')).join(' ');

// #############################################################################
final class _Host implements MidiBackendHost {
  @override
  final MidiClock clock = MidiFakeClock(start: const MidiTime(1000000));

  final events = <MidiPortEvent>[];
  final packets = <({MidiPortId port, MidiPacket packet})>[];
  final diagnostics = <MidiDiagnostic>[];

  @override
  void portsChanged(List<MidiPortEvent> events) => this.events.addAll(events);

  @override
  void received(MidiPortId port, MidiPacket packet) =>
      packets.add((port: port, packet: packet));

  @override
  void diagnostic(MidiDiagnostic diagnostic) => diagnostics.add(diagnostic);
}

// #############################################################################
final class _FakeCoreMidi implements MidiCoreMidi {
  MidiCoreMidiSnapshot setup = (devices: [], sources: [], destinations: []);
  void Function(int)? signal;
  String? openedAs;
  final calls = <String>[];
  final packets = <MidiCoreMidiPacket>[];
  final notifications = <MidiCoreMidiNotification>[];
  final failures = <String, int>{};
  final uniqueIds = <int, int>{};
  final taps = <int, MidiNativeTap>{};
  bool tapLeaks = false;
  int dropped = 0;
  int _nextEndpoint = 500;
  void Function()? onActivate;

  @override
  bool bluetoothDriverAvailable = true;

  void _check(String api) {
    final code = failures.remove(api);
    if (code != null) throw MidiNativeError(api: api, code: code);
  }

  @override
  void open({required String name, required void Function(int) onSignal}) {
    _check('open');
    openedAs = name;
    signal = onSignal;
  }

  @override
  void close() => calls.add('close');

  @override
  MidiCoreMidiSnapshot snapshot() => setup;

  @override
  void connectSource(int source, {required int protocol, required int refCon}) {
    _check('MIDIPortConnectSource');
    calls.add('connect $source $protocol $refCon');
  }

  @override
  void disconnectSource(int source, {required int protocol}) {
    _check('MIDIPortDisconnectSource');
    calls.add('disconnect $source $protocol');
  }

  @override
  void send(
    int destination, {
    required int protocol,
    required int timestamp,
    required Uint32List words,
  }) => calls.add('send $destination $protocol $timestamp ${_hex(words)}');

  @override
  int createSource({required String name, required int protocol}) {
    calls.add('createSource $name $protocol');
    return _endpoint();
  }

  @override
  int createDestination({
    required String name,
    required int protocol,
    required int refCon,
  }) {
    calls.add('createDestination $name $protocol $refCon');
    return _endpoint();
  }

  @override
  void describe(
    int endpoint, {
    int? uniqueId,
    String? manufacturer,
    String? model,
    int? groupBitmap,
  }) {
    calls.add('describe $endpoint $uniqueId $manufacturer $model $groupBitmap');
    _check('MIDIObjectSetIntegerProperty');
    if (uniqueId != null) uniqueIds[endpoint] = uniqueId;
  }

  @override
  int uniqueIdOf(int object) => uniqueIds[object]!;

  @override
  void emit(
    int source, {
    required int protocol,
    required int timestamp,
    required Uint32List words,
  }) => calls.add('emit $source $protocol $timestamp ${_hex(words)}');

  @override
  void disposeEndpoint(int endpoint) {
    calls.add('dispose $endpoint');
    _check('MIDIEndpointDispose');
  }

  @override
  void attachTap({
    required int refCon,
    required int source,
    required MidiNativeTap tap,
    required bool ring,
  }) {
    calls.add('attachTap $refCon $source ${tap.function} ${tap.user} $ring');
    _check('aud_midi_apple_tap_attach');
    taps[refCon] = tap;
  }

  @override
  bool detachTap(int refCon) {
    calls.add('detachTap $refCon');
    taps.remove(refCon);
    return !tapLeaks;
  }

  @override
  void setTapRing(int refCon, {required bool ring}) =>
      calls.add('setTapRing $refCon $ring');

  @override
  void setTapSource(int refCon, int source) =>
      calls.add('setTapSource $refCon $source');

  @override
  List<MidiCoreMidiPacket> readPackets() {
    final result = [...packets];
    packets.clear();
    return result;
  }

  @override
  List<MidiCoreMidiNotification> readNotifications() {
    final result = [...notifications];
    notifications.clear();
    return result;
  }

  @override
  int takeDropped() {
    final result = dropped;
    dropped = 0;
    return result;
  }

  @override
  void activateBluetoothConnections() {
    calls.add('activate');
    onActivate?.call();
  }

  @override
  void disconnectBluetooth(String uuid) =>
      calls.add('bluetooth disconnect $uuid');

  @override
  int now() => 0;

  @override
  final MidiMachTimebase timebase = const MidiMachTimebase(numer: 1, denom: 1);

  int _endpoint() {
    final ref = _nextEndpoint++;
    uniqueIds[ref] = ref * 10;
    return ref;
  }
}

// #############################################################################
final class _FakeCentral implements MidiCoreBluetooth {
  bool denied = false;
  String replyName = '';
  void Function(MidiCoreBluetoothEvent event)? _onEvent;

  MidiCoreBluetoothEvent _event(int kind, {int state = 0, String id = ''}) => (
    kind: kind,
    state: state,
    peripheralId: id,
    name: replyName,
    rssi: null,
    isConnectable: true,
    error: '',
  );

  @override
  void open(void Function(MidiCoreBluetoothEvent event) onEvent) {
    _onEvent = onEvent;
    onEvent(
      _event(
        MidiCoreBluetooth.stateChanged,
        state: MidiCoreBluetooth.poweredOn,
      ),
    );
  }

  @override
  void close() {}

  @override
  void scan() {}

  @override
  void stopScan() {}

  @override
  void connect(String peripheralId) =>
      _onEvent!(_event(MidiCoreBluetooth.connected, id: peripheralId));

  @override
  void cancelConnection(String peripheralId) {}

  @override
  bool get isDenied => denied;
}

// #############################################################################
final class _FakeSession implements MidiAppleNetworkSession {
  @override
  bool isAvailable = true;

  int source = 0;
  int destination = 0;
  bool observing = false;

  @override
  void setEnabled(bool enabled) {}

  @override
  void setConnectionPolicy(int policy) {}

  @override
  bool addConnection(MidiAppleNetworkHost host) => true;

  @override
  bool removeConnection(MidiAppleNetworkHost host) => true;

  @override
  void observe(void Function() onChange) => observing = true;

  @override
  void stopObserving() => observing = false;

  @override
  bool get isEnabled => true;

  @override
  String get networkName => 'iPad';

  @override
  String get localName => 'Session 1';

  @override
  int get networkPort => 5004;

  @override
  int get connectionPolicy => MidiAppleNetworkSession.anyone;

  @override
  List<MidiAppleNetworkHost> get contacts => const [];

  @override
  List<MidiAppleNetworkHost> get connections => const [];

  @override
  int get sourceEndpoint => source;

  @override
  int get destinationEndpoint => destination;
}

// #############################################################################
final class _FakeBrowser implements MidiBonjourBrowser {
  @override
  void start(String type, void Function(MidiBonjourEvent event) onEvent) {}

  @override
  void stop() {}
}
