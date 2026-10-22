// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// Checks the notices convention of the aud_midi family in a repo:
//
// - NOTICES.md in the root of the repo lists the third-party code,
// - every component directory under src/third_party has a row in NOTICES.md
//   whose Path column names it,
// - every row names a license from the permissive list or "public domain",
// - every component directory holds a license file, unless its row says
//   the license is in the header of the file,
// - every own source file outside src/third_party starts with the license
//   header of the family, generated files included (the files gg and helix
//   generate name their own copyright holder; the Objective-C trampolines
//   ffigen generates, `*.g.m`, carry none and are skipped).
//
// Usage: node scripts/check-notices.js [repoDir]
// Exits with 1 and the list of problems when the convention is broken.

import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs';
import { join, relative, sep } from 'node:path';
import { pathToFileURL } from 'node:url';

const permissive = [
  'MIT',
  'MIT-0',
  'BSD-2-Clause',
  'BSD-3-Clause',
  'Apache-2.0',
  'ISC',
  'Zlib',
  'zlib',
  'Unlicense',
  'CC0',
  'CC0-1.0',
  'BSL-1.0',
  'WTFPL',
  'public domain',
];

const header = /copyright \(c\) (audanika|ggsuite)/i;
const sourceExtensions = [
  '.c',
  '.cc',
  '.cpp',
  '.h',
  '.hpp',
  '.m',
  '.mm',
  '.java',
  '.kt',
  '.dart',
  '.js',
  '.ts',
];
const sourceDirs = ['src', 'lib', 'hook', 'scripts', 'test', 'bin', 'android'];
// `dna` holds the files helix generates; they carry no header of ours.
const skipDirs = ['third_party', 'node_modules', 'build', 'fixtures', 'dna'];

function walk(dir, files = []) {
  for (const entry of readdirSync(dir)) {
    if (skipDirs.includes(entry) || entry.startsWith('.')) continue;
    const path = join(dir, entry);
    if (statSync(path).isDirectory()) walk(path, files);
    else files.push(path);
  }
  return files;
}

function componentRows(notices) {
  return notices
    .split('\n')
    .filter((line) => line.startsWith('|') && !/^\|\s*-+/.test(line))
    .map((line) => line.split('|').slice(1, -1).map((cell) => cell.trim()))
    .filter((cells) => cells.length >= 3 && cells[0] !== 'Component');
}

export function checkNotices(repoDir) {
  const problems = [];
  const noticesPath = join(repoDir, 'NOTICES.md');
  if (!existsSync(noticesPath)) {
    problems.push('NOTICES.md is missing');
  }
  const thirdParty = join(repoDir, 'src', 'third_party');
  if (existsSync(thirdParty) && existsSync(noticesPath)) {
    const rows = componentRows(readFileSync(noticesPath, 'utf-8'));
    const components = readdirSync(thirdParty).filter((entry) =>
      statSync(join(thirdParty, entry)).isDirectory(),
    );
    for (const component of components) {
      const row = rows.find((cells) => cells[1].includes(`\`${component}`));
      if (!row) {
        problems.push(`src/third_party/${component} has no row in NOTICES.md`);
        continue;
      }
      const license = row[row.length - 1];
      if (!permissive.some((name) => license.includes(name))) {
        problems.push(`${component}: license "${license}" is not permissive`);
      }
      const hasLicenseFile = readdirSync(join(thirdParty, component)).some(
        (f) => /^(licen[cs]e|copying)/i.test(f),
      );
      if (!hasLicenseFile && !/header of the file/i.test(license)) {
        problems.push(`src/third_party/${component} has no license file`);
      }
    }
  }
  for (const dir of sourceDirs) {
    const path = join(repoDir, dir);
    if (!existsSync(path)) continue;
    for (const file of walk(path)) {
      if (!sourceExtensions.some((ext) => file.endsWith(ext))) continue;
      if (file.endsWith('.g.m')) continue;
      const head = readFileSync(file, 'utf-8').slice(0, 400);
      if (!head.includes('@license') || !header.test(head)) {
        problems.push(`${relative(repoDir, file).split(sep).join('/')} has no license header`);
      }
    }
  }
  return problems;
}

function main() {
  const repoDir = process.argv[2] ?? process.cwd();
  const problems = checkNotices(repoDir);
  if (problems.length === 0) {
    console.log('Notices are complete.');
    return;
  }
  console.error('The notices convention is broken:');
  for (const problem of problems) console.error(`  - ${problem}`);
  process.exit(1);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main();
}
