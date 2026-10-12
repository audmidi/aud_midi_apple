// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:async';

import 'package:aud_midi_core/aud_midi_core.dart';
import 'package:aud_midi_standard/aud_midi_standard.dart';

import 'midi_core_bluetooth.dart';

// #############################################################################
/// Waits until CoreMIDI lists the Bluetooth device [name] (any Bluetooth
/// device for an empty name) online and returns its ports; throws a
/// `MidiException` after [timeout].
typedef MidiBluetoothPortsWaiter =
    Future<List<MidiPortInfo>> Function({
      required String name,
      required Duration timeout,
    });

// #############################################################################
/// Connects Bluetooth LE MIDI peripherals to CoreMIDI (macOS 13, iOS 16).
///
/// It follows the steps of `MIDIBluetoothConnection.h`: scan with
/// CoreBluetooth for the BLE-MIDI service, connect the peripheral, promote
/// the connection with `MIDIBluetoothDriverActivateAllConnections`, wait for
/// the CoreMIDI device and its ports, then end the CoreBluetooth connection,
/// because CoreMIDI owns one of its own from then on.
///
/// With a picker, [showSystemDevicePicker] also offers the device
/// picker of iOS, which pairs and connects without these steps.
final class MidiAppleBluetoothBackend
    implements MidiBluetoothBackend, MidiBluetoothSystemPicker {
  /// Creates the support on top of the CoreBluetooth [central].
  ///
  /// - [activate] promotes connected peripherals to CoreMIDI devices.
  /// - [disconnectDriver] disconnects CoreMIDI from a peripheral.
  /// - [waitForPorts] waits for the CoreMIDI device of a peripheral.
  /// - [readyTimeout] how long to wait for the power state of Bluetooth.
  /// - [showPicker] shows the device picker of the operating system.
  /// - [activateInterval] how often the activation repeats while waiting
  ///   for the CoreMIDI device, e.g. until the user accepted the pairing.
  MidiAppleBluetoothBackend({
    required this.central,
    required this._activate,
    required this._disconnectDriver,
    required this._waitForPorts,
    this.readyTimeout = const Duration(seconds: 5),
    this._showPicker,
    this.activateInterval = const Duration(seconds: 1),
  });

  // ...........................................................................
  /// Scans for BLE-MIDI peripherals and reports each finding.
  ///
  /// The stream ends after [timeout], on [stopScan], on a new scan or when
  /// Bluetooth is not powered on. Throws a `MidiPermissionDenied` at once
  /// when the app may not use Bluetooth.
  @override
  Stream<MidiBlePeripheralInfo> scan({Duration? timeout}) {
    _checkPermission();
    _finishScan();
    late final StreamController<MidiBlePeripheralInfo> controller;
    controller = StreamController(
      onCancel: () {
        // A replaced scan must not end the scan that replaced it.
        if (identical(_scan, controller)) _finishScan();
      },
    );
    _scan = controller;
    unawaited(_startScan(controller, timeout));
    return controller.stream;
  }

  @override
  Future<void> stopScan() async => _finishScan();

  // ...........................................................................
  /// Connects [peripheralId] and returns the ports CoreMIDI creates for it.
  ///
  /// Throws a `MidiPermissionDenied` when the app may not use Bluetooth, a
  /// `MidiUnsupported` when Bluetooth is not powered on and a
  /// `MidiNativeError` when CoreBluetooth cannot connect and a
  /// `MidiException` when the CoreMIDI device does not appear within
  /// [timeout].
  @override
  Future<List<MidiPortInfo>> connect(
    String peripheralId, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    _checkPermission();
    final elapsed = Stopwatch()..start();
    if (!await _ready()) throw const MidiUnsupported('Bluetooth (powered off)');
    final event = await _connectCentral(peripheralId, timeout);
    // A peripheral that asks for pairing becomes a CoreMIDI device only when
    // activated after the user accepted, so the activation repeats.
    final reactivate = Timer.periodic(activateInterval, (_) => _tryActivate());
    try {
      _activate();
      return await _waitForPorts(
        name: event.name.isNotEmpty ? event.name : _names[peripheralId] ?? '',
        timeout: timeout - elapsed.elapsed,
      );
    } finally {
      reactivate.cancel();
      central.cancelConnection(peripheralId);
    }
  }

  // ...........................................................................
  /// Shows the Bluetooth MIDI device picker of iOS and completes once the
  /// user dismissed it; throws [pickerUnsupported] where there is none.
  @override
  Future<void> showSystemDevicePicker() async {
    _checkPermission();
    final show = _showPicker ?? (throw pickerUnsupported);
    await show();
  }

  @override
  Future<void> disconnect(String peripheralId) async {
    _disconnectDriver(peripheralId);
    if (_isOpen) central.cancelConnection(peripheralId);
  }

  // ...........................................................................
  /// Ends a running scan, fails pending connections and releases the
  /// central.
  void close() {
    _finishScan();
    for (final pending in _connecting.values) {
      pending.completeError(StateError('Bluetooth was closed'));
    }
    _connecting.clear();
    if (_isOpen) central.close();
    _isOpen = false;
    _state = 0;
    _stateKnown = null;
  }

  // ...........................................................................
  /// The CoreBluetooth central.
  final MidiCoreBluetooth central;

  /// How long to wait for the power state of Bluetooth.
  final Duration readyTimeout;

  /// How often the activation repeats while waiting for the CoreMIDI device.
  final Duration activateInterval;

  // ...........................................................................
  /// The error of [showSystemDevicePicker] where the operating system has
  /// no Bluetooth MIDI device picker, e.g. on macOS.
  static const MidiUnsupported pickerUnsupported = MidiUnsupported(
    'Bluetooth MIDI device picker',
  );

  // ...........................................................................
  final void Function() _activate;
  final void Function(String peripheralId) _disconnectDriver;
  final MidiBluetoothPortsWaiter _waitForPorts;
  final Future<void> Function()? _showPicker;

  bool _isOpen = false;
  int _state = 0;
  Completer<void>? _stateKnown;
  StreamController<MidiBlePeripheralInfo>? _scan;
  Timer? _scanTimer;
  final _names = <String, String>{};
  final _connecting = <String, Completer<MidiCoreBluetoothEvent>>{};

  void _tryActivate() {
    try {
      _activate();
    } on MidiException {
      // The next round or the timeout reports the failure.
    }
  }

  void _checkPermission() {
    if (central.isDenied) {
      throw const MidiPermissionDenied(MidiPermission.bluetooth);
    }
  }

  /// Opens the central once and returns whether Bluetooth is powered on.
  Future<bool> _ready() async {
    if (!_isOpen) {
      _isOpen = true;
      central.open(_onEvent);
    }
    final known = _stateKnown ??= Completer<void>();
    if (!known.isCompleted) {
      await known.future.timeout(readyTimeout, onTimeout: () {});
    }
    return _state == MidiCoreBluetooth.poweredOn;
  }

  Future<void> _startScan(
    StreamController<MidiBlePeripheralInfo> controller,
    Duration? timeout,
  ) async {
    final ready = await _ready();
    if (!identical(_scan, controller)) return;
    if (!ready) return _finishScan();
    central.scan();
    if (timeout != null) _scanTimer = Timer(timeout, _finishScan);
  }

  void _finishScan() {
    _scanTimer?.cancel();
    _scanTimer = null;
    final controller = _scan;
    if (controller == null) return;
    _scan = null;
    if (_state == MidiCoreBluetooth.poweredOn) central.stopScan();
    unawaited(controller.close());
  }

  Future<MidiCoreBluetoothEvent> _connectCentral(
    String peripheralId,
    Duration timeout,
  ) async {
    final completer = _connecting[peripheralId] = Completer();
    central.connect(peripheralId);
    final MidiCoreBluetoothEvent event;
    try {
      event = await completer.future.timeout(timeout);
    } on TimeoutException {
      central.cancelConnection(peripheralId);
      throw const MidiNativeError(api: _connectApi, code: _timeoutCode);
    } finally {
      _connecting.remove(peripheralId);
    }
    if (event.kind == MidiCoreBluetooth.connected) return event;
    throw const MidiNativeError(api: _connectApi, code: _failedCode);
  }

  void _onEvent(MidiCoreBluetoothEvent event) {
    switch (event.kind) {
      case MidiCoreBluetooth.stateChanged:
        _onState(event.state);
      case MidiCoreBluetooth.discovered:
        _names[event.peripheralId] = event.name;
        _scan?.add(
          MidiBlePeripheralInfo(
            id: event.peripheralId,
            name: event.name,
            rssi: event.rssi,
            isConnectable: event.isConnectable,
          ),
        );
      default:
        _connecting[event.peripheralId]?.complete(event);
    }
  }

  void _onState(int state) {
    _state = state;
    // Unknown (0) and resetting (1) are transient states.
    if (state <= 1) return;
    final known = _stateKnown ??= Completer<void>();
    if (!known.isCompleted) known.complete();
    if (state != MidiCoreBluetooth.poweredOn) _finishScan();
  }

  static const String _connectApi = 'CBCentralManager.connectPeripheral';

  /// The code of a connection that timed out.
  static const int _timeoutCode = -1;

  /// The code of a connection that CoreBluetooth refused or lost.
  static const int _failedCode = -2;
}
