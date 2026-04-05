#!/usr/bin/env node
/**
 * Epoch warmup: pre-warm proving caches inside bb prove_loop daemons.
 *
 * When the bb daemon starts, pass --warmup-dir pointing to the file cache
 * so it constructs ProverInstance (with dummy witness) for each circuit type
 * before the first real proof arrives. This warms:
 *   - In-memory PrecomputedPolyCache (tier 1) in the actual proving process
 *   - Cross-process disk poly cache (tier 2)
 *   - ACIR bytecode parse cache
 *   - SRS point tables
 *
 * Savings: eliminates 500ms-5s cold-cache penalty per circuit type on daemon
 * restart or first epoch. Total: ~3-16s across 5-7 circuit types.
 *
 * The shell-script warmup (warmup-epoch.sh) only warms the disk cache and OS
 * page cache. This in-process warmup additionally warms the in-memory LRU cache,
 * which is the fastest tier and saves an additional ~100-200ms per circuit type.
 *
 * Enable: BB_WARMUP_DIR=/tmp/bb-file-cache (or any dir with *-bytecode-* files)
 * Disable: unset BB_WARMUP_DIR or BB_WARMUP_DIR=""
 *
 * Usage:
 *   node patches/apply_daemon_warmup.js          # apply
 *   node patches/apply_daemon_warmup.js --revert  # revert
 */

const fs = require('fs');
const path = require('path');

const AZTEC_ROOT = path.join(process.env.HOME, '.aztec/versions/4.1.3/node_modules/@aztec');
const REVERT = process.argv.includes('--revert');
const M = 'DAEMON_WARMUP_V1';

function patchFile(relPath, patches) {
    const filePath = path.join(AZTEC_ROOT, relPath);
    const backupPath = filePath + '.warmup-backup';

    if (REVERT) {
        if (fs.existsSync(backupPath)) {
            fs.copyFileSync(backupPath, filePath);
            fs.unlinkSync(backupPath);
            console.log(`  Reverted: ${relPath}`);
        } else {
            console.log(`  No backup: ${relPath}`);
        }
        return true;
    }

    let content = fs.readFileSync(filePath, 'utf-8');
    if (content.includes(M)) {
        console.log(`  Already patched: ${relPath}`);
        return true;
    }
    if (!fs.existsSync(backupPath)) {
        fs.copyFileSync(filePath, backupPath);
    }

    for (const { find, replace, label } of patches) {
        if (!content.includes(find)) {
            console.error(`  ERROR [${label}]: Anchor not found in ${relPath}`);
            console.error(`    Expected: "${find.substring(0, 80)}..."`);
            fs.copyFileSync(backupPath, filePath);
            return false;
        }
        content = content.replace(find, replace);
    }

    fs.writeFileSync(filePath, content);
    console.log(`  Patched: ${relPath}`);
    return true;
}

// ══════════════════════════════════════════════════════════════════════════════
// PATCH: execute.js - Add --warmup-dir to daemon spawn args
//
// When BB_WARMUP_DIR is set, passes --warmup-dir to bb prove_loop so the
// daemon pre-warms its in-memory PrecomputedPolyCache on startup.
// ══════════════════════════════════════════════════════════════════════════════
const EXECUTE_PATCHES = [
    {
        label: 'daemon-warmup-dir',
        find: [
            "    args.push('--disable_zk');",
            '    return args;',
            '}',
        ].join('\n'),
        replace: [
            "    args.push('--disable_zk');",
            `    // ${M}: Pass warmup directory so daemon pre-warms caches on startup`,
            "    const warmupDir = process.env.BB_WARMUP_DIR || '';",
            "    if (warmupDir && require('fs').existsSync(warmupDir)) {",
            "        args.push('--warmup-dir', warmupDir);",
            '    }',
            '    return args;',
            '}',
        ].join('\n'),
    },
];

// ══════════════════════════════════════════════════════════════════════════════
// Apply
// ══════════════════════════════════════════════════════════════════════════════
console.log(REVERT ? 'Reverting daemon warmup patch...' : 'Applying daemon warmup patch...');

let ok = true;
ok = patchFile('bb-prover/dest/bb/execute.js', EXECUTE_PATCHES) && ok;

if (!ok) {
    console.error('\nPatch FAILED. Run with --revert to restore backups.');
    process.exit(1);
}

console.log(REVERT
    ? '\nRevert complete.'
    : '\nPatch applied successfully.\nEnable at runtime: export BB_WARMUP_DIR=/tmp/bb-file-cache');
