// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:ffi';
import 'dart:typed_data';

import 'package:aud_midi_core/aud_midi_core.dart';
import 'package:ffi/ffi.dart';
import 'package:objective_c/objective_c.dart' show CFString;

import '../native/aud_midi_apple_bindings.g.dart' as native;
import 'midi_core_midi.dart';
import 'midi_mach_timebase.dart';

// #############################################################################
/// The CoreMIDI calls of the backend through FFI: the CoreMIDI C API via
/// ffigen bindings and the C shim `src/aud_midi_apple.c`, which owns the
/// client, its input ports and the ring buffer of received packets.
final class MidiCoreMidiNative implements MidiCoreMidi {
  /// Creates the native layer with a ring buffer of [capacityWords] 32-bit
  /// words; nothing native happens before [open].
  MidiCoreMidiNative({this.capacityWords = 1 << 18})
    : assert(capacityWords >= 1024);

  // ...........................................................................
  @override
  void open({required String name, required void Function(int) onSignal}) {
    if (_client != nullptr) throw StateError('The client is open already');
    final callable = NativeCallable<Void Function(Int32)>.listener(onSignal);
    final status = using((arena) {
      final out = arena<Pointer<native.AudMidiAppleClient>>();
      final result = native.aud_midi_apple_client_create(
        name.toNativeUtf8(allocator: arena).cast(),
        callable.nativeFunction,
        capacityWords,
        out,
      );
      _client = out.value;
      return result;
    });
    if (status != 0) callable.close();
    _check('MIDIClientCreateWithBlock', status);
    _callable = callable;
    _readBuffer = malloc<Uint32>(capacityWords);
    _notificationBuffer = malloc<Uint32>(_notificationCapacity * _noteWords);
  }

  @override
  void close() {
    final client = _client;
    if (client == nullptr) return;
    final drained = native.aud_midi_apple_client_close(client, 1000) == 0;
    final callable = _callable!..keepIsolateAlive = false;
    // A callback that never returned could still call the signal; then the
    // callable must stay alive, which leaks it.
    if (drained) callable.close();
    native.aud_midi_apple_client_dispose(client);
    malloc
      ..free(_readBuffer)
      ..free(_notificationBuffer)
      ..free(_sendBuffer);
    _client = nullptr;
    _callable = null;
    _sendBuffer = nullptr;
    _sendCapacity = 0;
  }

  // ...........................................................................
  @override
  MidiCoreMidiSnapshot snapshot() => using(
    (arena) => (
      devices: [
        for (var i = 0; i < native.MIDIGetNumberOfDevices(); i++)
          _device(native.MIDIGetDevice(i), arena),
      ],
      sources: [
        for (var i = 0; i < native.MIDIGetNumberOfSources(); i++)
          _endpoint(native.MIDIGetSource(i), arena),
      ],
      destinations: [
        for (var i = 0; i < native.MIDIGetNumberOfDestinations(); i++)
          _endpoint(native.MIDIGetDestination(i), arena),
      ],
    ),
  );

  // ...........................................................................
  @override
  void connectSource(
    int source, {
    required int protocol,
    required int refCon,
  }) => _check(
    'MIDIPortConnectSource',
    native.MIDIPortConnectSource(
      native.aud_midi_apple_input_port(_open, _protocol(protocol)),
      source,
      Pointer.fromAddress(refCon),
    ),
  );

  @override
  void disconnectSource(int source, {required int protocol}) => _check(
    'MIDIPortDisconnectSource',
    native.MIDIPortDisconnectSource(
      native.aud_midi_apple_input_port(_open, _protocol(protocol)),
      source,
    ),
  );

  // ...........................................................................
  @override
  void send(
    int destination, {
    required int protocol,
    required int timestamp,
    required Uint32List words,
  }) => _check(
    'MIDISendEventList',
    native.aud_midi_apple_send(
      native.aud_midi_apple_output_port(_open),
      destination,
      _protocol(protocol),
      timestamp,
      _copy(words),
      words.length,
    ),
  );

