// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:test/test.dart';

void main() {
  Future<ProcessResult> run(String dir) =>
      Process.run('node', ['scripts/check-notices.js', dir]);

  group('scripts/check-notices.js', () {
    test('passes a repo whose notices are complete', () async {
      final result = await run('test/fixtures/notices/good');
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(result.stdout, contains('complete'));
    });

    test('passes this repo', () async {
      final result = await run('.');
      expect(result.exitCode, 0, reason: '${result.stderr}');
    });

    test('names every problem of a broken repo', () async {
      final result = await run('test/fixtures/notices/bad');
      expect(result.exitCode, 1);
      expect(result.stderr, contains('lib_b has no row'));
      expect(
        result.stderr,
        contains('"LGPL-2.1, `lib_a/LICENSE`" is not permissive'),
      );
      expect(result.stderr, contains('lib_a has no license file'));
      expect(result.stderr, contains('src/own.c has no license header'));
    });

    test('reports a missing NOTICES.md', () async {
      final result = await run('test/fixtures/notices/missing');
      expect(result.exitCode, 1);
      expect(result.stderr, contains('NOTICES.md is missing'));
    });
  });
}
