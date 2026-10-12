// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

/// Builds the C shim of the package into a dynamic library for macOS and
/// iOS; on every other target operating system it does nothing, so that
/// the aud_midi umbrella builds everywhere.
void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    final os = input.config.code.targetOS;
    if (os != OS.macOS && os != OS.iOS) return;

    await CBuilder.library(
      name: 'aud_midi_apple',
      assetName: 'src/native/aud_midi_apple_bindings.g.dart',
      sources: const [
        'src/aud_midi_apple.c',
        'src/aud_midi_apple_tap.c',
        'src/aud_midi_apple_objc.g.m',
      ],
      frameworks: const ['CoreFoundation', 'CoreMIDI', 'Foundation'],
      flags: const ['-fobjc-arc'],
    ).run(input: input, output: output);
  });
}