  // ...........................................................................
  @override
  int createSource({required String name, required int protocol}) =>
      using((arena) {
        final out = arena<UnsignedInt>();
        final string = _cfString(name, arena);
        final status = native.MIDISourceCreateWithProtocol(
          native.aud_midi_apple_client_ref(_open),
          string,
          _protocol(protocol),
          out,
        );
        native.CFRelease(string.cast());
        _check('MIDISourceCreateWithProtocol', status);
        return out.value;
      });

  @override
  int createDestination({
    required String name,
    required int protocol,
    required int refCon,
  }) => using((arena) {
    final out = arena<Uint32>();
    _check(
      'MIDIDestinationCreateWithProtocol',
      native.aud_midi_apple_destination_create(
        _open,
        name.toNativeUtf8(allocator: arena).cast(),
        _protocol(protocol),
        refCon,
        out,
      ),
    );
    return out.value;
  });

  @override
  void describe(
    int endpoint, {
    int? uniqueId,
    String? manufacturer,
    String? model,
    int? groupBitmap,
  }) {
    if (uniqueId != null) {
      _setInteger(endpoint, native.kMIDIPropertyUniqueID, uniqueId);
    }
    if (manufacturer != null) {
      _setString(endpoint, native.kMIDIPropertyManufacturer, manufacturer);
    }
    if (model != null) _setString(endpoint, native.kMIDIPropertyModel, model);
    final groupsKey = native.aud_midi_apple_property_ump_active_group_bitmap();
    if (groupBitmap != null && groupsKey != nullptr) {
      _setInteger(endpoint, groupsKey.cast(), groupBitmap);
    }
  }

  @override
  int uniqueIdOf(int object) => using((arena) {
    final out = arena<Int>();
    _check(
      'MIDIObjectGetIntegerProperty',
      native.MIDIObjectGetIntegerProperty(
        object,
        native.kMIDIPropertyUniqueID,
        out,
      ),
    );
    return out.value;
  });

  @override
  void emit(
    int source, {
    required int protocol,
    required int timestamp,
    required Uint32List words,
  }) => _check(
    'MIDIReceivedEventList',
    native.aud_midi_apple_receive(
      source,
      _protocol(protocol),
      timestamp,
      _copy(words),
      words.length,
    ),
  );

  @override
  void disposeEndpoint(int endpoint) =>
      _check('MIDIEndpointDispose', native.MIDIEndpointDispose(endpoint));

  // ...........................................................................
  @override
  void attachTap({
    required int refCon,
    required int source,
    required MidiNativeTap tap,
    required bool ring,
  }) => _check(
    'aud_midi_apple_tap_attach',
    native.aud_midi_apple_tap_attach(
      _open,
      refCon,
      source,
      Pointer.fromAddress(tap.function),
      Pointer.fromAddress(tap.user),
      ring ? 1 : 0,
    ),
  );

  @override
  bool detachTap(int refCon) =>
      native.aud_midi_apple_tap_detach(_open, refCon, _tapTimeoutMs) == 0;

  @override
  void setTapRing(int refCon, {required bool ring}) =>
      native.aud_midi_apple_tap_set_ring(_open, refCon, ring ? 1 : 0);

  @override
  void setTapSource(int refCon, int source) =>
      native.aud_midi_apple_tap_set_source(_open, refCon, source);

  // ...........................................................................
  @override
  List<MidiCoreMidiPacket> readPackets() {
    final client = _open;
    final packets = <MidiCoreMidiPacket>[];
    for (;;) {
      final count = native.aud_midi_apple_read_packets(
        client,
        _readBuffer,
        capacityWords,
      );
      if (count == 0) return packets;
      final words = _readBuffer.asTypedList(count);
      for (var i = 0; i < count; i += _headerWords + words[i + 6]) {
        packets.add((
          refCon: words[i],
          protocol: words[i + 1],
          timestamp: words[i + 2] | words[i + 3] << 32,
          arrival: words[i + 4] | words[i + 5] << 32,
          words: Uint32List.fromList(
            words.sublist(i + _headerWords, i + _headerWords + words[i + 6]),
          ),
        ));
      }
    }
  }

