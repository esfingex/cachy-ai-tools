import express from 'express';
import cors from 'cors';
import path from 'path';
import { fileURLToPath } from 'url';
import {
  addMemory,
  updateMemory,
  searchMemories,
  getAllMemories,
  getMemoryById,
  countMemories,
  deleteMemory,
  getProjectStats,
  listAllProjects,
  findDuplicates,
  mergeMemories,
  autoDedupAll,
  reembedAll,
  closeAllConnections,
  ALLOWED_CATEGORIES
} from './db.js';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const app = express();
const PORT = parseInt(process.env.PORT, 10) || 3000;
const HOST = process.env.CAVEMEM_HOST || '127.0.0.1';
const DEFAULT_PROJECT = process.env.CAVEMEM_DEFAULT_PROJECT || 'default_project';
const PAGE_SIZE_DEFAULT = parseInt(process.env.CAVEMEM_PAGE_SIZE, 10) || 24;

const corsOrigins = (process.env.CAVEMEM_CORS_ORIGIN || `http://localhost:${PORT},http://127.0.0.1:${PORT}`)
  .split(',').map(s => s.trim()).filter(Boolean);

app.use(cors({
  origin: (origin, cb) => {
    if (!origin) return cb(null, true);
    if (corsOrigins.includes('*') || corsOrigins.includes(origin)) return cb(null, true);
    return cb(new Error(`Origin not allowed: ${origin}`));
  }
}));

app.use(express.json({ limit: '1mb' }));
app.use(express.urlencoded({ extended: true, limit: '1mb' }));

app.set('view engine', 'ejs');
app.set('views', path.join(__dirname, 'views'));
app.use(express.static(path.join(__dirname, 'public')));

app.use((req, res, next) => {
  console.log(`[HTTP] ${req.method} ${req.originalUrl}`);
  next();
});

// --- GUI ---
app.get('/', (req, res) => {
  try {
    const projects = listAllProjects();
    const currentProject = req.query.project || (projects.length > 0 ? projects[0] : DEFAULT_PROJECT);
    const page = Math.max(parseInt(req.query.page, 10) || 1, 1);
    const limit = Math.min(parseInt(req.query.limit, 10) || PAGE_SIZE_DEFAULT, 200);
    const offset = (page - 1) * limit;
    const category = req.query.category && ALLOWED_CATEGORIES.includes(req.query.category)
      ? req.query.category : null;

    const memories = getAllMemories(currentProject, { limit, offset, category });
    const total = countMemories(currentProject, { category });
    const stats = getProjectStats(currentProject);

    res.render('index', {
      projects,
      currentProject,
      memories,
      stats,
      pagination: {
        page,
        limit,
        offset,
        total,
        totalPages: Math.max(Math.ceil(total / limit), 1),
        category
      }
    });
  } catch (err) {
    console.error('[HTTP Error] Rendering index dashboard failed:', err);
    res.status(500).send(`Error en el servidor: ${err.message}`);
  }
});

// --- REST API ---
app.get('/api/health', (req, res) => {
  res.json({ success: true, status: 'ok', host: HOST, port: PORT });
});

app.get('/api/categories', (req, res) => {
  res.json({ success: true, categories: ALLOWED_CATEGORIES });
});

app.get('/api/projects', (req, res) => {
  try {
    res.json({ success: true, projects: listAllProjects() });
  } catch (err) {
    res.status(500).json({ success: false, error: err.message });
  }
});

app.get('/api/status', (req, res) => {
  const project = req.query.project || DEFAULT_PROJECT;
  try {
    res.json({ success: true, stats: getProjectStats(project) });
  } catch (err) {
    res.status(500).json({ success: false, error: err.message });
  }
});

app.get('/api/memories', (req, res) => {
  const project = req.query.project || DEFAULT_PROJECT;
  const limit = Math.min(parseInt(req.query.limit, 10) || PAGE_SIZE_DEFAULT, 1000);
  const offset = Math.max(parseInt(req.query.offset, 10) || 0, 0);
  const category = req.query.category && ALLOWED_CATEGORIES.includes(req.query.category)
    ? req.query.category : null;

  try {
    const memories = getAllMemories(project, { limit, offset, category });
    const total = countMemories(project, { category });
    res.json({ success: true, memories, limit, offset, total });
  } catch (err) {
    res.status(500).json({ success: false, error: err.message });
  }
});

app.post('/api/memories', async (req, res) => {
  const { project, category, content, tags } = req.body;

  if (!project || !content) {
    return res.status(400).json({ success: false, error: 'Missing project or content in request body.' });
  }
  if (category && !ALLOWED_CATEGORIES.includes(String(category).toLowerCase())) {
    return res.status(400).json({
      success: false,
      error: `Invalid category. Allowed: ${ALLOWED_CATEGORIES.join(', ')}`
    });
  }

  try {
    const newMemory = await addMemory(project, { category, content, tags });
    res.status(201).json({ success: true, memory: newMemory });
  } catch (err) {
    console.error('[API Error] Adding memory failed:', err);
    res.status(500).json({ success: false, error: err.message });
  }
});

