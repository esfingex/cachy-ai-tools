import Database from 'better-sqlite3';
import path from 'path';
import fs from 'fs';
import { fileURLToPath } from 'url';
import { getEmbedding, cosineSimilarity } from './search-engine.js';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const DEFAULT_DBS_DIR = path.join(__dirname, 'dbs');
const DBS_DIR = process.env.CAVEMEM_DBS_DIR || DEFAULT_DBS_DIR;
const EMBEDDING_DIM = parseInt(process.env.CAVEMEM_EMBEDDING_DIM, 10) || 384;
const DEFAULT_SCORE_THRESHOLD = parseFloat(process.env.CAVEMEM_SCORE_THRESHOLD || '0.25');
const DEFAULT_DEDUP_THRESHOLD = parseFloat(process.env.CAVEMEM_DEDUP_THRESHOLD || '0.92');

export const ALLOWED_CATEGORIES = ['gotcha', 'rule', 'flow', 'config', 'dependency'];

if (!fs.existsSync(DBS_DIR)) {
  fs.mkdirSync(DBS_DIR, { recursive: true });
}

const dbConnections = new Map();

function cleanProjectName(rawName) {
  if (!rawName) return 'default_project';
  return rawName.toLowerCase().replace(/[^a-z0-9_\-]/g, '_');
}

function normalizeCategory(cat) {
  const c = (cat || '').toLowerCase();
  return ALLOWED_CATEGORIES.includes(c) ? c : 'gotcha';
}

function serializeTags(tags) {
  let arr;
  if (Array.isArray(tags)) arr = tags;
  else if (typeof tags === 'string' && tags.trim()) arr = tags.split(',');
  else arr = [];
  arr = arr.map(t => String(t).trim()).filter(Boolean);
  return JSON.stringify(arr);
}

function parseTags(raw) {
  if (!raw) return [];
  try {
    const v = JSON.parse(raw);
    if (Array.isArray(v)) return v.map(String);
  } catch {
    // legacy CSV fallback
  }
  return String(raw).split(',').map(t => t.trim()).filter(Boolean);
}

export function getDatabase(projectName) {
  const safeName = cleanProjectName(projectName);
  if (dbConnections.has(safeName)) return dbConnections.get(safeName);

  // Each project lives in its own subdirectory: dbs/<project>/<project>.db
  const projectDir = path.join(DBS_DIR, safeName);
  if (!fs.existsSync(projectDir)) {
    fs.mkdirSync(projectDir, { recursive: true });
  }
  const dbPath = path.join(projectDir, `${safeName}.db`);
  const db = new Database(dbPath);
  db.pragma('journal_mode = WAL');
  db.pragma('synchronous = NORMAL');
  db.pragma('foreign_keys = ON');

  db.exec(`
    CREATE TABLE IF NOT EXISTS memories (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      category TEXT NOT NULL,
      content TEXT NOT NULL,
      tags TEXT,
      vector TEXT NOT NULL,
      created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
      updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
    );
    CREATE INDEX IF NOT EXISTS idx_memories_category ON memories(category);
    CREATE INDEX IF NOT EXISTS idx_memories_created_at ON memories(created_at DESC);
    CREATE TRIGGER IF NOT EXISTS trg_memories_updated_at
    AFTER UPDATE ON memories
    FOR EACH ROW
    BEGIN
      UPDATE memories SET updated_at = CURRENT_TIMESTAMP WHERE id = OLD.id;
    END;
  `);

  dbConnections.set(safeName, db);
  return db;
}

