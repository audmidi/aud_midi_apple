// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:aud_midi_apple/aud_midi_apple.dart';
import 'package:aud_midi_core/aud_midi_core.dart';
import 'package:aud_midi_standard/aud_midi_standard.dart';
import 'package:test/test.dart';

void main() {
  late _FakeSession session;
  late List<_FakeBrowser> browsers;
  late List<Set<int>> endpointQueries;
  late MidiAppleNetworkBackend backend;

  const portIds = [MidiPortId('coremidi:1'), MidiPortId('coremidi:2')];
  const studio = MidiNetworkHostInfo(
    name: 'Studio',
    address: '192.0.2.2',
    port: 5004,
  );
  const studioHost = (
    name: 'Studio',
    address: '192.0.2.2',
    port: 5004,
    isBonjour: false,
  );

  setUp(() {
    session = _FakeSession();
    browsers = [];
    endpointQueries = [];
    backend = MidiAppleNetworkBackend(
      networkSession: session,
      browser: () {
        final browser = _FakeBrowser();
        browsers.add(browser);
        return browser;
      },
      portsOf: (endpoints) {
        endpointQueries.add(endpoints);
        return portIds;
      },
      portTimeout: const Duration(milliseconds: 100),
    );
  });

  group('MidiAppleNetworkBackend', () {
    group('enable(name, port, policy)', () {
      test('waits for the port of the session', () async {
        session.zeroPortReads = 2;
        expect((await backend.enable(name: 'x')).port, 5004);
        session.zeroPortReads = 1000;
        expect((await backend.enable(name: 'x')).port, 0);
        expect(backend.portTimeout, const Duration(milliseconds: 100));
      });

      test('enables the session with the policy', () async {
        final info = await backend.enable(
          name: 'ignored',
          port: 1,
          policy: MidiNetworkConnectionPolicy.contacts,
        );
        expect(session.isEnabled, isTrue);
        expect(session.connectionPolicy, 1);
        expect(
          info,
          MidiNetworkSessionInfo(
            localName: 'iPad',
            enabled: true,
            port: 5004,
            protocol: MidiNetworkProtocol.appleMidi,
            connectionPolicy: MidiNetworkConnectionPolicy.contacts,
          ),
        );
      });
    });

    group('disable()', () {
      test('disables the session', () async {
        session.isEnabled = true;
        await backend.disable();
        expect(session.isEnabled, isFalse);
      });
    });

    group('connect(host)', () {
      test('adds a connection with the session ports', () async {
        final connection = await backend.connect(studio);
        expect(session.connections, equals([studioHost]));
        expect(
          connection,
          MidiNetworkConnectionInfo(
            host: studio,
            state: MidiNetworkConnectionState.connected,
            portIds: portIds,
          ),
        );
        expect(
          endpointQueries,
          equals([
            {11, 12},
          ]),
        );
      });

      test('throws when the session refuses the host', () async {
        session.accept = false;
        await expectLater(
          backend.connect(studio),
          throwsA(
            isA<MidiNativeError>().having(
              (e) => e.api,
              'api',
              'MIDINetworkSession.addConnection',
            ),
          ),
        );
      });
    });

    group('disconnect(host)', () {
      test('removes the connection', () async {
        await backend.connect(studio);
        await backend.disconnect(
          studio.copyWith(source: MidiNetworkHostSource.bonjour),
        );
        expect(session.connections, isEmpty);
      });
    });

    group('session', () {
      test('lists the connections with their source', () {
        session.connections.addAll([
          studioHost,
          (name: 'Pad', address: 'pad.local.', port: 5006, isBonjour: true),
        ]);
        expect(
          backend.session.connections.map((c) => c.host.source),
          equals([MidiNetworkHostSource.manual, MidiNetworkHostSource.bonjour]),
        );
      });
    });

    group('sessionChanges', () {
      test('reports the session while someone listens', () async {
        final changes = <MidiNetworkSessionInfo>[];
        final subscription = backend.sessionChanges.listen(changes.add);
        expect(session.observer, isNotNull);
        session.isEnabled = true;
        session.observer!();
        await pumpEventQueue();
        expect(changes.single.enabled, isTrue);
        await subscription.cancel();
        expect(session.observer, isNull);
      });
    });

    group('browse()', () {
      test('reports contacts and Bonjour sessions', () async {
        session.contacts.add(studioHost);
        final lists = <List<MidiNetworkHostInfo>>[];
        final subscription = backend.browse().listen(lists.add);
        await pumpEventQueue();
        final browser = browsers.single;
        expect(browser.type, '_apple-midi._udp');
        browser
          ..emit((
            kind: MidiBonjourBrowser.found,
            name: 'Pad',
            host: 'pad.local.',
            port: 5006,
          ))
          ..emit((kind: MidiBonjourBrowser.failed, name: '', host: '', port: 1))
          ..emit((
            kind: MidiBonjourBrowser.lost,
            name: 'Pad',
            host: '',
            port: 0,
          ));
        await pumpEventQueue();
        const pad = MidiNetworkHostInfo(
          name: 'Pad',
          address: 'pad.local.',
          port: 5006,
          source: MidiNetworkHostSource.bonjour,
        );
        expect(
          lists,
          equals([
            [studio],
            [studio, pad],
            [studio],
          ]),
        );
        await subscription.cancel();
        expect(browser.stops, 1);
      });

      test('ends when browsing fails', () async {
        final stream = backend.browse();
        browsers.single.fail = true;
        expect(await stream.toList(), equals([<MidiNetworkHostInfo>[]]));
      });
    });

    group('close()', () {
      test('stops observers and browsers', () async {
        final subscription = backend.browse().listen((_) {});
        await pumpEventQueue();
        final done = backend.sessionChanges.toList();
        backend.close();
        expect(browsers.single.stops, 1);
        expect(session.observer, isNull);
        expect(await done, isEmpty);
        await subscription.cancel();
      });
    });

    group('policyOf(value), policyValueOf(policy)', () {
      test('map MIDINetworkConnectionPolicy', () {
        for (final policy in MidiNetworkConnectionPolicy.values) {
          expect(
            MidiAppleNetworkBackend.policyOf(
              MidiAppleNetworkBackend.policyValueOf(policy),
            ),
            policy,
          );
        }
        expect(
          MidiAppleNetworkBackend.policyOf(9),
          MidiNetworkConnectionPolicy.specificPeers,
        );
      });
    });

    group('networkSession', () {
      test('is the session of the operating system', () {
        expect(backend.networkSession, same(session));
      });
    });
  });
}

