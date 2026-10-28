// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

@TestOn('mac-os')
@Timeout(Duration(minutes: 3))
library;

import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:test/test.dart';

import '../../hook/build.dart' as build_hook;

// Runs the build hook for every target the umbrella builds for: Apple
// targets get the shim's dynamic library, all others nothing.
void main() {
  // Returns the platform line of the Mach-O build version of [file].
  String platformOf(Uri file) {
    final result = Process.runSync('xcrun', [
      'vtool',
      '-show-build',
      file.toFilePath(),
    ]);
    return RegExp(r'platform (\w+)')
        .firstMatch(result.stdout as String)!
        .group(1)!;
  }

  // Returns the libraries [file] links.
  String librariesOf(Uri file) =>
      Process.runSync('otool', ['-L', file.toFilePath()]).stdout as String;

  group('hook/build.dart', () {
    final apple = [
      (OS.iOS, IOSSdk.iPhoneSimulator, Architecture.arm64, 'IOSSIMULATOR'),
      (OS.iOS, IOSSdk.iPhoneOS, Architecture.arm64, 'IOS'),
      (OS.macOS, null, Architecture.arm64, 'MACOS'),
      (OS.macOS, null, Architecture.x64, 'MACOS'),
    ];
    for (final (os, sdk, architecture, platform) in apple) {
      test('builds the shim for $os ${sdk ?? ''} $architecture', () async {
        await testCodeBuildHook(
          mainMethod: build_hook.main,
          targetOS: os,
          targetIOSSdk: sdk,
          targetIOSVersion: 15,
          targetMacOSVersion: 12,
          targetArchitecture: architecture,
          check: (input, output) {
            final asset = output.assets.code.single;
            expect(
              asset.id,
              'package:aud_midi_apple/src/native/'
              'aud_midi_apple_bindings.g.dart',
            );
            expect(platformOf(asset.file!), platform);
            final libraries = librariesOf(asset.file!);
            expect(libraries, contains('CoreMIDI.framework'));
            expect(libraries, isNot(contains('CoreBluetooth')));
          },
        );
      });
    }

    for (final os in [OS.linux, OS.windows, OS.android]) {
      test('builds nothing for $os', () async {
        await testCodeBuildHook(
          mainMethod: build_hook.main,
          targetOS: os,
          targetArchitecture: Architecture.arm64,
          check: (input, output) => expect(output.assets.code, isEmpty),
        );
      });
    }
  });
}