  @override
  List<MidiCoreMidiNotification> readNotifications() {
    final client = _open;
    final notifications = <MidiCoreMidiNotification>[];
    for (;;) {
      final count = native.aud_midi_apple_read_notifications(
        client,
        _notificationBuffer,
        _notificationCapacity,
      );
      final words = _notificationBuffer.asTypedList(count * _noteWords);
      for (var i = 0; i < count * _noteWords; i += _noteWords) {
        notifications.add((
          messageId: words[i],
          values: List.unmodifiable(words.sublist(i + 1, i + _noteWords)),
        ));
      }
      if (count < _notificationCapacity) return notifications;
    }
  }

  @override
  int takeDropped() => native.aud_midi_apple_take_dropped(_open);

  // ...........................................................................
  @override
  void activateBluetoothConnections() => _check(
    'MIDIBluetoothDriverActivateAllConnections',
    native.aud_midi_apple_bluetooth_activate_all(),
  );

  @override
  void disconnectBluetooth(String uuid) => using(
    (arena) => _check(
      'MIDIBluetoothDriverDisconnect',
      native.aud_midi_apple_bluetooth_disconnect(
        uuid.toNativeUtf8(allocator: arena).cast(),
      ),
    ),
  );

  @override
  bool get bluetoothDriverAvailable =>
      native.aud_midi_apple_bluetooth_available() == 1;

  // ...........................................................................
  @override
  int now() => native.aud_midi_apple_now();

  @override
  late final MidiMachTimebase timebase = using((arena) {
    final numer = arena<Uint32>();
    final denom = arena<Uint32>();
    native.aud_midi_apple_timebase(numer, denom);
    return MidiMachTimebase(numer: numer.value, denom: denom.value);
  });

  // ...........................................................................
  /// The capacity of the ring buffer in 32-bit words.
  final int capacityWords;

  /// Whether the client is open.
  bool get isOpen => _client != nullptr;

  // ...........................................................................
  static const int _headerWords = native.AUD_MIDI_APPLE_RECORD_HEADER_WORDS;
  static const int _noteWords = native.AUD_MIDI_APPLE_NOTIFICATION_WORDS;
  static const int _notificationCapacity = 64;

  /// How long a detach waits for the calls of a tap in flight.
  static const int _tapTimeoutMs = 1000;

  Pointer<native.AudMidiAppleClient> _client = nullptr;
  NativeCallable<Void Function(Int32)>? _callable;
  Pointer<Uint32> _readBuffer = nullptr;
  Pointer<Uint32> _notificationBuffer = nullptr;
  Pointer<Uint32> _sendBuffer = nullptr;
  int _sendCapacity = 0;

  Pointer<native.AudMidiAppleClient> get _open {
    if (_client == nullptr) throw StateError('The client is not open');
    return _client;
  }

  /// Copies [words] into the send buffer, which grows as needed.
  Pointer<Uint32> _copy(Uint32List words) {
    if (_client == nullptr) throw StateError('The client is not open');
    if (words.length > _sendCapacity) {
      malloc.free(_sendBuffer);
      _sendCapacity = words.length < 256 ? 256 : words.length;
      _sendBuffer = malloc<Uint32>(_sendCapacity);
    }
    _sendBuffer.asTypedList(words.length).setAll(0, words);
    return _sendBuffer;
  }

  MidiCoreMidiDevice _device(int ref, Arena arena) => (
    ref: ref,
    uniqueId: _integer(ref, native.kMIDIPropertyUniqueID, arena) ?? 0,
    name: _string(ref, native.kMIDIPropertyName, arena),
    manufacturer: _string(ref, native.kMIDIPropertyManufacturer, arena),
    model: _string(ref, native.kMIDIPropertyModel, arena),
    driverOwner: _string(ref, native.kMIDIPropertyDriverOwner, arena),
    isOffline: _integer(ref, native.kMIDIPropertyOffline, arena) == 1,
    entities: [
      for (var i = 0; i < native.MIDIDeviceGetNumberOfEntities(ref); i++)
        _entity(native.MIDIDeviceGetEntity(ref, i), arena),
    ],
  );

