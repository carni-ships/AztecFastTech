#!/usr/bin/env node
//
// purge-archiver-logs.js
//
// Purges unnecessary log data from the Aztec prover's archiver LMDB database.
// The prover never reads logs, but the archiver stores all private/public/contract-class
// logs since genesis. This script removes them to reclaim space.
//
// Prerequisites:
//   - The prover must NOT be running (LMDB single-writer lock)
//   - Python 3 with the 'lmdb' package installed (pip3 install lmdb)
//
// Usage:
//   node scripts/purge-archiver-logs.js [--dry-run] [--compact] [--db-path PATH]
//
// The script shells out to Python because the Node.js lmdb package (v3.5.3)
// crashes (SIGABRT) when opening databases created by the Aztec native LMDB backend.
// Python's lmdb binding handles the same files without issue.

const { execSync } = require('child_process');
const { existsSync, statSync, writeFileSync, unlinkSync } = require('fs');
const { tmpdir } = require('os');
const path = require('path');

// --- Configuration ---
const DEFAULT_DB_DIR = path.resolve(__dirname, '..', '.prover-data', 'archiver');

const LOG_MAPS = [
  'archiver_private_tagged_logs_by_tag',
  'archiver_public_tagged_logs_by_tag',
  'archiver_private_log_keys_by_block',
  'archiver_public_log_keys_by_block',
  'archiver_public_logs_by_block',
  'archiver_contract_class_logs_by_block',
];

// --- Parse args ---
const args = process.argv.slice(2);
const dryRun = args.includes('--dry-run');
const compact = args.includes('--compact');
const dbPathIdx = args.indexOf('--db-path');
const dbDir = dbPathIdx >= 0 ? args[dbPathIdx + 1] : DEFAULT_DB_DIR;

const dbFile = path.join(dbDir, 'data.mdb');

if (!existsSync(dbFile)) {
  console.error(`Error: database not found at ${dbFile}`);
  process.exit(1);
}

const sizeBefore = statSync(dbFile).size;
console.log(`Database: ${dbFile}`);
console.log(`File size: ${(sizeBefore / 1024 / 1024).toFixed(1)} MB`);
console.log(`Mode: ${dryRun ? 'DRY RUN (no changes)' : 'LIVE'}`);
console.log('');

// --- Build Python script ---
const pyScript = `
import lmdb
import sys
import json

db_dir = ${JSON.stringify(dbDir)}
dry_run = ${dryRun ? 'True' : 'False'}
compact = ${compact ? 'True' : 'False'}
log_maps = ${JSON.stringify(LOG_MAPS)}

map_size = 2 * 1024 * 1024 * 1024  # 2 GB

if dry_run:
    env = lmdb.open(db_dir, readonly=True, max_dbs=10, map_size=map_size, subdir=True)
else:
    env = lmdb.open(db_dir, readonly=False, max_dbs=10, map_size=map_size, subdir=True)

data_db = env.open_db(b'data')

results = {}

if dry_run:
    # Read-only scan: count entries and bytes per log map
    with env.begin(db=data_db) as txn:
        for map_name in log_maps:
            prefix = ('map:' + map_name).encode('utf8')
            cursor = txn.cursor()
            count = 0
            key_bytes = 0
            val_bytes = 0
            if cursor.set_range(prefix):
                while True:
                    k = cursor.key()
                    if not k.startswith(prefix):
                        break
                    v = cursor.value()
                    count += 1
                    key_bytes += len(k)
                    val_bytes += len(v)
                    if not cursor.next():
                        break
            results[map_name] = {
                'count': count,
                'key_bytes': key_bytes,
                'val_bytes': val_bytes,
                'total_bytes': key_bytes + val_bytes,
            }
else:
    # Delete entries for each log map
    for map_name in log_maps:
        prefix = ('map:' + map_name).encode('utf8')
        count = 0
        key_bytes = 0
        val_bytes = 0

        with env.begin(db=data_db, write=True) as txn:
            cursor = txn.cursor()
            if cursor.set_range(prefix):
                while True:
                    k = cursor.key()
                    if not k.startswith(prefix):
                        break
                    v = cursor.value()
                    count += 1
                    key_bytes += len(k)
                    val_bytes += len(v)
                    if not cursor.delete():
                        break

        results[map_name] = {
            'count': count,
            'key_bytes': key_bytes,
            'val_bytes': val_bytes,
            'total_bytes': key_bytes + val_bytes,
        }

    if compact:
        import shutil, tempfile, os
        # LMDB compaction: copy with MDB_CP_COMPACT then replace
        compact_dir = db_dir + '.compact'
        if os.path.exists(compact_dir):
            shutil.rmtree(compact_dir)
        env.copy(compact_dir, compact=True)
        env.close()
        # Replace original with compacted
        for f in ['data.mdb', 'lock.mdb']:
            src = os.path.join(compact_dir, f)
            dst = os.path.join(db_dir, f)
            if os.path.exists(src):
                shutil.move(src, dst)
        shutil.rmtree(compact_dir)
        results['__compacted'] = True
    else:
        env.close()

print(json.dumps(results))
`;

// --- Execute ---
const pyTmpFile = path.join(tmpdir(), `purge-archiver-logs-${process.pid}.py`);
try {
  writeFileSync(pyTmpFile, pyScript);
  const raw = execSync(`python3 ${JSON.stringify(pyTmpFile)}`, {
    encoding: 'utf8',
    maxBuffer: 10 * 1024 * 1024,
    timeout: 120_000,
  }).trim();

  const results = JSON.parse(raw);
  const compacted = results.__compacted;
  delete results.__compacted;

  let totalEntries = 0;
  let totalBytes = 0;

  console.log('Log map results:');
  console.log('-'.repeat(80));
  for (const [name, stats] of Object.entries(results)) {
    const shortName = name.replace('archiver_', '');
    const mb = (stats.total_bytes / 1024 / 1024).toFixed(2);
    console.log(
      `  ${shortName.padEnd(40)} ${String(stats.count).padStart(8)} entries  ${mb.padStart(8)} MB`
    );
    totalEntries += stats.count;
    totalBytes += stats.total_bytes;
  }
  console.log('-'.repeat(80));
  console.log(
    `  ${'TOTAL'.padEnd(40)} ${String(totalEntries).padStart(8)} entries  ${(totalBytes / 1024 / 1024).toFixed(2).padStart(8)} MB`
  );
  console.log('');

  if (dryRun) {
    console.log('Dry run complete. No data was modified.');
    console.log(`Estimated savings: ${(totalBytes / 1024 / 1024).toFixed(1)} MB of entry data.`);
    console.log('Run without --dry-run to delete, add --compact to also shrink the file.');
  } else {
    console.log(`Deleted ${totalEntries.toLocaleString()} entries (${(totalBytes / 1024 / 1024).toFixed(1)} MB of entry data).`);
    if (compacted) {
      const sizeAfter = statSync(dbFile).size;
      const saved = sizeBefore - sizeAfter;
      console.log(`Compaction complete. File size: ${(sizeAfter / 1024 / 1024).toFixed(1)} MB (saved ${(saved / 1024 / 1024).toFixed(1)} MB on disk).`);
    } else {
      console.log('Note: LMDB file size does not shrink until compaction. Freed pages will be reused.');
      console.log('Run with --compact to also shrink the file on disk.');
    }
  }
} catch (err) {
  if (err.stderr) {
    console.error('Python error:', err.stderr);
  } else {
    console.error('Error:', err.message);
  }
  process.exit(1);
} finally {
  try { unlinkSync(pyTmpFile); } catch (_) {}
}
