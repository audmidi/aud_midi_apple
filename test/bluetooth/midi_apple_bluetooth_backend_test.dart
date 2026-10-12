// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:async';

import 'package:aud_midi_apple/aud_midi_apple.dart';
import 'package:aud_midi_core/aud_midi_core.dart';
import 'package:aud_midi_standard/aud_midi_standard.dart';
import 'package:test/test.dart';

void main() {
  late _FakeCentral central;
  late List<String> calls;
  late List<({String name, Duration timeout})> waits;
  late Future<List<MidiPortInfo>> Function({
    required String name,
    required Duration timeout,
  })
  waitForPorts;
  late MidiAppleBluetoothBackend backend;

  final port = MidiPortInfo(
    id: const MidiPortId('coremidi:1'),
    name: 'Keys',
    direction: MidiDirection.input,
  );

  MidiCoreBluetoothEvent event(
    int kind, {
    int state = 0,
    String id = 'p1',
    String name = '',
    int? rssi,
    bool isConnectable = true,
  }) => (
    kind: kind,
    state: state,
    peripheralId: id,
    name: name,
    rssi: rssi,
    isConnectable: isConnectable,
    error: '',
  );

  setUp(() {
    central = _FakeCentral();
    calls = central.calls;
    waits = [];
    waitForPorts = ({required name, required timeout}) async {
      waits.add((name: name, timeout: timeout));
      return [port];
    };
    backend = MidiAppleBluetoothBackend(
      central: central,
      activate: () => calls.add('activate'),
      disconnectDriver: (id) => calls.add('driver disconnect $id'),
      waitForPorts: ({required name, required timeout}) =>
          waitForPorts(name: name, timeout: timeout),
      readyTimeout: const Duration(milliseconds: 50),
    );
  });

  tearDown(() => backend.close());

  group('MidiAppleBluetoothBackend', () {
    group('scan(timeout)', () {
      test('reports discovered peripherals until stopScan', () async {
        final found = <MidiBlePeripheralInfo>[];
        final done = backend.scan().listen(found.add).asFuture<void>();
        await pumpEventQueue();
        expect(calls, equals(['open', 'scan']));
        central.emit(
          event(
            MidiCoreBluetooth.discovered,
            name: 'Keys',
            rssi: -40,
            isConnectable: false,
          ),
        );
        await backend.stopScan();
        await done;
        expect(found, [
          MidiBlePeripheralInfo(
            id: 'p1',
            name: 'Keys',
            rssi: -40,
            isConnectable: false,
          ),
        ]);
        expect(calls.last, 'stopScan');
      });

      test('ends after the timeout', () async {
        final stream = backend.scan(timeout: const Duration(milliseconds: 10));
        expect(await stream.toList(), isEmpty);
        expect(calls, equals(['open', 'scan', 'stopScan']));
      });

      test('waits for a state that arrives later', () async {
        central.openState = null;
        final done = backend.scan().toList();
        await pumpEventQueue();
        central
          ..emit(event(MidiCoreBluetooth.stateChanged, state: 1))
          ..emit(
            event(
              MidiCoreBluetooth.stateChanged,
              state: MidiCoreBluetooth.poweredOn,
            ),
          );
        await pumpEventQueue();
        expect(calls, equals(['open', 'scan']));
        central.emit(
          event(
            MidiCoreBluetooth.stateChanged,
            state: MidiCoreBluetooth.poweredOff,
          ),
        );
        expect(await done, isEmpty);
      });

      test('ends at once when Bluetooth is off', () async {
        central.openState = MidiCoreBluetooth.poweredOff;
        expect(await backend.scan().toList(), isEmpty);
        expect(calls, equals(['open']));
      });

      test('ends when the state stays unknown', () async {
        central.openState = null;
        expect(await backend.scan().toList(), isEmpty);
        expect(calls, equals(['open']));
      });

      test('replaces a running scan', () async {
        central.openState = null;
        final first = backend.scan().toList();
        final second = backend.scan().toList();
        expect(await first, isEmpty);
        central.emit(
          event(
            MidiCoreBluetooth.stateChanged,
            state: MidiCoreBluetooth.poweredOn,
          ),
        );
        await pumpEventQueue();
        await backend.stopScan();
        expect(await second, isEmpty);
        expect(calls, equals(['open', 'scan', 'stopScan']));
      });

      test('stops when the listener cancels', () async {
        final subscription = backend.scan().listen((_) {});
        await pumpEventQueue();
        await subscription.cancel();
        expect(calls, equals(['open', 'scan', 'stopScan']));
      });

      test('throws when Bluetooth is denied', () {
        central.denied = true;
        expect(
          backend.scan,
          throwsA(
            isA<MidiPermissionDenied>().having(
              (e) => e.permission,
              'permission',
              MidiPermission.bluetooth,
            ),
          ),
        );
      });
    });

    group('connect(peripheralId, timeout)', () {
      test('hands the peripheral to CoreMIDI and returns its ports', () async {
        central.connectReply = MidiCoreBluetooth.connected;
        central.replyName = 'Keys';
        expect(await backend.connect('p1'), equals([port]));
        expect(calls, equals(['open', 'connect p1', 'activate', 'cancel p1']));
        expect(waits.single.name, 'Keys');
        expect(
          waits.single.timeout,
          lessThanOrEqualTo(const Duration(seconds: 10)),
        );
      });

      test('uses the name of the discovery', () async {
        final scan = backend.scan().toList();
        await pumpEventQueue();
        central.emit(event(MidiCoreBluetooth.discovered, name: 'Pads'));
        await backend.stopScan();
        await scan;
        central.connectReply = MidiCoreBluetooth.connected;
        await backend.connect('p1');
        await backend.connect('p2');
        expect(waits.map((w) => w.name), equals(['Pads', '']));
      });

      test('throws when CoreBluetooth fails', () async {
        for (final reply in [
          MidiCoreBluetooth.failedToConnect,
          MidiCoreBluetooth.disconnected,
        ]) {
          central.connectReply = reply;
          await expectLater(
            backend.connect('p1'),
            throwsA(
              isA<MidiNativeError>()
                  .having((e) => e.code, 'code', -2)
                  .having(
                    (e) => e.api,
                    'api',
                    'CBCentralManager.connectPeripheral',
                  ),
            ),
          );
        }
        expect(calls, isNot(contains('activate')));
      });

      test('throws after the timeout', () async {
        await expectLater(
          backend.connect('p1', timeout: const Duration(milliseconds: 10)),
          throwsA(isA<MidiNativeError>().having((e) => e.code, 'code', -1)),
        );
        expect(calls, equals(['open', 'connect p1', 'cancel p1']));
      });

      test('ends the connection when CoreMIDI does not take it', () async {
        central.connectReply = MidiCoreBluetooth.connected;
        waitForPorts = ({required name, required timeout}) async =>
            throw const MidiNativeError(api: 'x', code: 1);
        await expectLater(
          backend.connect('p1'),
          throwsA(isA<MidiNativeError>()),
        );
        expect(calls.last, 'cancel p1');
      });

      test('throws when Bluetooth is off or denied', () async {
        central.openState = MidiCoreBluetooth.unauthorized;
        await expectLater(
          backend.connect('p1'),
          throwsA(isA<MidiUnsupported>()),
        );
        central.denied = true;
        await expectLater(
          backend.connect('p1'),
          throwsA(isA<MidiPermissionDenied>()),
        );
      });

      test('ignores replies for other peripherals', () async {
        final connecting = backend.connect(
          'p1',
          timeout: const Duration(milliseconds: 20),
        );
        await pumpEventQueue();
        central.emit(event(MidiCoreBluetooth.connected, id: 'p9'));
        await expectLater(connecting, throwsA(isA<MidiNativeError>()));
      });
    });

    group('disconnect(peripheralId)', () {
      test('disconnects CoreMIDI and CoreBluetooth', () async {
        await backend.disconnect('p1');
        expect(calls, equals(['driver disconnect p1']));
        central.connectReply = MidiCoreBluetooth.connected;
        await backend.connect('p1');
        calls.clear();
        await backend.disconnect('p1');
        expect(calls, equals(['driver disconnect p1', 'cancel p1']));
      });
    });

    group('close()', () {
      test('fails pending connections and closes the central', () async {
        final connecting = backend.connect('p1');
        await pumpEventQueue();
        backend.close();
        await expectLater(connecting, throwsA(isA<StateError>()));
        expect(calls.last, 'close');
        backend.close();
        expect(calls.where((c) => c == 'close'), hasLength(1));
      });
    });

    group('central, readyTimeout, activateInterval', () {
      test('keep the dependencies', () {
        expect(backend.central, same(central));
        expect(backend.readyTimeout, const Duration(milliseconds: 50));
        expect(backend.activateInterval, const Duration(seconds: 1));
      });
    });

    group('connect() while the user pairs', () {
      test('repeats the activation until the ports appear', () async {
        var activations = 0;
        final pairing = MidiAppleBluetoothBackend(
          central: central,
          activate: () {
            activations++;
            if (activations == 2) {
              throw const MidiNativeError(api: 'x', code: 1);
            }
          },
          disconnectDriver: (_) {},
          waitForPorts: ({required name, required timeout}) async {
            await Future<void>.delayed(const Duration(milliseconds: 40));
            return [port];
          },
          readyTimeout: const Duration(milliseconds: 50),
          activateInterval: const Duration(milliseconds: 5),
        );
        central.connectReply = MidiCoreBluetooth.connected;
        expect(await pairing.connect('p1'), equals([port]));
        expect(activations, greaterThan(2));
        final after = activations;
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(activations, after);
        pairing.close();
      });
    });

    group('showSystemDevicePicker()', () {
      test('shows the picker of the operating system', () async {
        var shown = 0;
        final picking = MidiAppleBluetoothBackend(
          central: central,
          activate: () {},
          disconnectDriver: (_) {},
          waitForPorts: waitForPorts,
          showPicker: () async => shown++,
        );
        await picking.showSystemDevicePicker();
        expect(shown, 1);
        central.denied = true;
        await expectLater(
          picking.showSystemDevicePicker(),
          throwsA(isA<MidiPermissionDenied>()),
        );
      });

      test('throws without a picker', () async {
        await expectLater(
          backend.showSystemDevicePicker(),
          throwsA(isA<MidiUnsupported>()),
        );
      });
    });
  });
}