app.put('/api/memories/:id', async (req, res) => {
  const { id } = req.params;
  const { project, category, content, tags } = req.body;

  if (!project) {
    return res.status(400).json({ success: false, error: 'Missing project in request body.' });
  }
  if (category !== undefined && !ALLOWED_CATEGORIES.includes(String(category).toLowerCase())) {
    return res.status(400).json({
      success: false,
      error: `Invalid category. Allowed: ${ALLOWED_CATEGORIES.join(', ')}`
    });
  }

  try {
    const result = await updateMemory(project, parseInt(id, 10), { category, content, tags });
    if (!result.updated) {
      return res.status(404).json({ success: false, error: 'Memory not found' });
    }
    res.json({ success: true, ...result });
  } catch (err) {
    console.error('[API Error] Update failed:', err);
    res.status(500).json({ success: false, error: err.message });
  }
});

app.get('/api/memories/:id', (req, res) => {
  const { id } = req.params;
  const project = req.query.project;
  if (!project) {
    return res.status(400).json({ success: false, error: 'Missing project query parameter.' });
  }
  try {
    const memory = getMemoryById(project, parseInt(id, 10));
    if (!memory) return res.status(404).json({ success: false, error: 'Memory not found' });
    res.json({ success: true, memory });
  } catch (err) {
    res.status(500).json({ success: false, error: err.message });
  }
});

app.get('/api/search', async (req, res) => {
  const { project, q, limit, threshold } = req.query;
  if (!project || !q) {
    return res.status(400).json({ success: false, error: 'Missing required parameters: project and q.' });
  }
  const limitNum = Math.min(parseInt(limit, 10) || 5, 100);
  const thresholdNum = threshold !== undefined ? parseFloat(threshold) : undefined;

  try {
    const results = await searchMemories(project, q, limitNum, thresholdNum);
    res.json(results);
  } catch (err) {
    console.error('[API Error] Search failed:', err);
    res.status(500).json({ success: false, error: err.message });
  }
});

app.delete('/api/memories/:id', (req, res) => {
  const { id } = req.params;
  const project = req.query.project;
  if (!project) {
    return res.status(400).json({ success: false, error: 'Missing project query parameter.' });
  }
  try {
    const result = deleteMemory(project, parseInt(id, 10));
    res.json({ success: true, ...result });
  } catch (err) {
    res.status(500).json({ success: false, error: err.message });
  }
});

// --- Dedup / Merge / Reembed ---

app.get('/api/dedup', (req, res) => {
  const project = req.query.project;
  if (!project) return res.status(400).json({ success: false, error: 'Missing project query parameter.' });

  const threshold = req.query.threshold !== undefined ? parseFloat(req.query.threshold) : undefined;
  const category = req.query.category && ALLOWED_CATEGORIES.includes(req.query.category)
    ? req.query.category : null;

  try {
    const pairs = findDuplicates(project, { threshold, category });
    res.json({ success: true, threshold, count: pairs.length, pairs });
  } catch (err) {
    console.error('[API Error] dedup scan failed:', err);
    res.status(500).json({ success: false, error: err.message });
  }
});

app.post('/api/dedup/merge', (req, res) => {
  const { project, keepId, dropId, appendContent } = req.body;
  if (!project || keepId === undefined || dropId === undefined) {
    return res.status(400).json({ success: false, error: 'Missing project, keepId, or dropId.' });
  }

  try {
    const result = mergeMemories(project, parseInt(keepId, 10), parseInt(dropId, 10), { appendContent: !!appendContent });
    res.json({ success: true, ...result });
  } catch (err) {
    console.error('[API Error] merge failed:', err);
    res.status(400).json({ success: false, error: err.message });
  }
});

app.post('/api/dedup/auto', (req, res) => {
  const { project, threshold, dryRun } = req.body;
  if (!project) return res.status(400).json({ success: false, error: 'Missing project.' });

  try {
    const result = autoDedupAll(project, {
      threshold: threshold !== undefined ? parseFloat(threshold) : undefined,
      dryRun: !!dryRun
    });
    res.json({ success: true, ...result });
  } catch (err) {
    console.error('[API Error] auto-dedup failed:', err);
    res.status(500).json({ success: false, error: err.message });
  }
});

app.post('/api/reembed', async (req, res) => {
  const { project, force } = req.body;
  if (!project) return res.status(400).json({ success: false, error: 'Missing project.' });

  try {
    const result = await reembedAll(project, { force: !!force });
    res.json({ success: true, ...result });
  } catch (err) {
    console.error('[API Error] reembed failed:', err);
    res.status(500).json({ success: false, error: err.message });
  }
});

app.use((err, req, res, next) => {
  console.error('[Unhandled Error]', err);
  res.status(err.status || 500).json({ success: false, error: err.message });
});

const server = app.listen(PORT, HOST, () => {
  console.log(`\n======================================================`);
  console.log(`🚀 CaveMem Server listening on http://${HOST}:${PORT}`);
  console.log(`   Editor-Agnostic AI REST API and Local Visual Panel`);
  console.log(`   Allowed CORS origins: ${corsOrigins.join(', ')}`);
  console.log(`======================================================\n`);
});

function shutdown(signal) {
  console.log(`\n[Shutdown] Received ${signal}, closing...`);
  server.close(() => {
    closeAllConnections();
    process.exit(0);
  });
  setTimeout(() => process.exit(1), 5000).unref();
}
process.on('SIGINT', () => shutdown('SIGINT'));
process.on('SIGTERM', () => shutdown('SIGTERM'));