export async function addMemory(project, { category, content, tags }) {
  if (!content || typeof content !== 'string') {
    throw new Error('content is required and must be a string');
  }
  const db = getDatabase(project);
  const vector = await getEmbedding(content);
  if (!Array.isArray(vector) || vector.length !== EMBEDDING_DIM) {
    throw new Error(`Invalid embedding dimension: expected ${EMBEDDING_DIM}, got ${vector?.length}`);
  }
  const cat = normalizeCategory(category);
  const tagJson = serializeTags(tags);

  const stmt = db.prepare(`INSERT INTO memories (category, content, tags, vector) VALUES (?, ?, ?, ?)`);
  const info = stmt.run(cat, content, tagJson, JSON.stringify(vector));

  return {
    id: info.lastInsertRowid,
    category: cat,
    content,
    tags: parseTags(tagJson),
    created_at: new Date().toISOString()
  };
}

export async function updateMemory(project, id, { category, content, tags }) {
  const db = getDatabase(project);
  const fields = [];
  const values = [];

  if (category !== undefined) {
    fields.push('category = ?');
    values.push(normalizeCategory(category));
  }
  if (content !== undefined) {
    if (typeof content !== 'string' || !content.trim()) {
      throw new Error('content must be a non-empty string');
    }
    const vector = await getEmbedding(content);
    if (!Array.isArray(vector) || vector.length !== EMBEDDING_DIM) {
      throw new Error(`Invalid embedding dimension: expected ${EMBEDDING_DIM}, got ${vector?.length}`);
    }
    fields.push('content = ?', 'vector = ?');
    values.push(content, JSON.stringify(vector));
  }
  if (tags !== undefined) {
    fields.push('tags = ?');
    values.push(serializeTags(tags));
  }

  if (fields.length === 0) throw new Error('No fields to update');

  values.push(id);
  const info = db.prepare(`UPDATE memories SET ${fields.join(', ')} WHERE id = ?`).run(...values);
  return { updated: info.changes > 0 };
}

export async function searchMemories(project, queryText, limit = 5, threshold = DEFAULT_SCORE_THRESHOLD) {
  const queryVector = await getEmbedding(queryText);

  // Search project DB
  const db = getDatabase(project);
  const rows = db.prepare(`SELECT id, category, content, tags, vector, created_at FROM memories`).all();

  // Search common/global DB (if we're not already searching it)
  const isGlobal = project.toLowerCase() === 'common' || project.toLowerCase() === 'global';
  let globalRows = [];
  if (!isGlobal) {
    try {
      const globalDb = getDatabase('common');
      globalRows = globalDb.prepare(`SELECT id, category, content, tags, vector, created_at FROM memories`).all();
    } catch (e) {
      // Ignore if common DB does not exist or fails
    }
  }

  const scored = [];
  const processRows = (rowList, source) => {
    for (const row of rowList) {
      try {
        const vector = JSON.parse(row.vector);
        if (vector.length !== queryVector.length) continue;
        const score = cosineSimilarity(queryVector, vector);
        scored.push({
          id: row.id,
          category: row.category,
          content: row.content,
          tags: parseTags(row.tags),
          created_at: row.created_at,
          score: Math.round(score * 10000) / 10000,
          source: source
        });
      } catch (e) {
        console.error(`[DB] Error parsing vector for memory ID ${row.id} in ${source}:`, e.message);
      }
    }
  };

  processRows(rows, 'project');
  if (globalRows.length > 0) {
    processRows(globalRows, 'global');
  }

  // Deduplicate by normalized content
  const seenContent = new Set();
  const dedupedScored = [];
  for (const item of scored) {
    const normContent = item.content.trim().toLowerCase();
    if (!seenContent.has(normContent)) {
      seenContent.add(normContent);
      dedupedScored.push(item);
    }
  }

  return dedupedScored
    .filter(item => item.score >= threshold)
    .sort((a, b) => b.score - a.score)
    .slice(0, limit);
}

export function getAllMemories(project, { limit = 200, offset = 0, category = null } = {}) {
  const db = getDatabase(project);
  const where = category ? 'WHERE category = ?' : '';
  const sql = `SELECT id, category, content, tags, created_at, updated_at FROM memories ${where} ORDER BY created_at DESC LIMIT ? OFFSET ?`;
  const rows = category
    ? db.prepare(sql).all(category, limit, offset)
    : db.prepare(sql).all(limit, offset);
  return rows.map(r => ({ ...r, tags: parseTags(r.tags) }));
}