// #############################################################################
final class _FakeSession implements MidiAppleNetworkSession {
  @override
  bool isAvailable = true;

  @override
  bool isEnabled = false;

  @override
  int connectionPolicy = 0;

  @override
  final contacts = <MidiAppleNetworkHost>[];

  @override
  final connections = <MidiAppleNetworkHost>[];

  bool accept = true;
  void Function()? observer;

  @override
  void setEnabled(bool enabled) => isEnabled = enabled;

  @override
  void setConnectionPolicy(int policy) => connectionPolicy = policy;

  @override
  bool addConnection(MidiAppleNetworkHost host) {
    if (accept) connections.add(host);
    return accept;
  }

  @override
  bool removeConnection(MidiAppleNetworkHost host) {
    final before = connections.length;
    connections.removeWhere(
      (c) => c.address == host.address && c.port == host.port,
    );
    return connections.length < before;
  }

  @override
  void observe(void Function() onChange) => observer = onChange;

  @override
  void stopObserving() => observer = null;

  @override
  String get networkName => 'iPad';

  @override
  String get localName => 'Session 1';

  /// The number of port reads that return 0 before the session has a port.
  int zeroPortReads = 0;

  @override
  int get networkPort {
    if (zeroPortReads == 0) return 5004;
    zeroPortReads--;
    return 0;
  }

  @override
  int get sourceEndpoint => 11;

  @override
  int get destinationEndpoint => 12;
}

// #############################################################################
final class _FakeBrowser implements MidiBonjourBrowser {
  void Function(MidiBonjourEvent event)? _onEvent;
  String? type;
  bool fail = false;
  int stops = 0;

  void emit(MidiBonjourEvent event) => _onEvent!(event);

  @override
  void start(String type, void Function(MidiBonjourEvent event) onEvent) {
    if (fail) {
      throw const MidiNativeError(api: 'DNSServiceBrowse', code: -65540);
    }
    this.type = type;
    _onEvent = onEvent;
  }

  @override
  void stop() => stops++;
}
