#!/usr/bin/env node
/**
 * Inter-proof pipelining: speculative input prefetch.
 *
 * While a proof is running, the agent peeks at the broker's priority queue to
 * see which job would be assigned next. It then pre-fetches and deserializes
 * that job's inputs from the proof store. When the current proof completes and
 * the agent gets assigned the peeked job, it skips the input fetch (cache hit).
 *
 * With InlineProofStore, the savings per proof are ~10-50ms (JSON parse).
 * With FileStoreProofStore, savings can be ~50-200ms (file I/O + deserialization).
 *
 * The real savings come from having the inputs ready instantly, reducing the
 * gap between proof N completion and proof N+1's ACVM start.
 *
 * Safety:
 *   - peekNextProvingJob is read-only: no queue mutation, no job claiming
 *   - Prefetched inputs are keyed by job ID; discarded on mismatch
 *   - Disabled by default; enable with PROVER_WITNESS_PREFETCH=1
 *   - Falls back to normal path if prefetch misses or errors
 *
 * Usage:
 *   node patches/apply_witness_prefetch.js          # apply
 *   node patches/apply_witness_prefetch.js --revert  # revert
 *   PROVER_WITNESS_PREFETCH=1 ./scripts/start-prover.sh  # enable at runtime
 */

const fs = require('fs');
const path = require('path');

const AZTEC_ROOT = path.join(process.env.HOME, '.aztec/versions/4.1.3/node_modules/@aztec');
const REVERT = process.argv.includes('--revert');
const M = 'WITNESS_PREFETCH_V1';

