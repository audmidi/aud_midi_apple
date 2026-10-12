// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

@TestOn('mac-os')
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:aud_midi_apple/aud_midi_apple.dart';
import 'package:aud_midi_apple/src/native/aud_midi_apple_bindings.g.dart'
    as native;
import 'package:aud_midi_core/aud_midi_core.dart';
import 'package:ffi/ffi.dart';
import 'package:test/test.dart';

// #############################################################################
/// The probe tap of the shim, read from Dart: UMP calls, byte calls, gone
/// calls, words, bytes, the last time, the sum, the first word, overlaps
/// and the smallest delay.
final class _Probe {
  _Probe()
    : pointer = native.aud_midi_apple_probe_create(),
      _values = calloc<Int64>(native.AUD_MIDI_APPLE_PROBE_VALUES);

  final Pointer<native.AudMidiAppleProbe> pointer;
  final Pointer<Int64> _values;

  MidiNativeTap get tap => MidiNativeTap(
    function: native.aud_midi_apple_probe_function().address,
    user: pointer.address,
  );

  List<int> read() {
    native.aud_midi_apple_probe_read(
      pointer,
      _values,
      native.AUD_MIDI_APPLE_PROBE_VALUES,
    );
    return _values.asTypedList(native.AUD_MIDI_APPLE_PROBE_VALUES).toList();
  }

  int get umpCalls => read()[0];
  int get goneCalls => read()[2];
  int get words => read()[3];
  int get lastTimeNs => read()[5];
  int get sum => read()[6];
  int get first => read()[7];
  int get minDelayNs => read()[9];

  /// Waits up to two seconds until [done] holds.
  Future<void> until(bool Function() done) async {
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (!done() && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  void free() {
    native.aud_midi_apple_probe_free(pointer);
    calloc.free(_values);
  }
}

void main() {
  late MidiCoreMidiNative a;
  late MidiCoreMidiNative b;
  late List<int> signalsOfB;

  // Polls [native] until [count] packets arrived or two seconds passed.
  Future<List<MidiCoreMidiPacket>> packetsOf(
    MidiCoreMidi native, {
    int count = 1,
  }) async {
    final packets = <MidiCoreMidiPacket>[];
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (packets.length < count && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      packets.addAll(native.readPackets());
    }
    return packets;
  }

  // Polls [native] until a notification arrives or five seconds passed.
  Future<List<MidiCoreMidiNotification>> notificationsOf(
    MidiCoreMidi native,
  ) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final notifications = native.readNotifications();
      if (notifications.isNotEmpty) return notifications;
    }
    return const [];
  }

  Uint32List words(List<int> values) => Uint32List.fromList(values);

  Matcher nativeError(String api) => isA<MidiNativeError>()
      .having((e) => e.api, 'api', api)
      .having((e) => e.code, 'code', isNot(0));

  setUp(() {
    signalsOfB = [];
    a = MidiCoreMidiNative()..open(name: 'aud test a', onSignal: (_) {});
    b = MidiCoreMidiNative()
      ..open(name: 'aud test b', onSignal: signalsOfB.add);
  });

  tearDown(() {
    a.close();
    b.close();
  });

