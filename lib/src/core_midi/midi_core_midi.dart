// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:typed_data';

import 'package:aud_midi_core/aud_midi_core.dart';

import 'midi_mach_timebase.dart';

// #############################################################################
/// A CoreMIDI endpoint with its properties as read from the system.
///
/// - `ref` the `MIDIEndpointRef`, valid while the endpoint exists.
/// - `protocol` the `MIDIProtocolID`, 1 for MIDI 1.0 and 2 for MIDI 2.0.
/// - `groupBitmap` the active UMP groups (bit 0 = group 1), or null when
///   the endpoint does not declare them.
typedef MidiCoreMidiEndpoint = ({
  int ref,
  int uniqueId,
  String name,
  String displayName,
  String manufacturer,
  String model,
  String driverOwner,
  bool isOffline,
  bool isPrivate,
  int protocol,
  int? groupBitmap,
});

/// A CoreMIDI entity: a group of endpoints of a device.
typedef MidiCoreMidiEntity = ({
  String name,
  List<MidiCoreMidiEndpoint> sources,
  List<MidiCoreMidiEndpoint> destinations,
});

/// A CoreMIDI device with its entities.
typedef MidiCoreMidiDevice = ({
  int ref,
  int uniqueId,
  String name,
  String manufacturer,
  String model,
  String driverOwner,
  bool isOffline,
  List<MidiCoreMidiEntity> entities,
});

/// Everything CoreMIDI lists: the devices and all sources and destinations,
/// including the virtual endpoints of applications.
typedef MidiCoreMidiSnapshot = ({
  List<MidiCoreMidiDevice> devices,
  List<MidiCoreMidiEndpoint> sources,
  List<MidiCoreMidiEndpoint> destinations,
});

/// A received `MIDIEventPacket`.
///
/// - `refCon` identifies the source, see [MidiCoreMidi.connectSource].
/// - `timestamp` the packet's time in mach ticks; the shim replaces 0 by
///   the arrival time.
/// - `arrival` the mach ticks when the packet reached the shim.
/// - `words` complete UMPs.
typedef MidiCoreMidiPacket = ({
  int refCon,
  int protocol,
  int timestamp,
  int arrival,
  Uint32List words,
});

/// A CoreMIDI notification; the meaning of `values` depends on
/// `messageId`, see [MidiCoreMidi.objectAdded] and the others.
typedef MidiCoreMidiNotification = ({int messageId, List<int> values});

// #############################################################################
/// The CoreMIDI calls of the backend: the boundary between the Dart logic
/// and the native layer.
///
/// `MidiCoreMidiNative` implements it with FFI; tests implement it in Dart.
/// All methods throw `MidiNativeError` when CoreMIDI reports an error.
abstract interface class MidiCoreMidi {
  // ...........................................................................
  /// Creates the MIDI client [name]; [onSignal] runs in the calling
  /// isolate with the signal bits ([packetsSignal], [notificationsSignal])
  /// whenever data waits.
  void open({required String name, required void Function(int) onSignal});

  /// Stops every callback, waits until none is in flight and disposes the
  /// client with its ports and endpoints.
  void close();

  // ...........................................................................
  /// Reads all devices, sources and destinations.
  MidiCoreMidiSnapshot snapshot();

  // ...........................................................................
  /// Connects [source] to the input port of [protocol]; its packets carry
  /// [refCon].
  void connectSource(int source, {required int protocol, required int refCon});

  /// Disconnects [source] from the input port of [protocol].
  void disconnectSource(int source, {required int protocol});

  // ...........................................................................
  /// Sends [words] to [destination] in event lists of [protocol] at
  /// [timestamp] (mach ticks, 0 = now).
  void send(
    int destination, {
    required int protocol,
    required int timestamp,
    required Uint32List words,
  });

  // ...........................................................................
  /// Creates a virtual source named [name] and returns it.
  int createSource({required String name, required int protocol});