function patchFile(relPath, patches) {
    const filePath = path.join(AZTEC_ROOT, relPath);
    const backupPath = filePath + '.wpf-backup';

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
// PATCH 1: ProvingBroker - peekNextProvingJob()
//
// Reads queue heads across priority-ordered proof types without dequeueing.
// Respects the same memory-aware scheduling limits as getProvingJob.
// ══════════════════════════════════════════════════════════════════════════════
const BROKER_PATCHES = [
    {
        label: 'broker-peek',
        find: [
            '    getProvingJob(filter) {',
            '        return Promise.resolve(this.#getProvingJob(filter));',
            '    }',
        ].join('\n'),
        replace: [
            '    getProvingJob(filter) {',
            '        return Promise.resolve(this.#getProvingJob(filter));',
            '    }',
            `    /** ${M}: Non-claiming queue lookahead for input prefetch. */`,
            '    peekNextProvingJob(filter = { allowList: [] }) {',
            '        const ap = Array.isArray(filter.allowList) && filter.allowList.length > 0',
            '            ? [...filter.allowList]',
            '            : Object.values(ProvingRequestType).filter(x => typeof x === "number");',
            '        ap.sort(proofTypeComparator);',
            '        const H = new Set([11, 12, 15]), MD = new Set([2, 3, 5, 6, 8, 9, 16, 17]);',
            '        const mH = parseInt(process.env.PROVER_MAX_CONCURRENT_HEAVY ?? "1", 10);',
            '        const mL = parseInt(process.env.PROVER_MAX_CONCURRENT_LARGE ?? "2", 10);',
            '        let hI = 0, lI = 0;',
            '        for (const [, m] of this.inProgress) {',
            '            const j = this.jobsCache.get(m.id);',
            '            if (j && H.has(j.type)) { hI++; lI++; }',
            '            else if (j && MD.has(j.type)) { lI++; }',
            '        }',
            '        for (const pt of ap) {',
            '            if (H.has(pt) && hI >= mH) continue;',
            '            if ((H.has(pt) || MD.has(pt)) && lI >= mL) continue;',
            '            const q = this.queues[pt];',
            '            // PriorityQueue.peek() reads head without removing',
            '            const head = q.items && q.items.peek ? q.items.peek() : undefined;',
            '            if (head) {',
            '                const job = this.jobsCache.get(head.id);',
            '                if (job && !this.inProgress.has(head.id) && !this.resultsCache.has(head.id)) {',
            '                    return job;',
            '                }',
            '            }',
            '        }',
            '        return undefined;',
            '    }',
        ].join('\n'),
    }
];

// ══════════════════════════════════════════════════════════════════════════════
// PATCH 2: ProvingAgent - input prefetch during heartbeats + cache usage
// ══════════════════════════════════════════════════════════════════════════════
const AGENT_PATCHES = [
    // 2a: Initialize prefetch state in constructor
    {
        label: 'agent-init',
        find: [
            '        this.runningPromise = new RunningPromise(this.work.bind(this), this.log, this.pollIntervalMs);',
            '    }',
        ].join('\n'),
        replace: [
            '        this.runningPromise = new RunningPromise(this.work.bind(this), this.log, this.pollIntervalMs);',
            `        // ${M}`,
            '        this._wpOn = process.env.PROVER_WITNESS_PREFETCH === "1";',
            '        this._wpFlight = null;',
            '        this._wpCache = new Map();',
            '    }',
        ].join('\n'),
    },

    // 2b: Peek + prefetch during heartbeat (RUNNING state)
    {
        label: 'agent-heartbeat-prefetch',
        find: [
            '            if (status === ProvingJobControllerStatus.RUNNING) {',
            '                maybeJob = await this.broker.reportProvingJobProgress(jobId, startedAt, {',
            '                    allowList: this.proofAllowList',
            '                });',
        ].join('\n'),
        replace: [
            '            if (status === ProvingJobControllerStatus.RUNNING) {',
            '                maybeJob = await this.broker.reportProvingJobProgress(jobId, startedAt, {',
            '                    allowList: this.proofAllowList',
            '                });',
            `                // ${M}: Speculative input prefetch`,
            '                if (this._wpOn && !maybeJob && !this._wpFlight',
            '                    && typeof this.broker.peekNextProvingJob === "function") {',
            '                    try {',
            '                        const pk = this.broker.peekNextProvingJob({ allowList: this.proofAllowList });',
            '                        if (pk && !this._wpCache.has(pk.id)) {',
            '                            const jid = pk.id, uri = pk.inputsUri;',
            '                            this.log.info(`[prefetch] pre-fetching inputs for job ${jid}`);',
            '                            const p = this.proofStore.getProofInput(uri).then(inputs => {',
            '                                this._wpCache.set(jid, inputs);',
            '                                this.log.info(`[prefetch] inputs ready for job ${jid}`);',
            '                            }).catch(e => {',
            '                                this.log.debug(`[prefetch] failed for job ${jid}: ${e.message}`);',
            '                            }).finally(() => { this._wpFlight = null; });',
            '                            this._wpFlight = { jobId: jid, promise: p };',
            '                        }',
            '                    } catch (_) { /* best-effort */ }',
            '                }',
        ].join('\n'),
    },

    // 2c: Use prefetched inputs in startJob — replace the whole input-fetching block
    {
        label: 'agent-startjob-cache',
        find: [
            '        let inputs;',
            '        try {',
            '            inputs = await this.proofStore.getProofInput(job.inputsUri);',
            '        } catch  {',
            '            const maybeJob = await this.broker.reportProvingJobError(job.id, \'Failed to load proof inputs\', true, {',
            '                allowList: this.proofAllowList',
            '            });',
            '            if (maybeJob) {',
            '                return this.startJob(maybeJob);',
            '            }',
            '            return;',
            '        }',
        ].join('\n'),
        replace: [
            `        // ${M}: Check prefetch cache first`,
            '        let inputs = this._wpOn ? this._wpCache.get(job.id) : undefined;',
            '        if (inputs) {',
            '            this._wpCache.delete(job.id);',
            '            this.log.info(`[prefetch] cache hit for job ${job.id}`);',
            '        }',
            '        // Clear stale prefetches',
            '        if (this._wpOn) {',
            '            if (this._wpFlight && this._wpFlight.jobId !== job.id) this._wpFlight = null;',
            '            for (const [k] of this._wpCache) { if (k !== job.id) this._wpCache.delete(k); }',
            '        }',
            '        if (!inputs) {',
            '            try {',
            '                inputs = await this.proofStore.getProofInput(job.inputsUri);',
            '            } catch  {',
            '                const maybeJob = await this.broker.reportProvingJobError(job.id, \'Failed to load proof inputs\', true, {',
            '                    allowList: this.proofAllowList',
            '                });',
            '                if (maybeJob) {',
            '                    return this.startJob(maybeJob);',
            '                }',
            '                return;',
            '            }',
            '        }',
        ].join('\n'),
    },
];

// ══════════════════════════════════════════════════════════════════════════════
// Apply
// ══════════════════════════════════════════════════════════════════════════════
console.log(REVERT ? 'Reverting witness prefetch pipeline...' : 'Applying witness prefetch pipeline...');

let ok = true;
ok = patchFile('prover-client/dest/proving_broker/proving_broker.js', BROKER_PATCHES) && ok;
ok = patchFile('prover-client/dest/proving_broker/proving_agent.js', AGENT_PATCHES) && ok;

if (!ok) {
    console.error('\nPatch FAILED. Run with --revert to restore backups.');
    process.exit(1);
}

console.log(REVERT
    ? '\nRevert complete.'
    : '\nPatch applied successfully.\nEnable at runtime: export PROVER_WITNESS_PREFETCH=1');