  MidiCoreMidiEntity _entity(int ref, Arena arena) => (
    name: _string(ref, native.kMIDIPropertyName, arena),
    sources: [
      for (var i = 0; i < native.MIDIEntityGetNumberOfSources(ref); i++)
        _endpoint(native.MIDIEntityGetSource(ref, i), arena),
    ],
    destinations: [
      for (var i = 0; i < native.MIDIEntityGetNumberOfDestinations(ref); i++)
        _endpoint(native.MIDIEntityGetDestination(ref, i), arena),
    ],
  );

  MidiCoreMidiEndpoint _endpoint(int ref, Arena arena) {
    final groupsKey = native.aud_midi_apple_property_ump_active_group_bitmap();
    return (
      ref: ref,
      uniqueId: _integer(ref, native.kMIDIPropertyUniqueID, arena) ?? 0,
      name: _string(ref, native.kMIDIPropertyName, arena),
      displayName: _string(ref, native.kMIDIPropertyDisplayName, arena),
      manufacturer: _string(ref, native.kMIDIPropertyManufacturer, arena),
      model: _string(ref, native.kMIDIPropertyModel, arena),
      driverOwner: _string(ref, native.kMIDIPropertyDriverOwner, arena),
      isOffline: _integer(ref, native.kMIDIPropertyOffline, arena) == 1,
      isPrivate: _integer(ref, native.kMIDIPropertyPrivate, arena) == 1,
      protocol: _integer(ref, native.kMIDIPropertyProtocolID, arena) ?? 1,
      groupBitmap: groupsKey == nullptr
          ? null
          : _integer(ref, groupsKey.cast(), arena),
    );
  }

  int? _integer(int object, Pointer<CFString> key, Arena arena) {
    final out = arena<Int>();
    final status = native.MIDIObjectGetIntegerProperty(object, key, out);
    return status == 0 ? out.value : null;
  }

  String _string(int object, Pointer<CFString> key, Arena arena) {
    final out = arena<Pointer<CFString>>();
    if (native.MIDIObjectGetStringProperty(object, key, out) != 0) return '';
    final string = out.value;
    final length = native.CFStringGetLength(string);
    final characters = arena<UnsignedShort>(length + 1);
    final range = arena<native.CFRange>()
      ..ref.location = 0
      ..ref.length = length;
    native.CFStringGetCharacters(string, range.ref, characters);
    native.CFRelease(string.cast());
    return String.fromCharCodes(characters.cast<Uint16>().asTypedList(length));
  }

  void _setInteger(int object, Pointer<CFString> key, int value) => _check(
    'MIDIObjectSetIntegerProperty',
    native.MIDIObjectSetIntegerProperty(object, key, value),
  );

  void _setString(int object, Pointer<CFString> key, String value) =>
      using((arena) {
        final string = _cfString(value, arena);
        final status = native.MIDIObjectSetStringProperty(object, key, string);
        native.CFRelease(string.cast());
        _check('MIDIObjectSetStringProperty', status);
      });

  /// Returns a new CFString of [value]; the caller releases it.
  static Pointer<CFString> _cfString(String value, Arena arena) {
    final units = value.codeUnits;
    final characters = arena<UnsignedShort>(units.length + 1);
    characters.cast<Uint16>().asTypedList(units.length).setAll(0, units);
    return native.CFStringCreateWithCharacters(
      nullptr,
      characters,
      units.length,
    );
  }

  /// Returns [protocol] when it is 1 or 2; CoreMIDI aborts the process for
  /// other values in some calls.
  static int _protocol(int protocol) => protocol == 1 || protocol == 2
      ? protocol
      : throw ArgumentError.value(protocol, 'protocol', 'Must be 1 or 2');

  static void _check(String api, int status) {
    if (status != 0) throw MidiNativeError(api: api, code: status);
  }
}
