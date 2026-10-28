// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// coverage:ignore-file
// A CBCentralManager aborts every process without the usage description
// NSBluetoothAlwaysUsageDescription in its Info.plist, so `dart test`
// cannot create one, and this machine has no BLE-MIDI peripheral. The glue
// runs in apps only; its logic is tested in midi_apple_bluetooth_backend.

import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:objective_c/objective_c.dart' as objc;

import '../native/aud_midi_apple_objc_bindings.g.dart';
import 'midi_core_bluetooth.dart';

// #############################################################################
/// The CoreBluetooth calls of the Bluetooth LE MIDI support through
/// Objective-C bindings.
///
/// CoreBluetooth is loaded at runtime instead of being linked, so that apps
/// that never use Bluetooth carry no reference to it. The delegate is a
/// listener: CoreBluetooth calls it on a private dispatch queue and the
/// events arrive asynchronously in the isolate that opened the central.
final class MidiCoreBluetoothNative implements MidiCoreBluetooth {
  /// Creates the glue; CoreBluetooth is touched first by [open] or
  /// [isDenied].
  MidiCoreBluetoothNative();

  // ...........................................................................
  @override
  void open(void Function(MidiCoreBluetoothEvent event) onEvent) {
    _loadFramework();
    final delegate = CBCentralManagerDelegate$Builder.implementAsListener(
      centralManagerDidUpdateState_: (central) =>
          onEvent(_event(MidiCoreBluetooth.stateChanged, state: central.state)),
      centralManager_didDiscoverPeripheral_advertisementData_RSSI_: (
        central,
        peripheral,
        advertisement,
        rssi,
      ) => onEvent(_discovered(peripheral, advertisement, rssi)),
      centralManager_didConnectPeripheral_: (central, peripheral) =>
          onEvent(_event(MidiCoreBluetooth.connected, peripheral: peripheral)),
      centralManager_didFailToConnectPeripheral_error_:
          (central, peripheral, error) => onEvent(
            _event(
              MidiCoreBluetooth.failedToConnect,
              peripheral: peripheral,
              error: error,
            ),
          ),
      centralManager_didDisconnectPeripheral_error_:
          (central, peripheral, error) => onEvent(
            _event(
              MidiCoreBluetooth.disconnected,
              peripheral: peripheral,
              error: error,
            ),
          ),
    );
    final label = 'aud_midi_apple.bluetooth'.toNativeUtf8();
    final queue = dispatch_queue_create(label.cast(), null);
    malloc.free(label);
    // The central holds its delegate weakly; the record keeps it alive.
    _session = (
      central: CBCentralManager.alloc().initWithDelegate(
        delegate,
        queue: queue,
      ),
      delegate: delegate,
    );
  }

  @override
  void close() {
    _central?.stopScan();
    _central?.ref.release();
    _session = null;
    _peripherals.clear();
  }

  // ...........................................................................
  @override
  void scan() => _central!.scanForPeripheralsWithServices(
    objc.NSArray.of([CBUUID.UUIDWithString(_serviceUuid.toNSString())]),
  );

  @override
  void stopScan() => _central?.stopScan();

  // ...........................................................................
  @override
  void connect(String peripheralId) {
    final peripheral = _peripheral(peripheralId);
    if (peripheral == null) {
      throw ArgumentError.value(peripheralId, 'peripheralId', 'Unknown');
    }
    _central!.connectPeripheral(peripheral);
  }

  @override
  void cancelConnection(String peripheralId) {
    final peripheral = _peripheral(peripheralId);
    if (peripheral != null) _central?.cancelPeripheralConnection(peripheral);
  }

  // ...........................................................................
  @override
  bool get isDenied {
    _loadFramework();
    final authorization = CBCentralManager.getAuthorization$1();
    return authorization ==
            CBManagerAuthorization.CBManagerAuthorizationDenied ||
        authorization ==
            CBManagerAuthorization.CBManagerAuthorizationRestricted;
  }

  // ...........................................................................
  static const String _serviceUuid = '03B80E5A-EDE8-4B33-A751-6CE34EC4C700';
  static const String _frameworkPath =
      '/System/Library/Frameworks/CoreBluetooth.framework/CoreBluetooth';
  static bool _loaded = false;

  ({CBCentralManager central, CBCentralManagerDelegate delegate})? _session;
  final _peripherals = <String, CBPeripheral>{};

  CBCentralManager? get _central => _session?.central;

  static void _loadFramework() {
    if (_loaded) return;
    DynamicLibrary.open(_frameworkPath);
    _loaded = true;
  }

  CBPeripheral? _peripheral(String id) {
    final known = _peripherals[id];
    if (known != null) return known;
    final uuid = NSUUID.alloc().initWithUUIDString(id.toNSString());
    if (uuid == null || _central == null) return null;
    final found = _central!.retrievePeripheralsWithIdentifiers(
      objc.NSArray.of([uuid]),
    );
    if (found.count == 0) return null;
    return _peripherals[id] = CBPeripheral.as(found.objectAtIndex(0));
  }

  MidiCoreBluetoothEvent _discovered(
    CBPeripheral peripheral,
    objc.NSDictionary advertisement,
    objc.NSNumber rssi,
  ) {
    final id = peripheral.identifier.UUIDString.toDartString();
    _peripherals[id] = peripheral;
    final localName = advertisement.objectForKey(
      'kCBAdvDataLocalName'.toNSString(),
    );
    final connectable = advertisement.objectForKey(
      'kCBAdvDataIsConnectable'.toNSString(),
    );
    return (
      kind: MidiCoreBluetooth.discovered,
      state: 0,
      peripheralId: id,
      name:
          peripheral.name?.toDartString() ??
          (objc.NSString.isA(localName)
              ? objc.NSString.as(localName!).toDartString()
              : ''),
      // CoreBluetooth reports 127 when the strength is not available.
      rssi: rssi.intValue == 127 ? null : rssi.intValue,
      isConnectable:
          !objc.NSNumber.isA(connectable) ||
          objc.NSNumber.as(connectable!).boolValue,
      error: '',
    );
  }

  static MidiCoreBluetoothEvent _event(
    int kind, {
    CBManagerState? state,
    CBPeripheral? peripheral,
    objc.NSError? error,
  }) => (
    kind: kind,
    state: state?.value ?? 0,
    peripheralId: peripheral?.identifier.UUIDString.toDartString() ?? '',
    name: peripheral?.name?.toDartString() ?? '',
    rssi: null,
    isConnectable: true,
    error: error?.localizedDescription.toDartString() ?? '',
  );
}