// #############################################################################
final class _FakeCentral implements MidiCoreBluetooth {
  final calls = <String>[];
  void Function(MidiCoreBluetoothEvent event)? _onEvent;

  /// The state reported when the central opens; null reports none.
  int? openState = MidiCoreBluetooth.poweredOn;

  /// The reply to connect; null replies nothing.
  int? connectReply;

  /// The name of the peripheral in the connect reply.
  String replyName = '';

  bool denied = false;

  void emit(MidiCoreBluetoothEvent event) => _onEvent!(event);

  @override
  void open(void Function(MidiCoreBluetoothEvent event) onEvent) {
    calls.add('open');
    _onEvent = onEvent;
    final state = openState;
    if (state != null) {
      emit(_event(MidiCoreBluetooth.stateChanged, state: state));
    }
  }

  @override
  void close() => calls.add('close');

  @override
  void scan() => calls.add('scan');

  @override
  void stopScan() => calls.add('stopScan');

  @override
  void connect(String peripheralId) {
    calls.add('connect $peripheralId');
    final reply = connectReply;
    if (reply != null) {
      emit(_event(reply, id: peripheralId, name: replyName));
    }
  }

  @override
  void cancelConnection(String peripheralId) =>
      calls.add('cancel $peripheralId');

  @override
  bool get isDenied => denied;

  static MidiCoreBluetoothEvent _event(
    int kind, {
    int state = 0,
    String id = '',
    String name = '',
  }) => (
    kind: kind,
    state: state,
    peripheralId: id,
    name: name,
    rssi: null,
    isConnectable: true,
    error: '',
  );
}