export function getMemoryById(project, id) {
  const db = getDatabase(project);
  const row = db.prepare(`SELECT id, category, content, tags, created_at, updated_at FROM memories WHERE id = ?`).get(id);
  if (!row) return null;
  return { ...row, tags: parseTags(row.tags) };
}

export function countMemories(project, { category = null } = {}) {
  const db = getDatabase(project);
  const where = category ? 'WHERE category = ?' : '';
  const row = category
    ? db.prepare(`SELECT COUNT(*) as count FROM memories ${where}`).get(category)
    : db.prepare(`SELECT COUNT(*) as count FROM memories`).get();
  return row.count;
}

export function deleteMemory(project, id) {
  const db = getDatabase(project);
  const info = db.prepare(`DELETE FROM memories WHERE id = ?`).run(id);
  return { deleted: info.changes > 0 };
}

export function getProjectStats(project) {
  const safeName = cleanProjectName(project);
  const dbPath = path.join(DBS_DIR, safeName, `${safeName}.db`);
  let size = 0;
  if (fs.existsSync(dbPath)) size = fs.statSync(dbPath).size;

  const db = getDatabase(project);
  const countRow = db.prepare(`SELECT COUNT(*) as count FROM memories`).get();
  const catRows = db.prepare(`SELECT category, COUNT(*) as catCount FROM memories GROUP BY category`).all();
  const categories = {};
  for (const r of catRows) categories[r.category] = r.catCount;

  return {
    projectName: safeName,
    count: countRow.count,
    sizeBytes: size,
    categories
  };
}

export function listAllProjects() {
  if (!fs.existsSync(DBS_DIR)) return [];
  // Projects are subdirectories that contain a matching <name>.db inside
  return fs.readdirSync(DBS_DIR, { withFileTypes: true })
    .filter(entry => entry.isDirectory())
    .filter(entry => fs.existsSync(path.join(DBS_DIR, entry.name, `${entry.name}.db`)))
    .map(entry => entry.name)
    .sort();
}

/**
 * Finds near-duplicate memory pairs by cosine similarity.
 * O(n²) pairwise comparison; fine for n < ~10k rows.
 * Returns pairs sorted by score descending.
 */
export function findDuplicates(project, { threshold = DEFAULT_DEDUP_THRESHOLD, category = null } = {}) {
  const db = getDatabase(project);
  const where = category ? 'WHERE category = ?' : '';
  const sql = `SELECT id, category, content, tags, vector, created_at FROM memories ${where} ORDER BY id`;
  const rows = category ? db.prepare(sql).all(category) : db.prepare(sql).all();

  const items = [];
  for (const r of rows) {
    try {
      const vec = JSON.parse(r.vector);
      items.push({ id: r.id, category: r.category, content: r.content, tags: parseTags(r.tags), vec, created_at: r.created_at });
    } catch {
      // skip malformed
    }
  }

  const pairs = [];
  for (let i = 0; i < items.length; i++) {
    for (let j = i + 1; j < items.length; j++) {
      if (items[i].vec.length !== items[j].vec.length) continue;
      const score = cosineSimilarity(items[i].vec, items[j].vec);
      if (score >= threshold) {
        pairs.push({
          score: Math.round(score * 10000) / 10000,
          a: { id: items[i].id, category: items[i].category, content: items[i].content, tags: items[i].tags, created_at: items[i].created_at },
          b: { id: items[j].id, category: items[j].category, content: items[j].content, tags: items[j].tags, created_at: items[j].created_at }
        });
      }
    }
  }

  return pairs.sort((x, y) => y.score - x.score);
}

/**
 * Merges two memories: appends drop's tags into keep (deduped),
 * optionally concatenates content, then deletes drop. Atomic.
 */