  /// Creates a virtual destination named [name] whose packets carry
  /// [refCon] and returns it.
  int createDestination({
    required String name,
    required int protocol,
    required int refCon,
  });

  /// Sets the properties of the own [endpoint] that are not null.
  void describe(
    int endpoint, {
    int? uniqueId,
    String? manufacturer,
    String? model,
    int? groupBitmap,
  });

  /// Returns the unique id of [object].
  int uniqueIdOf(int object);

  /// Distributes [words] from the own virtual [source] to the clients
  /// connected to it, stamped with [timestamp] (mach ticks, 0 = now).
  void emit(
    int source, {
    required int protocol,
    required int timestamp,
    required Uint32List words,
  });

  /// Disposes the own virtual [endpoint].
  void disposeEndpoint(int endpoint);

  // ...........................................................................
  /// Attaches the native [tap] to the packets that arrive with [refCon]
  /// from the endpoint [source]: the shim calls it on CoreMIDI's receive
  /// thread once per packet with the UMP words and the timestamp in
  /// nanoseconds, and reports `gone` when the source is removed or goes
  /// offline. With [ring] the packets reach [readPackets] as well.
  ///
  /// Throws a `MidiNativeError` when [refCon] has a tap already or no slot
  /// is free.
  void attachTap({
    required int refCon,
    required int source,
    required MidiNativeTap tap,
    required bool ring,
  });

  /// Detaches the tap of [refCon]: no call starts afterwards, and the
  /// method returns after the calls in flight returned. Returns false when
  /// a call did not return in time; the shim then leaks the slot and logs.
  bool detachTap(int refCon);

  /// Sets whether the packets of the tapped [refCon] reach [readPackets]
  /// as well.
  void setTapRing(int refCon, {required bool ring});

  /// Tells the tap of [refCon] the new endpoint [source] of its source
  /// after it came back.
  void setTapSource(int refCon, int source);

  // ...........................................................................
  /// Returns and removes the received packets.
  List<MidiCoreMidiPacket> readPackets();

  /// Returns and removes the received notifications.
  List<MidiCoreMidiNotification> readNotifications();

  /// Returns the number of packets dropped since the last call because the
  /// ring buffer was full.
  int takeDropped();

  // ...........................................................................
  /// Promotes the Bluetooth LE MIDI peripherals connected through
  /// CoreBluetooth to CoreMIDI devices
  /// (`MIDIBluetoothDriverActivateAllConnections`).
  void activateBluetoothConnections();

  /// Disconnects CoreMIDI from the Bluetooth LE MIDI peripheral with the
  /// CoreBluetooth identifier [uuid] (`MIDIBluetoothDriverDisconnect`).
  void disconnectBluetooth(String uuid);

  /// Whether the Bluetooth MIDI driver can be driven programmatically
  /// (macOS 13, iOS 16).
  bool get bluetoothDriverAvailable;

  // ...........................................................................
  /// Returns the current host time in mach ticks.
  int now();

  /// The duration of a mach tick.
  MidiMachTimebase get timebase;

  // ...........................................................................
  /// The signal bit for waiting packets.
  static const int packetsSignal = 1;

  /// The signal bit for waiting notifications.
  static const int notificationsSignal = 2;

  /// The notification that reports lost notifications.
  static const int notificationsLost = 0;

  /// `kMIDIMsgSetupChanged`: something changed; no values.
  static const int setupChanged = 1;

  /// `kMIDIMsgObjectAdded`: values are parent, parent type, child and child
  /// type.
  static const int objectAdded = 2;

  /// `kMIDIMsgObjectRemoved`: values are parent, parent type, child and
  /// child type.
  static const int objectRemoved = 3;

  /// `kMIDIMsgPropertyChanged`: values are object and object type.
  static const int propertyChanged = 4;

  /// `kMIDIMsgIOError`: values are the driver device and the error code.
  static const int ioError = 7;
}
