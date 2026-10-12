// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:test/test.dart';

void main() {
  // Whether [command] runs on this machine.
  bool has(String command) {
    try {
      return Process.runSync(command, ['--version']).exitCode == 0;
    } on ProcessException {
      return false;
    }
  }

  final missing = [
    if (!has('node')) 'node',
    if (!has('clang') && !has('cc') && !has('gcc')) 'a C compiler',
  ];

  group('scripts/test-native.js', () {
    test(
      'passes the tap slots of the shim under the sanitizers',
      () async {
        final result = await Process.run('node', [
          'scripts/test-native.js',
          '--no-rtsan',
        ]);
        expect(
          result.exitCode,
          0,
          reason: '${result.stdout}\n${result.stderr}',
        );
        expect(result.stdout, contains('all checks passed'));
      },
      skip: missing.isEmpty ? false : '${missing.join(' and ')} missing',
      timeout: const Timeout(Duration(minutes: 5)),
    );
  });
}