export function mergeMemories(project, keepId, dropId, { appendContent = false, separator = '\n---\n' } = {}) {
  if (keepId === dropId) throw new Error('keepId and dropId must differ');
  const db = getDatabase(project);
  const keep = getMemoryById(project, keepId);
  const drop = getMemoryById(project, dropId);
  if (!keep) throw new Error(`keep id ${keepId} not found`);
  if (!drop) throw new Error(`drop id ${dropId} not found`);

  const mergedTags = Array.from(new Set([...(keep.tags || []), ...(drop.tags || [])]));
  const tagJson = JSON.stringify(mergedTags);

  const tx = db.transaction(() => {
    if (appendContent) {
      const newContent = `${keep.content}${separator}${drop.content}`;
      db.prepare(`UPDATE memories SET tags = ?, content = ? WHERE id = ?`).run(tagJson, newContent, keepId);
    } else {
      db.prepare(`UPDATE memories SET tags = ? WHERE id = ?`).run(tagJson, keepId);
    }
    db.prepare(`DELETE FROM memories WHERE id = ?`).run(dropId);
  });
  tx();

  return { kept: keepId, dropped: dropId, mergedTags };
}

/**
 * Auto-merge ALL duplicate pairs above threshold.
 * Strategy: keep the older (lower id) row; merge tags from younger.
 * Returns an array of merge actions performed.
 */
export function autoDedupAll(project, { threshold = DEFAULT_DEDUP_THRESHOLD, dryRun = false } = {}) {
  const pairs = findDuplicates(project, { threshold });
  const dropped = new Set();
  const actions = [];

  for (const p of pairs) {
    // Skip if either side already merged this run
    if (dropped.has(p.a.id) || dropped.has(p.b.id)) continue;

    // Keep older row (lower id), drop newer
    const keepId = Math.min(p.a.id, p.b.id);
    const dropId = Math.max(p.a.id, p.b.id);

    if (!dryRun) {
      mergeMemories(project, keepId, dropId);
    }
    dropped.add(dropId);
    actions.push({ score: p.score, kept: keepId, dropped: dropId });
  }

  return { dryRun, threshold, pairsFound: pairs.length, merged: actions.length, actions };
}

/**
 * Re-computes embeddings for ALL memories in a project using the CURRENT model.
 * Required after changing CAVEMEM_MODEL. Atomic per-row; failed rows are reported.
 */
export async function reembedAll(project, { force = false } = {}) {
  const db = getDatabase(project);
  const rows = db.prepare(`SELECT id, content FROM memories`).all();
  const update = db.prepare(`UPDATE memories SET vector = ? WHERE id = ?`);

  let updated = 0, failed = 0, detectedDim = null;
  const errors = [];

  for (const row of rows) {
    try {
      const vec = await getEmbedding(row.content);
      if (!Array.isArray(vec)) throw new Error('embedding returned non-array');
      if (detectedDim === null) detectedDim = vec.length;
      if (!force && vec.length !== EMBEDDING_DIM) {
        throw new Error(`dim mismatch: got ${vec.length}, expected ${EMBEDDING_DIM}. Set CAVEMEM_EMBEDDING_DIM=${vec.length} or pass force=true`);
      }
      if (vec.length !== detectedDim) {
        throw new Error(`dim inconsistency mid-run: got ${vec.length}, first row was ${detectedDim}`);
      }
      update.run(JSON.stringify(vec), row.id);
      updated++;
    } catch (e) {
      failed++;
      errors.push({ id: row.id, error: e.message });
      if (errors.length >= 5) break; // bail early on systemic failures
    }
  }

  return { total: rows.length, updated, failed, detectedDim, errors };
}

export function closeAllConnections() {
  for (const [name, db] of dbConnections.entries()) {
    try { db.close(); } catch (e) { console.error(`[DB] close ${name}:`, e.message); }
  }
  dbConnections.clear();
}
