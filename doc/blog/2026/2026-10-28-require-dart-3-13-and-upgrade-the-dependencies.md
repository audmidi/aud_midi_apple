<!--
@license
Copyright (c) audanika

Use of this source code is governed by terms that can be
found in the LICENSE file in the root of this package.
-->

# Require Dart 3.13 and upgrade the dependencies

## Motivation

- The packages of this family are maintained in one pass: every repo moves to
  the current SDK, takes the current versions of its dependencies and rebuilds
  its DNA instances.
- A common SDK floor keeps the family resolvable as one: a consumer on Dart
  3.13 should not have to carry a package that still allows the previous minor.
- `dna_audanika` ^0.1.0 brings the blog and translate layers, refreshed guides
  and a README check; the old constraint kept all of that out.

## Strategy

- Raise the SDK constraint to `^3.13.0`, the versions the family builds and
  tests with.
- Let `gg do upgrade deps` lift every dependency to its current version and
  tighten the constraints to what resolved.
- Rebuild the DNA with `gg dna build` and let the DNA test of the repo verify
  the instances when the checks run.
- Let `dart format` of the new SDK reformat what it formats differently now; no
  code changes by hand.
- Keep the public API untouched.

## Implementation 1: SDK and dependencies

- `pubspec.yaml`: `environment.sdk` moves from `^3.12.2` to `^3.13.0`.
- Dependencies upgraded: `dna_audanika` ^0.1.0, `helix` ^1.14.0.
- The formatter of Dart 3.13 reformats 6 files: trailing commas after single
  parameters and rewrapped expressions, nothing in behaviour.
- The off-Apple branch of the Bluetooth picker is excluded from coverage: the
  tests run on macOS only and cannot reach it.
- The analyzer and the tests stay green.

## Implementation 2: DNA instances

- `dna/_vars.json` already carried the identity; the name of the quick check
  pipeline, `Quick Check`, which the GitHub ruleset requires, was added.
- `gg dna build` instantiated the layers: the blog guide and its templates, the
  translate guide, the refreshed README guides with `scripts/check-readme.js`,
  the updated AI guides and the `/blog`, `/translate` and `/readme` skills.
- gg 17.6 builds with helix 1.13 and folded `.claude/CLAUDE_dna_gg.md` into
  `CLAUDE.md`; the DNA test of the repo runs with helix 1.14 and restored the
  file on the next check. Both landed as `#gg: generated DNA` commits and
  cancel out for `CLAUDE.md`.

## Dependency updates

- `dna_audanika` ^0.1.0: the layers `dna_blog` and `dna_translate`, the README
  check script, refreshed guides and skills, and new required variables (see
  above).
- `helix` 1.14: the DNA engine the test of this repo builds with.

## Open Points

- The README does not follow the new README template yet:
  `scripts/check-readme.js` reports the missing sections and the missing
  language switcher. A follow-up pass brings it in line.
- The translate guide asks for a German copy of every file under `doc`; this
  post has one, the rest follows with the README pass.
- Until gg builds with helix 1.14, `gg dna build` and the DNA test disagree
  about `CLAUDE.md`; the test has the last word.
