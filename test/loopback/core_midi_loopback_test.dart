// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

@TestOn('mac-os')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';

import 'package:aud_midi_apple/aud_midi_apple.dart';
import 'package:aud_midi_apple/src/native/aud_midi_apple_bindings.g.dart'
    as native
    show
        AUD_MIDI_APPLE_PROBE_VALUES,
        AudMidiAppleProbe,
        MIDIFlushOutput,
        aud_midi_apple_probe_create,
        aud_midi_apple_probe_free,
        aud_midi_apple_probe_function,
        aud_midi_apple_probe_read,
        aud_midi_apple_ticks_to_ns;
import 'package:aud_midi_core/aud_midi_core.dart';
import 'package:aud_midi_standard/aud_midi_standard.dart';
import 'package:ffi/ffi.dart';
import 'package:test/test.dart';

// Real CoreMIDI loopback between two backends of this process, the way two
// apps see each other: one creates virtual endpoints, the other one finds
// them through hotplug and uses them like any other port.
//
// Set AUD_MIDI_REPORT to a file path to write the measured timing numbers
// as JSON.
void main() {
  late _Host hostA;
  late _Host hostB;
  late AppleMidiBackend a;
  late AppleMidiBackend b;
  final report = <String, Object?>{};
  final suffix = Random().nextInt(1 << 30);

  // Waits until [backend] lists a port named [name] in [direction].
  Future<MidiPortInfo> portNamed(
    _Host host,
    AppleMidiBackend backend,
    String name,
    MidiDirection direction,
  ) async {
    bool matches(MidiPortInfo port) =>
        port.name == name && port.direction == direction;
    await host.until(() => backend.ports.any(matches));
    return backend.ports.singleWhere(matches);
  }

  MidiUmpPacket packet(List<int> words, MidiTime time) =>
      MidiUmpPacket(words: words, time: time);

  List<int> wordsOf(Iterable<_Received> received) => [
    for (final entry in received) ...(entry.packet as MidiUmpPacket).words,
  ];

  setUp(() async {
    hostA = _Host();
    hostB = _Host();
    a = AppleMidiBackend(clientName: 'aud loop a');
    b = AppleMidiBackend(clientName: 'aud loop b');
    await a.start(hostA);
    await b.start(hostB);
  });

  tearDown(() async {
    await a.stop();
    await b.stop();
  });

  tearDownAll(() {
    final path = Platform.environment['AUD_MIDI_REPORT'];
    if (path == null || report.isEmpty) return;
    File(path)
        .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(report));
  });

  group('virtual source → input port', () {
    for (final protocol in MidiProtocol.values) {
      test(
        'delivers ${protocol.name} UMPs in order with their times',
        () async {
          final name = 'aud loop src ${protocol.name} $suffix';
          final source = await a.create(
            MidiVirtualPortSpec(
              name: name,
              direction: MidiDirection.output,
              protocol: protocol,
            ),
          );
          final input = await portNamed(hostB, b, name, MidiDirection.input);
          expect(input.protocol, protocol);
          expect(input.transport, MidiTransport.virtual);
          expect(input.isVirtual, isTrue);
          expect(input.isOwn, isFalse);
          expect(input.capabilities.ump, isTrue);
          expect(input.capabilities.timestampsIn, isTrue);
          await b.openPort(input.id);

          final messages = protocol == MidiProtocol.midi1
              ? [
                  [0x20903c64],
                  [0x20b00740],
                  [0x30160001, 0x02030405],
                  [0x30260607, 0x08090a0b],
                  [0x30320c0d, 0x00000000],
                  [0x20803c00],
                ]
              : [
                  [0x40903c00, 0xc8000000],
                  [0x40b00700, 0x80000000],
                  [0x50160001, 0x02030405, 0x06070809, 0x0a0b0c0d],
                  [0x50360001, 0x0e0f1011, 0x12131415, 0x16171819],
                  [0x40803c00, 0x00000000],
                ];
          // A future timestamp travels unchanged from a virtual source.
          final base = hostA.clock.now() + const Duration(milliseconds: 50);
          for (var i = 0; i < messages.length; i++) {
            await a.send(
              source.id,
              packet(messages[i], base + Duration(milliseconds: i)),
            );
          }
          final sent = [for (final message in messages) ...message];
          await hostB.until(() => wordsOf(hostB.packets).length >= sent.length);
          expect(wordsOf(hostB.packets), equals(sent));
          expect(hostB.packets.map((e) => e.port).toSet(), equals({input.id}));

          final deviations = [
            for (final entry in hostB.packets)
              entry.packet.time.microseconds - base.microseconds,
          ];
          for (final deviation in deviations) {
            expect(deviation, inInclusiveRange(-2, messages.length * 1000 + 2));
          }
          report['timestamps_${protocol.name}_us'] = deviations;
        },
      );
    }

    test('stops delivering after closePort', () async {
      final name = 'aud loop close $suffix';
      final source = await a.create(
        MidiVirtualPortSpec(name: name, direction: MidiDirection.output),
      );
      final input = await portNamed(hostB, b, name, MidiDirection.input);
      await b.openPort(input.id);
      await b.closePort(input.id);
      await a.send(source.id, packet([0x20903c64], hostA.clock.now()));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(hostB.packets, isEmpty);
    });
  });

  group('output port → virtual destination', () {
    test('delivers MIDI 2.0 UMPs to the own destination', () async {
      final name = 'aud loop dst $suffix';
      final destination = await a.create(
        MidiVirtualPortSpec(
          name: name,
          direction: MidiDirection.input,
          protocol: MidiProtocol.midi2,
          groups: const [0, 1],
        ),
      );
      expect(destination.capabilities.timestampsIn, isTrue);
      await a.openPort(destination.id);
      final output = await portNamed(hostB, b, name, MidiDirection.output);
      expect(output.capabilities.scheduledSend, isTrue);
      expect(output.capabilities.cancelPending, isFalse);
      expect(output.groups.map((g) => g.group), equals([0, 1]));
      final words = [0x40903c00, 0xc8000000, 0xd0100000, 0x00000078, 0, 0];
      await b.send(output.id, packet(words, hostB.clock.now()));
      await hostA.until(() => hostA.packets.isNotEmpty);
      expect(wordsOf(hostA.packets), equals(words));
      expect(hostA.packets.single.port, destination.id);
    });

    test('schedules future packets in CoreMIDI', () async {
      // The receiving side is a plain native client, whose packets carry
      // the arrival time of the CoreMIDI callback next to the timestamp.
      final receiver = MidiCoreMidiNative()
        ..open(name: 'aud loop timing', onSignal: (_) {});
      addTearDown(receiver.close);
      final name = 'aud loop timing $suffix';
      receiver.createDestination(name: name, protocol: 1, refCon: 1);
      final output = await portNamed(hostB, b, name, MidiDirection.output);
      const count = 50;
      const lead = Duration(milliseconds: 100);
      final start = hostB.clock.now() + lead;
      for (var i = 0; i < count; i++) {
        await b.send(
          output.id,
          packet([0x20903c00 | i], start + Duration(milliseconds: 10 * i)),
        );
      }
      final packets = <MidiCoreMidiPacket>[];
      final deadline = DateTime.now().add(const Duration(seconds: 3));
      while (packets.length < count && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        packets.addAll(receiver.readPackets());
      }
      expect(packets, hasLength(count));
      final timebase = receiver.timebase;
      final lateness = [
        for (final p in packets)
          timebase.toMicros(p.arrival) - timebase.toMicros(p.timestamp),
      ]..sort();
      final requested = [
        for (final p in packets)
          timebase.toMicros(p.timestamp) -
              timebase.toMicros(packets[0].timestamp),
      ];
      expect(requested.last, closeTo(10000 * (count - 1), 50));
      expect(lateness.first, greaterThanOrEqualTo(0));
      expect(lateness.last, lessThan(5000));
      report['scheduled_send_lateness_us'] = {
        'count': count,
        'min': lateness.first,
        'median': lateness[count ~/ 2],
        'p95': lateness[(count * 95) ~/ 100],
        'max': lateness.last,
      };
    });

    test('cancelPending leaves the destination alone', () async {
      final name = 'aud loop cancel $suffix';
      final destination = await a.create(
        MidiVirtualPortSpec(name: name, direction: MidiDirection.input),
      );
      await a.openPort(destination.id);
      final output = await portNamed(hostB, b, name, MidiDirection.output);
      await b.send(
        output.id,
        packet([
          0x20903c64,
        ], hostB.clock.now() + const Duration(milliseconds: 300)),
      );
      await b.cancelPending(output.id);
      await hostA.until(() => hostA.packets.isNotEmpty);
      // The scheduled note arrives, and no System Reset came before it.
      expect(wordsOf(hostA.packets), equals([0x20903c64]));
    });

    test('MIDIFlushOutput would reset a virtual destination', () async {
      // The reason why no port supports cancelPending: flushing a virtual
      // destination that never received anything delivers a System Reset.
      final receiver = MidiCoreMidiNative()
        ..open(name: 'aud loop flush', onSignal: (_) {});
      addTearDown(receiver.close);
      final destination = receiver.createDestination(
        name: 'aud loop flush $suffix',
        protocol: 1,
        refCon: 1,
      );
      expect(native.MIDIFlushOutput(destination), 0);
      final words = <int>[];
      final deadline = DateTime.now().add(const Duration(seconds: 2));
      while (words.isEmpty && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        for (final p in receiver.readPackets()) {
          words.addAll(p.words);
        }
      }
      expect(words, equals([0x10ff0000]));
      report['flush_delivers'] = [
        for (final word in words) word.toRadixString(16),
      ];
    });
  });

  group('hotplug', () {
    test('reports virtual endpoints appearing and disappearing', () async {
      final name = 'aud loop hotplug $suffix';
      final stopwatch = Stopwatch()..start();
      final source = await a.create(
        MidiVirtualPortSpec(name: name, direction: MidiDirection.output),
      );
      await hostB.until(
        () =>
            hostB.events.any((e) => e is MidiPortAdded && e.port.name == name),
      );
      final added = stopwatch.elapsedMilliseconds;
      // Other test files create endpoints at the same time.
      expect(
        hostA.events.where((e) => e.port.name == name),
        equals([MidiPortAdded(port: source)]),
      );
      stopwatch.reset();
      await a.remove(source.id);
      await hostB.until(
        () => hostB.events.any(
          (e) => e is MidiPortRemoved && e.port.name == name,
        ),
      );
      report['hotplug_latency_ms'] = {
        'added': added,
        'removed': stopwatch.elapsedMilliseconds,
      };
      expect(b.ports.where((p) => p.name == name), isEmpty);
    });

    test('reconnects an open input when its source comes back', () async {
      final name = 'aud loop replug $suffix';
      final uniqueId = 0x6a000000 + suffix % 0xffff;
      final spec = MidiVirtualPortSpec(
        name: name,
        direction: MidiDirection.output,
        uniqueId: uniqueId,
      );
      var source = await a.create(spec);
      expect(
        source.id,
        MidiPortId.of(backend: 'coremidi', nativeId: '$uniqueId'),
      );
      final input = await portNamed(hostB, b, name, MidiDirection.input);
      expect(input.id.nativeId, '$uniqueId');
      await b.openPort(input.id);
      await a.remove(source.id);
      await hostB.until(() => b.ports.every((p) => p.id != input.id));
      source = await a.create(spec);
      await portNamed(hostB, b, name, MidiDirection.input);
      await a.send(source.id, packet([0x20903c64], hostA.clock.now()));
      await hostB.until(() => hostB.packets.isNotEmpty);
      expect(hostB.packets.single.port, input.id);
    });
  });

  group('stop()', () {
    test('stops cleanly while packets are in flight', () async {
      final name = 'aud loop stop $suffix';
      final source = await a.create(
        MidiVirtualPortSpec(name: name, direction: MidiDirection.output),
      );
      final input = await portNamed(hostB, b, name, MidiDirection.input);
      await b.openPort(input.id);
      final burst = [for (var i = 0; i < 64; i++) 0x20903c00 | i];
      var sending = true;
      final sender = () async {
        while (sending) {
          await a.send(source.id, packet(burst, hostA.clock.now()));
          await Future<void>.delayed(Duration.zero);
        }
      }();
      await hostB.until(() => hostB.packets.isNotEmpty);
      await b.stop();
      final received = hostB.packets.length;
      await Future<void>.delayed(const Duration(milliseconds: 100));
      sending = false;
      await sender;
      expect(hostB.packets.length, received);
      expect(b.ports, isEmpty);
    });
  });

  group('native taps', () {
    late _Probe probe;

    setUp(() => probe = _Probe());

    tearDown(() => probe.free());

    test('receive every packet with host times, without a listener', () async {
      final name = 'aud loop tap $suffix';
      final source = await a.create(
        MidiVirtualPortSpec(
          name: name,
          direction: MidiDirection.output,
          protocol: MidiProtocol.midi2,
        ),
      );
      final input = await portNamed(hostB, b, name, MidiDirection.input);
      expect(b.supportsNativeTap(input.id), isTrue);
      await b.attachNativeTap(input.id, probe.tap);
      final messages = [
        [0x40903c00, 0xc8000000],
        [0x40b00700, 0x80000000],
        [0x40803c00, 0x00000000],
      ];
      final base = hostA.clock.now() + const Duration(milliseconds: 20);
      for (var i = 0; i < messages.length; i++) {
        await a.send(
          source.id,
          packet(messages[i], base + Duration(milliseconds: i)),
        );
      }
      await probe.until(() => probe.words >= 6);
      expect(probe.umpCalls, 3);
      expect(probe.words, 6);
      expect(
        probe.sum,
        [for (final m in messages) ...m].fold<int>(0, (a, b) => a + b),
      );
      expect(probe.first, 0x40803c00);
      expect(probe.minDelayNs, greaterThanOrEqualTo(-1000));
      // The timestamps are the sent times, on the host clock in ns.
      final nowNs = native.aud_midi_apple_ticks_to_ns(
        MidiCoreMidiNative().now(),
      );
      expect((nowNs - probe.lastTimeNs).abs(), lessThan(1000000000));
      // No listener: nothing reached Dart.
      expect(hostB.packets, isEmpty);
      report['tap_delivery_delay_ns'] = probe.minDelayNs;
      // With a listener both get the packets; the tap stays after close.
      await b.openPort(input.id);
      await a.send(source.id, packet(messages[0], hostA.clock.now()));
      await hostB.until(() => hostB.packets.isNotEmpty);
      await probe.until(() => probe.words >= 8);
      expect(probe.words, 8);
      await b.closePort(input.id);
      await a.send(source.id, packet(messages[0], hostA.clock.now()));
      await probe.until(() => probe.words >= 10);
      expect(probe.words, 10);
      expect(hostB.packets, hasLength(1));
      await b.detachNativeTap(input.id);
    });

    test('detach under traffic lets no call through afterwards', () async {
      final name = 'aud loop tap detach $suffix';
      final source = await a.create(
        MidiVirtualPortSpec(name: name, direction: MidiDirection.output),
      );
      final input = await portNamed(hostB, b, name, MidiDirection.input);
      await b.attachNativeTap(input.id, probe.tap);
      final burst = [for (var i = 0; i < 16; i++) 0x20903c00 | i];
      var sending = true;
      final sender = () async {
        while (sending) {
          await a.send(source.id, packet(burst, hostA.clock.now()));
          await Future<void>.delayed(Duration.zero);
        }
      }();
      await probe.until(() => probe.umpCalls >= 50);
      await b.detachNativeTap(input.id);
      final calls = probe.umpCalls;
      await Future<void>.delayed(const Duration(milliseconds: 100));
      sending = false;
      await sender;
      expect(probe.umpCalls, calls);
      expect(probe.overlaps, 0);
      // The slot is free again: a second tap attaches.
      await b.attachNativeTap(input.id, probe.tap);
      await b.detachNativeTap(input.id);
      report['tap_calls_before_detach'] = calls;
    });

    test('report gone when the source goes and survive its return', () async {
      final name = 'aud loop tap gone $suffix';
      final uniqueId = 0x6b000000 + suffix % 0xffff;
      final spec = MidiVirtualPortSpec(
        name: name,
        direction: MidiDirection.output,
        uniqueId: uniqueId,
      );
      var source = await a.create(spec);
      final input = await portNamed(hostB, b, name, MidiDirection.input);
      await b.attachNativeTap(input.id, probe.tap);
      final stopwatch = Stopwatch()..start();
      await a.remove(source.id);
      await probe.until(() => probe.goneCalls >= 1);
      report['tap_gone_latency_ms'] = stopwatch.elapsedMilliseconds;
      expect(probe.goneCalls, 1);
      // Dart learns the removal later, the tap stays attached meanwhile.
      await hostB.until(() => b.ports.every((p) => p.id != input.id));
      expect(b.supportsNativeTap(input.id), isFalse);
      // The source comes back under its unique id: the tap gets its data.
      source = await a.create(spec);
      await portNamed(hostB, b, name, MidiDirection.input);
      await a.send(source.id, packet([0x20903c64], hostA.clock.now()));
      await probe.until(() => probe.words >= 1);
      expect(probe.words, 1);
      expect(probe.goneCalls, 1);
      await a.remove(source.id);
      await probe.until(() => probe.goneCalls >= 2);
      expect(probe.goneCalls, 2);
      await b.detachNativeTap(input.id);
    });
  });

  group('network session', () {
    test(
      'follows MIDINetworkSession when AUD_MIDI_TEST_NETWORK=1',
      () async {
        final session = MidiAppleNetworkSessionNative();
        final observation = <String, Object?>{'available': session.isAvailable};
        report['network_session'] = observation;
        if (!session.isAvailable) {
          // macOS: the SDK declares MIDINetworkSession non-functional and
          // defaultSession is nil.
          expect(b.network, isNull);
          expect(b.capabilities.network, isEmpty);
          return;
        }
        final network = b.network!;
        final previous = network.session;
        observation['before'] = previous.toJson();
        addTearDown(() async {
          if (!previous.enabled) await network.disable();
        });
        final enabled = await network.enable(name: 'aud');
        observation['after'] = enabled.toJson();
        expect(enabled.enabled, isTrue);
      },
      skip: Platform.environment['AUD_MIDI_TEST_NETWORK'] == '1'
          ? false
          : 'changes a global setting; set AUD_MIDI_TEST_NETWORK=1',
    );
  });
}

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
  int get overlaps => read()[8];
  int get minDelayNs => read()[9];

  /// Waits up to five seconds until [done] holds.
  Future<void> until(bool Function() done) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!done() && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  void free() {
    native.aud_midi_apple_probe_free(pointer);
    calloc.free(_values);
  }
}

// #############################################################################
typedef _Received = ({MidiPortId port, MidiPacket packet, MidiTime arrival});

final class _Host implements MidiBackendHost {
  @override
  final MidiClock clock = const MidiSystemClock();

  final events = <MidiPortEvent>[];
  final packets = <_Received>[];
  final diagnostics = <MidiDiagnostic>[];

  @override
  void portsChanged(List<MidiPortEvent> events) => this.events.addAll(events);

  @override
  void received(MidiPortId port, MidiPacket packet) =>
      packets.add((port: port, packet: packet, arrival: clock.now()));

  @override
  void diagnostic(MidiDiagnostic diagnostic) => diagnostics.add(diagnostic);

  /// Waits up to five seconds until [condition] holds.
  Future<void> until(bool Function() condition) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) {
        throw TimeoutException('Condition not met');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }
}
