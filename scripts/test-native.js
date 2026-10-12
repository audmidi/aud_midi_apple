// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// Builds and runs the host-side test of the tap slots of the shim,
// test/native/aud_midi_apple_tap_test.c, the part of the shim independent
// of CoreMIDI, in up to three builds:
//
// - the address and the undefined behaviour sanitizer,
// - Clang's RealtimeSanitizer when a compiler on this machine has it (LLVM
//   from Homebrew; Apple's clang refuses it), which checks that the call
//   path of a tap neither blocks nor allocates,
// - the thread sanitizer for the attach and detach against calls on other
//   threads.
//
// The binaries are cached under .dart_tool by the hash of their inputs.
//
//   node scripts/test-native.js               every build this machine has
//   node scripts/test-native.js --no-sanitize  one build, no sanitizer
//   node scripts/test-native.js --rtsan        fail without rtsan
//   node scripts/test-native.js --no-rtsan     skip the rtsan build
//   node scripts/test-native.js --no-tsan      skip the thread sanitizer

import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const args = process.argv.slice(2);
const sanitize = !args.includes('--no-sanitize');
const wantRtsan = args.includes('--rtsan');
const skipRtsan = args.includes('--no-rtsan') || !sanitize;
const skipTsan = args.includes('--no-tsan') || !sanitize;

const sources = [
  path.join(root, 'src', 'aud_midi_apple_tap.c'),
  path.join(root, 'test', 'native', 'aud_midi_apple_tap_test.c'),
];
const headers = [
  path.join(root, 'src', 'aud_midi_apple_tap.h'),
  path.join(root, 'src', 'aud_midi_apple.h'),
];

// Compilers that may carry the RealtimeSanitizer.
const rtsanCandidates = [
  process.env.AUD_RTSAN_CC,
  '/opt/homebrew/opt/llvm/bin/clang',
  '/usr/local/opt/llvm/bin/clang',
  'clang',
].filter(Boolean);

// Whether `compiler` exists and builds a program with `flags`.
function works(compiler, flags) {
  const probe = spawnSync(compiler, ['--version'], { encoding: 'utf8' });
  if (probe.status !== 0) return false;
  if (flags.length === 0) return true;
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'aud-probe-'));
  try {
    const source = path.join(dir, 'probe.c');
    fs.writeFileSync(source, 'int main(void) { return 0; }\n');
    const build = spawnSync(
      compiler,
      [...flags, source, '-o', path.join(dir, 'probe')],
      { encoding: 'utf8' },
    );
    return build.status === 0;
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

function defaultCompiler() {
  for (const candidate of ['clang', 'cc', 'gcc']) {
    if (works(candidate, [])) return candidate;
  }
  throw new Error('No C compiler found (clang, cc or gcc)');
}

function rtsanCompiler() {
  for (const candidate of rtsanCandidates) {
    if (works(candidate, ['-fsanitize=realtime', '-std=c23'])) {
      return candidate;
    }
  }
  return null;
}

// Builds one variant of the test binary unless it is cached; returns its
// path.
function build(name, compiler, extraFlags) {
  const hash = createHash('sha256');
  hash.update(name);
  hash.update(compiler);
  hash.update(extraFlags.join(' '));
  for (const file of [...sources, ...headers]) {
    hash.update(file);
    hash.update(fs.readFileSync(file));
  }
  const outDir = path.join(root, '.dart_tool', 'aud_native_test');
  fs.mkdirSync(outDir, { recursive: true });
  const binary = path.join(
    outDir,
    `aud_midi_apple_tap_test_${name}_${hash.digest('hex').slice(0, 16)}`,
  );
  if (fs.existsSync(binary)) return binary;
  const flags = [
    ...extraFlags,
    '-g',
    '-O1',
    '-Wall',
    '-Wextra',
    '-fno-omit-frame-pointer',
    `-I${path.join(root, 'src')}`,
    '-o',
    binary,
    ...sources,
    '-lpthread',
  ];
  const result = spawnSync(compiler, flags, { encoding: 'utf8' });
  if (result.status !== 0) {
    process.stderr.write(result.stdout + result.stderr);
    process.exit(result.status ?? 1);
  }
  return binary;
}

function run(name, binary, env) {
  process.stdout.write(`${name}: ${path.basename(binary)}\n`);
  const result = spawnSync(binary, [], {
    encoding: 'utf8',
    env: { ...process.env, ...env },
  });
  process.stdout.write(result.stdout);
  process.stderr.write(result.stderr);
  if (result.status !== 0) process.exit(result.status ?? 1);
}

// The rtsan run must catch the probe allocation of the call path;
// otherwise its silence would prove nothing.
function probeRtsan(binary, env) {
  const result = spawnSync(binary, [], {
    encoding: 'utf8',
    env: { ...process.env, ...env, AUD_TEST_RTSAN_PROBE: '1' },
  });
  if (result.status === 0 || !result.stderr.includes('RealtimeSanitizer')) {
    process.stderr.write(
      'rtsan: the probe allocation on the call path was not caught\n' +
        result.stdout +
        result.stderr,
    );
    process.exit(1);
  }
  process.stdout.write('rtsan: the probe allocation was caught\n');
}

function main() {
  const compiler = defaultCompiler();
  const leaks =
    process.platform === 'linux' ? 'detect_leaks=1' : 'detect_leaks=0';
  const main = build(
    sanitize ? 'asan' : 'plain',
    compiler,
    sanitize ? ['-std=c11', '-fsanitize=address,undefined'] : ['-std=c11'],
  );
  run(sanitize ? 'asan+ubsan' : 'plain', main, {
    UBSAN_OPTIONS: 'print_stacktrace=1:halt_on_error=1',
    ASAN_OPTIONS: leaks,
  });
  if (!skipRtsan) {
    const rtsanCc = rtsanCompiler();
    if (rtsanCc === null) {
      if (wantRtsan) {
        throw new Error('No compiler with -fsanitize=realtime found');
      }
      process.stdout.write('rtsan: no compiler has it, skipped\n');
    } else {
      const rtsan = build('rtsan', rtsanCc, [
        '-std=c23',
        '-fsanitize=realtime',
        '-DAUD_MIDI_RTSAN=1',
      ]);
      // Every violation aborts the run: the test fails on any.
      const env = { RTSAN_OPTIONS: 'halt_on_error=true' };
      run('rtsan', rtsan, env);
      probeRtsan(rtsan, env);
    }
  }
  if (!skipTsan) {
    if (!works(compiler, ['-fsanitize=thread'])) {
      process.stdout.write('tsan: the compiler lacks it, skipped\n');
      return;
    }
    const tsan = build('tsan', compiler, ['-std=c11', '-fsanitize=thread']);
    run('tsan', tsan, {
      TSAN_OPTIONS: 'halt_on_error=1:second_deadlock_stack=1',
    });
  }
}

main();
