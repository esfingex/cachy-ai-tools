#!/usr/bin/env node
/**
 * cavemem-seed.js
 * ===============
 * Imports a knowledge seed JSON file into a CaveMem project.
 * Idempotent: skips entries that are already semantically present (cosine > threshold).
 *
 * Usage:
 *   node cavemem-seed.js --file knowledge/common.json [--dry-run] [--verbose] [--threshold 0.92]
 *
 * Flags:
 *   --file <path>       Path to the seed JSON file (required)
 *   --project <name>    Override the project name from the file (optional)
 *   --threshold <n>     Similarity threshold for dedup check (default: 0.90)
 *   --dry-run           Preview without inserting
 *   --verbose           Print each entry being processed
 *   --help              Show this message
 *
 * Seed file format (see knowledge/example-common.json):
 * {
 *   "project": "common",
 *   "seeds": [
 *     { "category": "rule", "tags": ["tag1"], "content": "..." },
 *     ...
 *   ]
 * }
 */

import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const __filename = fileURLToPath(import.meta.url);
const __dirname  = path.dirname(__filename);

// ─── Args ────────────────────────────────────────────────────────────────────

const args = process.argv.slice(2);
const getArg = (flag) => {
  const i = args.indexOf(flag);
  return i !== -1 && args[i + 1] ? args[i + 1] : null;
};
const hasFlag = (flag) => args.includes(flag);

if (hasFlag('--help')) {
  console.log(`
cavemem-seed.js — Seed a CaveMem project from a JSON knowledge file

Usage: node cavemem-seed.js --file <path> [options]

Options:
  --file <path>       Path to seed JSON (required)
  --project <name>    Override project name defined in the file
  --threshold <n>     Dedup similarity threshold (default: 0.90)
  --dry-run           Simulate without inserting
  --verbose           Show each entry
  --help              This help

Seed file format: see knowledge/example-common.json
`);
  process.exit(0);
}

const BASE_URL  = process.env.CAVEMEM_URL || 'http://127.0.0.1:3000';
const FILE_ARG  = getArg('--file');
const PROJ_ARG  = getArg('--project');
const THRESHOLD = parseFloat(getArg('--threshold') || '0.90');
const DRY_RUN   = hasFlag('--dry-run');
const VERBOSE   = hasFlag('--verbose');

if (!FILE_ARG) {
  console.error('❌ --file is required. Run with --help for usage.');
  process.exit(1);
}

// ─── Helpers ─────────────────────────────────────────────────────────────────

async function apiGet(endpoint) {
  const res = await fetch(`${BASE_URL}${endpoint}`);
  if (!res.ok) throw new Error(`GET ${endpoint} → ${res.status}`);
  return res.json();
}

async function apiPost(endpoint, body) {
  const res = await fetch(`${BASE_URL}${endpoint}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body)
  });
  if (!res.ok) {
    const text = await res.text();
    throw new Error(`POST ${endpoint} → ${res.status}: ${text}`);
  }
  return res.json();
}

async function isDuplicate(project, content, threshold) {
  try {
    const q = encodeURIComponent(content.slice(0, 120));
    const results = await apiGet(`/api/search?project=${project}&q=${q}&limit=1&threshold=${threshold}`);
    // results may be array directly
    const hits = Array.isArray(results) ? results : (results.results || []);
    return hits.length > 0 && hits[0].score >= threshold;
  } catch {
    return false; // on error, allow insert
  }
}

// ─── Main ─────────────────────────────────────────────────────────────────────

async function main() {
  // Resolve seed file path relative to repo root (parent of scripts/)
  const repoRoot = path.resolve(__dirname, '..');
  const filePath = path.resolve(repoRoot, FILE_ARG);

  if (!fs.existsSync(filePath)) {
    console.error(`❌ Seed file not found: ${filePath}`);
    process.exit(1);
  }

  let seedData;
  try {
    seedData = JSON.parse(fs.readFileSync(filePath, 'utf8'));
  } catch (e) {
    console.error(`❌ Failed to parse JSON: ${e.message}`);
    process.exit(1);
  }

  const project = PROJ_ARG || seedData.project;
  if (!project) {
    console.error('❌ No project defined. Set "project" in the JSON or pass --project.');
    process.exit(1);
  }

  const seeds = seedData.seeds || [];
  if (seeds.length === 0) {
    console.warn('⚠️  No seeds found in file.');
    process.exit(0);
  }

  console.log('╔══════════════════════════════════════════════╗');
  console.log('║         CaveMem Seed Importer                ║');
  console.log(`║  Project : ${project.padEnd(32)} ║`);
  console.log(`║  Seeds   : ${String(seeds.length).padEnd(32)} ║`);
  console.log(`║  ${DRY_RUN ? '🔍 DRY-RUN mode (no inserts)            ' : '🚀 Inserting...                          '} ║`);
  console.log('╚══════════════════════════════════════════════╝\n');

  // Check server
  try {
    await apiGet('/api/health');
  } catch {
    console.error('❌ Cannot connect to CaveMem at', BASE_URL);
    console.error('   Start it: systemctl --user start cavemem-stack');
    process.exit(1);
  }

  let inserted = 0, skipped = 0, failed = 0;

  for (const seed of seeds) {
    if (!seed.content || seed.content.includes('[your ')) {
      // Skip unfilled example placeholders
      if (VERBOSE) console.log(`   ⏭️  Skipping placeholder: "${seed.content?.slice(0, 60)}..."`);
      skipped++;
      continue;
    }

    if (VERBOSE) {
      console.log(`\n   → [${(seed.category || 'gotcha').toUpperCase()}] ${seed.content.slice(0, 80)}...`);
    }

    if (DRY_RUN) {
      console.log(`   [DRY-RUN] Would insert: "${seed.content.slice(0, 70)}..."`);
      inserted++;
      continue;
    }

    // Dedup check
    const dup = await isDuplicate(project, seed.content, THRESHOLD);
    if (dup) {
      if (VERBOSE) console.log(`   ⏭️  Already exists (similarity ≥ ${THRESHOLD}), skipping.`);
      skipped++;
      continue;
    }

    try {
      await apiPost('/api/memories', {
        project,
        category: seed.category || 'gotcha',
        content: seed.content,
        tags: Array.isArray(seed.tags) ? seed.tags.join(',') : (seed.tags || '')
      });
      inserted++;
      process.stdout.write('.');
    } catch (e) {
      console.error(`\n   ❌ Failed: ${e.message}`);
      failed++;
    }
  }

  if (!DRY_RUN) process.stdout.write('\n');

  // Summary
  const stats = await apiGet(`/api/status?project=${project}`).catch(() => null);
  const total = stats?.stats?.count ?? '?';

  console.log('\n══════════════════════════════════════════════');
  console.log(`✅ Inserted : ${inserted}`);
  console.log(`⏭️  Skipped  : ${skipped} (duplicates or placeholders)`);
  console.log(`❌ Failed   : ${failed}`);
  console.log(`📊 Total in '${project}': ${total} memories`);
  if (DRY_RUN) console.log('ℹ️  Dry-run — no data was modified.');
  console.log('══════════════════════════════════════════════\n');
}

main().catch(err => {
  console.error('\n💥 Fatal error:', err.message);
  process.exit(1);
});