  group('MidiCoreMidiNative', () {
    group('open(name, onSignal)', () {
      test('opens a client once', () {
        expect(a.isOpen, isTrue);
        expect(
          () => a.open(name: 'again', onSignal: (_) {}),
          throwsA(isA<StateError>()),
        );
      });

      test('opens again after close', () {
        final native = MidiCoreMidiNative(capacityWords: 1024)
          ..open(name: 'aud test c', onSignal: (_) {})
          ..close();
        expect(native.isOpen, isFalse);
        native
          ..open(name: 'aud test c', onSignal: (_) {})
          ..close();
      });
    });

    group('close()', () {
      test('does nothing when the client is not open', () {
        final native = MidiCoreMidiNative()..close();
        expect(native.isOpen, isFalse);
      });

      test('lets every call that needs the client throw', () {
        final native = MidiCoreMidiNative();
        for (final call in <void Function()>[
          native.readPackets,
          native.readNotifications,
          native.takeDropped,
          () => native.send(1, protocol: 1, timestamp: 0, words: words([])),
          () => native.emit(1, protocol: 1, timestamp: 0, words: words([])),
          () => native.connectSource(1, protocol: 1, refCon: 1),
        ]) {
          expect(call, throwsA(isA<StateError>()));
        }
      });
    });

    group('snapshot()', () {
      test('lists devices with entities and the virtual endpoints', () {
        final source = a.createSource(name: 'aud snap src', protocol: 2);
        final destination = a.createDestination(
          name: 'aud snap dst',
          protocol: 1,
          refCon: 9,
        );
        a.describe(source, manufacturer: 'Audanika', model: 'Test');
        final snapshot = b.snapshot();
        expect(snapshot.devices, isNotEmpty);
        expect(
          snapshot.devices.any((device) => device.entities.isNotEmpty),
          isTrue,
        );
        final src = snapshot.sources.singleWhere((e) => e.ref == source);
        expect([
          src.name,
          src.displayName,
          src.manufacturer,
          src.model,
        ], equals(['aud snap src', 'aud snap src', 'Audanika', 'Test']));
        expect(src.protocol, 2);
        expect(src.uniqueId, a.uniqueIdOf(source));
        expect(src.isOffline, isFalse);
        expect(src.isPrivate, isFalse);
        expect(src.driverOwner, isEmpty);
        final dst = snapshot.destinations.singleWhere(
          (e) => e.ref == destination,
        );
        expect(dst.protocol, 1);
      });
    });

    group('connectSource(source, protocol, refCon)', () {
      test('delivers the packets of the source with the ref con', () async {
        final source = a.createSource(name: 'aud conn src', protocol: 2);
        b.connectSource(source, protocol: 2, refCon: 42);
        final sent = words([0x40903c00, 0xc8000000]);
        final before = b.now();
        a.emit(source, protocol: 2, timestamp: 0, words: sent);
        final packets = await packetsOf(b);
        expect(packets, hasLength(1));
        final packet = packets.single;
        expect(packet.refCon, 42);
        expect(packet.protocol, 2);
        expect(packet.words, equals(sent));
        expect(packet.timestamp, greaterThanOrEqualTo(before));
        expect(packet.arrival, greaterThanOrEqualTo(packet.timestamp));
        expect(signalsOfB, contains(MidiCoreMidi.packetsSignal));
      });

      test('throws for an unknown source', () {
        expect(
          () => b.connectSource(1, protocol: 1, refCon: 1),
          throwsA(nativeError('MIDIPortConnectSource')),
        );
      });
    });

    group('disconnectSource(source, protocol)', () {
      test('stops the packets of the source', () async {
        final source = a.createSource(name: 'aud disc src', protocol: 1);
        b
          ..connectSource(source, protocol: 1, refCon: 1)
          ..disconnectSource(source, protocol: 1);
        a.emit(source, protocol: 1, timestamp: 0, words: words([0x20903c64]));
        expect(await packetsOf(b), isEmpty);
      });

      test('throws for a source that is not connected', () {
        expect(
          () => b.disconnectSource(1, protocol: 1),
          throwsA(nativeError('MIDIPortDisconnectSource')),
        );
      });
    });

    group('send(destination, protocol, timestamp, words)', () {
      test('reaches a virtual destination, also with many words', () async {
        final destination = a.createDestination(
          name: 'aud send dst',
          protocol: 1,
          refCon: 7,
        );
        final sysEx = [
          for (var i = 0; i < 300; i++) ...[
            i == 0 ? 0x30160000 : (i == 299 ? 0x30360000 : 0x30260000),
            0x01020304,
          ],
        ];
        b
          ..send(
            destination,
            protocol: 1,
            timestamp: 0,
            words: words([0x20903c64]),
          )
          ..send(destination, protocol: 1, timestamp: 0, words: words(sysEx));
        final packets = await packetsOf(a, count: 2);
        expect(packets.first.refCon, 7);
        expect(packets.first.words, equals([0x20903c64]));
        expect([
          for (final packet in packets.skip(1)) ...packet.words,
        ], equals(sysEx));
      });

      test('throws when the words end inside a UMP', () {
        expect(
          () =>
              b.send(1, protocol: 2, timestamp: 0, words: words([0x40903c00])),
          throwsA(nativeError('MIDISendEventList')),
        );
      });
    });

    group('protocol arguments', () {
      test('accept only 1 and 2', () {
        final source = a.createSource(name: 'aud proto', protocol: 1);
        for (final call in <void Function()>[
          () => a.createSource(name: 'aud bad', protocol: 7),
          () => a.createDestination(name: 'aud bad', protocol: 0, refCon: 1),
          () => b.connectSource(source, protocol: 3, refCon: 1),
          () => b.disconnectSource(source, protocol: 3),
          () => b.send(1, protocol: 4, timestamp: 0, words: words([0])),
          () => a.emit(source, protocol: 5, timestamp: 0, words: words([0])),
        ]) {
          expect(
            call,
            throwsA(
              isA<ArgumentError>().having((e) => e.name, 'name', 'protocol'),
            ),
          );
        }
      });
    });

    group('createSource(name, protocol)', () {
      test('throws once the client is disposed', () {
        final native = MidiCoreMidiNative()
          ..open(name: 'aud gone', onSignal: (_) {})
          ..close();
        expect(
          () => native.createSource(name: 'aud bad', protocol: 1),
          throwsA(isA<StateError>()),
        );
      });
    });

    group('describe(endpoint, ...)', () {
      test('sets unique id, manufacturer, model and groups', () {
        final source = a.createSource(name: 'aud desc src', protocol: 2);
        final uniqueId = 0x7a00000 + DateTime.now().microsecond;
        a.describe(
          source,
          uniqueId: uniqueId,
          manufacturer: 'Audanika',
          model: 'Model',
          groupBitmap: 0x3,
        );
        final endpoint = b.snapshot().sources.singleWhere(
          (e) => e.ref == source,
        );
        expect(endpoint.uniqueId, uniqueId);
        expect(endpoint.manufacturer, 'Audanika');
        expect(endpoint.model, 'Model');
        expect(endpoint.groupBitmap, 0x3);
        a.describe(source);
      });

      test('throws when the unique id is taken', () {
        final first = a.createSource(name: 'aud uid 1', protocol: 1);
        final second = a.createSource(name: 'aud uid 2', protocol: 1);
        expect(
          () => a.describe(second, uniqueId: a.uniqueIdOf(first)),
          throwsA(nativeError('MIDIObjectSetIntegerProperty')),
        );
      });

      test('throws for an unknown endpoint', () {
        expect(
          () => a.describe(1, manufacturer: 'x'),
          throwsA(nativeError('MIDIObjectSetStringProperty')),
        );
      });
    });

    group('uniqueIdOf(object)', () {
      test('throws for an unknown object', () {
        expect(
          () => a.uniqueIdOf(1),
          throwsA(nativeError('MIDIObjectGetIntegerProperty')),
        );
      });
    });

    group('emit(source, protocol, timestamp, words)', () {
      test('throws when the words end inside a UMP', () {
        final source = a.createSource(name: 'aud emit', protocol: 2);
        expect(
          () => a.emit(
            source,
            protocol: 2,
            timestamp: 1,
            words: words([0x40903c00]),
          ),
          throwsA(nativeError('MIDIReceivedEventList')),
        );
      });
    });

    group('disposeEndpoint(endpoint)', () {
      test('disposes an endpoint once', () {
        final source = a.createSource(name: 'aud dispose', protocol: 1);
        a.disposeEndpoint(source);
        expect(
          () => a.disposeEndpoint(source),
          throwsA(nativeError('MIDIEndpointDispose')),
        );
      });
    });

    group('readNotifications()', () {
      test('reports added endpoints', () async {
        a.createSource(name: 'aud notify', protocol: 1);
        final notifications = await notificationsOf(b);
        expect(
          notifications.map((n) => n.messageId),
          contains(MidiCoreMidi.objectAdded),
        );
        expect(notifications.first.values, hasLength(5));
        expect(signalsOfB, contains(MidiCoreMidi.notificationsSignal));
      });
    });

    group('takeDropped()', () {
      test('counts the packets that did not fit', () async {
        final small = MidiCoreMidiNative(capacityWords: 1024)
          ..open(name: 'aud small', onSignal: (_) {});
        addTearDown(small.close);
        final source = a.createSource(name: 'aud flood', protocol: 1);
        small.connectSource(source, protocol: 1, refCon: 1);
        for (var i = 0; i < 400; i++) {
          a.emit(
            source,
            protocol: 1,
            timestamp: 0,
            words: words([0x20903c64, 0x20803c00]),
          );
        }
        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(small.takeDropped(), greaterThan(0));
        expect(small.takeDropped(), 0);
        expect(small.readPackets(), isNotEmpty);
      });
    });

    group('activateBluetoothConnections()', () {
      test('succeeds without connected peripherals', () {
        expect(a.bluetoothDriverAvailable, isTrue);
        a.activateBluetoothConnections();
      });
    });

    group('disconnectBluetooth(uuid)', () {
      test('succeeds for a peripheral that is not connected', () {
        a.disconnectBluetooth('00000000-0000-0000-0000-000000000000');
      });
    });

    group('now(), timebase', () {
      test('read the host clock', () {
        final first = a.now();
        expect(a.now(), greaterThanOrEqualTo(first));
        expect(a.timebase.numer, greaterThan(0));
        expect(a.timebase.denom, greaterThan(0));
      });
    });

    group('attachTap, detachTap, setTapRing, setTapSource', () {
      late _Probe probe;

      setUp(() => probe = _Probe());

      tearDown(() => probe.free());

      test('call the tap per packet with nanosecond timestamps', () async {
        final source = a.createSource(name: 'aud tap src', protocol: 2);
        b
          ..connectSource(source, protocol: 2, refCon: 7)
          ..attachTap(refCon: 7, source: source, tap: probe.tap, ring: false);
        final sent = words([0x40903c00, 0xc8000000, 0x40803c00, 0x00000000]);
        final stamp = b.now();
        // CoreMIDI merges UMPs with one timestamp into one MIDIEventPacket.
        a.emit(source, protocol: 2, timestamp: stamp, words: sent);
        await probe.until(() => probe.words >= 4);
        expect(probe.umpCalls, inInclusiveRange(1, 2));
        expect(probe.words, 4);
        expect(probe.sum, sent.fold<int>(0, (a, b) => a + b));
        expect(probe.first, anyOf(0x40903c00, 0x40803c00));
        expect(probe.lastTimeNs, native.aud_midi_apple_ticks_to_ns(stamp));
        expect(probe.minDelayNs, greaterThanOrEqualTo(0));
        // Without the ring, Dart gets nothing; with it, both get the data.
        expect(await packetsOf(b), isEmpty);
        b.setTapRing(7, ring: true);
        a.emit(source, protocol: 2, timestamp: 0, words: sent);
        expect(await packetsOf(b), isNotEmpty);
        await probe.until(() => probe.words >= 8);
        expect(probe.words, 8);
        expect(
          probe.lastTimeNs,
          greaterThan(native.aud_midi_apple_ticks_to_ns(stamp)),
        );
        final calls = probe.umpCalls;
        expect(b.detachTap(7), isTrue);
        a.emit(source, protocol: 2, timestamp: 0, words: sent);
        expect(await packetsOf(b), isNotEmpty);
        expect(probe.umpCalls, calls);
      });

      test('report gone when the source is disposed', () async {
        final source = a.createSource(name: 'aud tap gone', protocol: 1);
        b
          ..connectSource(source, protocol: 1, refCon: 8)
          ..attachTap(refCon: 8, source: source, tap: probe.tap, ring: false);
        final before = native.aud_midi_apple_ticks_to_ns(b.now());
        a.disposeEndpoint(source);
        await probe.until(() => probe.goneCalls >= 1);
        expect(probe.goneCalls, 1);
        expect(probe.lastTimeNs, greaterThanOrEqualTo(before));
        // The tap survives; a new source under the ref con reports again.
        final again = a.createSource(name: 'aud tap gone', protocol: 1);
        b
          ..connectSource(again, protocol: 1, refCon: 8)
          ..setTapSource(8, again);
        a.disposeEndpoint(again);
        await probe.until(() => probe.goneCalls >= 2);
        expect(probe.goneCalls, 2);
        expect(b.detachTap(8), isTrue);
      });

      test('refuse a second tap and a stale detach', () {
        final source = a.createSource(name: 'aud tap twice', protocol: 1);
        b
          ..connectSource(source, protocol: 1, refCon: 9)
          ..attachTap(refCon: 9, source: source, tap: probe.tap, ring: true);
        expect(
          () => b.attachTap(
            refCon: 9,
            source: source,
            tap: probe.tap,
            ring: true,
          ),
          throwsA(nativeError('aud_midi_apple_tap_attach')),
        );
        expect(b.detachTap(9), isTrue);
        expect(b.detachTap(9), isFalse);
        b.setTapRing(9, ring: false);
        b.setTapSource(9, source);
      });
    });

    group('aud_midi_apple_ticks_to_ns', () {
      test('converts with the timebase of the process', () {
        final timebase = a.timebase;
        expect(native.aud_midi_apple_ticks_to_ns(0), 0);
        expect(
          native.aud_midi_apple_ticks_to_ns(timebase.denom * 1000),
          timebase.numer * 1000,
        );
        final now = a.now();
        expect(
          native.aud_midi_apple_ticks_to_ns(now) ~/ 1000,
          closeTo(timebase.toMicros(now), 1),
        );
      });
    });
  });
}
