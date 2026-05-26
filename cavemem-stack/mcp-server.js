#!/usr/bin/env node
// ==============================================================================
//   cavemem-stack/mcp-server.js
//   Purpose: MCP JSON-RPC stdio adapter for the CaveMem v2 REST API.
//   The IDE launches this process; it speaks MCP protocol over stdin/stdout
//   and translates calls into HTTP requests to the local Express server.
//   Provides backwards compatibility with the legacy cavemem toolset.
// ==============================================================================

import { createInterface } from 'readline';
import { spawn } from 'child_process';
import path from 'path';
import { fileURLToPath } from 'url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const SERVER_URL = process.env.CAVEMEM_SERVER_URL || 'http://127.0.0.1:3000';
const DEFAULT_PROJECT = process.env.CAVEMEM_PROJECT || 'default_project';

// Derive project from CWD if possible
function detectProject() {
  const cwd = process.env.CAVEMEM_CWD || process.cwd();
  const base = path.basename(cwd).toLowerCase().replace(/[^a-z0-9_-]/g, '_');
  return base || DEFAULT_PROJECT;
}

const PROJECT = detectProject();

// ---------- HTTP helpers ----------

async function apiGet(urlPath) {
  const resp = await fetch(`${SERVER_URL}${urlPath}`);
  return resp.json();
}

async function apiPost(urlPath, body) {
  const resp = await fetch(`${SERVER_URL}${urlPath}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body)
  });
  return resp.json();
}

async function ensureServer() {
  try {
    await fetch(`${SERVER_URL}/api/health`, { signal: AbortSignal.timeout(2000) });
    return true;
  } catch {
    // Try to start the server
    const serverPath = path.join(__dirname, 'server.js');
    const child = spawn('node', [serverPath], {
      cwd: __dirname,
      detached: true,
      stdio: 'ignore'
    });
    child.unref();

    // Wait up to 15s for startup
    for (let i = 0; i < 30; i++) {
      await new Promise(r => setTimeout(r, 500));
      try {
        await fetch(`${SERVER_URL}/api/health`, { signal: AbortSignal.timeout(1000) });
        return true;
      } catch { /* keep waiting */ }
    }
    return false;
  }
}

// ---------- MCP Tool Definitions ----------

const TOOLS = [
  {
    name: 'search',
    description: 'Search memory. Returns compact hits — fetch full bodies via get_observations.',
    inputSchema: {
      type: 'object',
      properties: {
        query: { type: 'string', description: 'Semantic search query', minLength: 1 },
        limit: { type: 'integer', description: 'Max results (default 5)', minimum: 1, maximum: 50 },
        project: { type: 'string', description: `Project name (default: ${PROJECT})` }
      },
      required: ['query']
    }
  },
  {
    name: 'get_observations',
    description: 'Fetch full observation bodies by ID. Returns expanded text by default.',
    inputSchema: {
      type: 'object',
      properties: {
        ids: {
          type: 'array',
          items: { type: 'integer', minimum: 1 },
          minItems: 1,
          maxItems: 50,
          description: 'Array of memory IDs to fetch'
        },
        expand: { type: 'boolean', description: 'Expand content' },
        project: { type: 'string', description: `Project name (default: ${PROJECT})` }
      },
      required: ['ids']
    }
  },
  {
    name: 'list_sessions',
    description: 'List recent sessions in reverse chronological order. Use to navigate before calling timeline.',
    inputSchema: {
      type: 'object',
      properties: {
        limit: { type: 'integer', description: 'Max items to return', minimum: 1, maximum: 200 },
        project: { type: 'string', description: `Project name (default: ${PROJECT})` }
      }
    }
  },
  {
    name: 'timeline',
    description: 'Chronological observation IDs for a session. Use to locate context around a point.',
    inputSchema: {
      type: 'object',
      properties: {
        session_id: { type: 'string', description: 'Session ID', minLength: 1 },
        around_id: { type: 'integer', description: 'Center search around ID' },
        limit: { type: 'integer', description: 'Max items', minimum: 1, maximum: 200 },
        project: { type: 'string', description: `Project name (default: ${PROJECT})` }
      },
      required: ['session_id']
    }
  },
  {
    name: 'add',
    description: 'Store a new memory observation. Categories: gotcha, rule, flow, config, dependency.',
    inputSchema: {
      type: 'object',
      properties: {
        content: { type: 'string', description: 'The memory content to store', minLength: 1 },
        category: { type: 'string', description: 'Category (default: gotcha)', enum: ['gotcha', 'rule', 'flow', 'config', 'dependency'] },
        tags: { type: 'string', description: 'Comma-separated tags' },
        project: { type: 'string', description: `Project name (default: ${PROJECT})` }
      },
      required: ['content']
    }
  },
  {
    name: 'list',
    description: 'List recent memories for the project, optionally filtered by category.',
    inputSchema: {
      type: 'object',
      properties: {
        limit: { type: 'integer', description: 'Max items (default 20)', minimum: 1, maximum: 200 },
        category: { type: 'string', description: 'Filter by category', enum: ['gotcha', 'rule', 'flow', 'config', 'dependency'] },
        project: { type: 'string', description: `Project name (default: ${PROJECT})` }
      }
    }
  },
  {
    name: 'status',
    description: 'Show memory stats for the project: total count, DB size, categories breakdown.',
    inputSchema: {
      type: 'object',
      properties: {
        project: { type: 'string', description: `Project name (default: ${PROJECT})` }
      }
    }
  }
];

// ---------- MCP Tool Handlers ----------

async function handleToolCall(name, args) {
  const project = args?.project || PROJECT;

  switch (name) {
    case 'search': {
      const q = encodeURIComponent(args.query);
      const limit = args.limit || 5;
      const results = await apiGet(`/api/search?project=${project}&q=${q}&limit=${limit}`);
      if (!Array.isArray(results) || results.length === 0) {
        return '[]';
      }
      const mapped = results.map(r => ({
        id: r.id,
        session_id: 'session_default',
        snippet: r.content,
        score: r.score,
        ts: new Date(r.created_at || Date.now()).getTime()
      }));
      return JSON.stringify(mapped);
    }

    case 'get_observations': {
      const ids = args.ids || [];
      const payload = [];
      for (const id of ids) {
        try {
          const res = await apiGet(`/api/memories/${id}?project=${project}`);
          if (res && res.success && res.memory) {
            const m = res.memory;
            payload.push({
              id: m.id,
              session_id: 'session_default',
              kind: m.category || 'gotcha',
              ts: new Date(m.created_at || Date.now()).getTime(),
              content: m.content,
              metadata: { tags: m.tags }
            });
          }
        } catch (err) {
          // ignore or handle missing
        }
      }
      return JSON.stringify(payload);
    }

    case 'list_sessions': {
      const sessions = [{
        id: 'session_default',
        ide: 'antigravity',
        cwd: process.env.CAVEMEM_CWD || process.cwd(),
        started_at: Date.now() - 3600000,
        ended_at: null
      }];
      return JSON.stringify(sessions);
    }

    case 'timeline': {
      const limit = args.limit || 50;
      const res = await apiGet(`/api/memories?project=${project}&limit=${limit}`);
      if (!res.memories?.length) {
        return '[]';
      }
      const mapped = res.memories.map(m => ({
        id: m.id,
        kind: m.category || 'gotcha',
        ts: new Date(m.created_at || Date.now()).getTime()
      }));
      return JSON.stringify(mapped);
    }

    case 'add': {
      const result = await apiPost('/api/memories', {
        project,
        category: args.category || 'gotcha',
        content: args.content,
        tags: args.tags || ''
      });
      if (result.success) {
        return `Memory saved: ID ${result.memory.id} [${result.memory.category}] in project '${project}'`;
      }
      return `Error: ${result.error || 'unknown'}`;
    }

    case 'list': {
      const limit = args?.limit || 20;
      const cat = args?.category ? `&category=${args.category}` : '';
      const result = await apiGet(`/api/memories?project=${project}&limit=${limit}${cat}`);
      if (!result.memories?.length) {
        return `No memories in project '${project}'.`;
      }
      const header = `Project '${project}': ${result.total} total memories\n`;
      const items = result.memories.map(m =>
        `[ID:${m.id}] [${(m.category || '').toUpperCase()}] ${m.content}` +
        (m.tags?.length ? ` (#${m.tags.join(' #')})` : '')
      ).join('\n');
      return header + items;
    }

    case 'status': {
      const result = await apiGet(`/api/status?project=${project}`);
      if (!result.success) return `Error: ${result.error}`;
      const s = result.stats;
      const cats = Object.entries(s.categories || {}).map(([k, v]) => `  ${k}: ${v}`).join('\n');
      return `Project: ${s.projectName}\nTotal: ${s.count} memories\nSize: ${(s.sizeBytes / 1024).toFixed(1)} KB\nCategories:\n${cats || '  (empty)'}`;
    }

    default:
      return `Unknown tool: ${name}`;
  }
}

// ---------- MCP JSON-RPC Protocol ----------

function sendResponse(id, result) {
  const msg = JSON.stringify({ jsonrpc: '2.0', id, result });
  process.stdout.write(msg + '\n');
}

function sendError(id, code, message) {
  const msg = JSON.stringify({ jsonrpc: '2.0', id, error: { code, message } });
  process.stdout.write(msg + '\n');
}

function sendNotification(method, params) {
  const msg = JSON.stringify({ jsonrpc: '2.0', method, params });
  process.stdout.write(msg + '\n');
}

async function handleMessage(line) {
  let msg;
  try {
    msg = JSON.parse(line);
  } catch {
    return; // ignore malformed
  }

  const { id, method, params } = msg;

  switch (method) {
    case 'initialize':
      sendResponse(id, {
        protocolVersion: '2024-11-05',
        capabilities: { tools: { listChanged: false } },
        serverInfo: { name: 'cavemem', version: '2.0.0' }
      });
      break;

    case 'notifications/initialized':
      // Client acknowledged — no response needed
      break;

    case 'tools/list':
      sendResponse(id, { tools: TOOLS });
      break;

    case 'tools/call': {
      const toolName = params?.name;
      const toolArgs = params?.arguments || {};

      try {
        const text = await handleToolCall(toolName, toolArgs);
        sendResponse(id, {
          content: [{ type: 'text', text }]
        });
      } catch (err) {
        sendResponse(id, {
          content: [{ type: 'text', text: `Error: ${err.message}` }],
          isError: true
        });
      }
      break;
    }

    case 'ping':
      sendResponse(id, {});
      break;

    default:
      if (id !== undefined) {
        sendError(id, -32601, `Method not found: ${method}`);
      }
  }
}

// ---------- Main ----------

async function main() {
  // Ensure the Express server is running
  const ok = await ensureServer();
  if (!ok) {
    process.stderr.write('[cavemem-mcp] WARNING: Could not start CaveMem server\n');
  }

  const rl = createInterface({ input: process.stdin, terminal: false });
  rl.on('line', (line) => {
    handleMessage(line.trim()).catch(err => {
      process.stderr.write(`[cavemem-mcp] Error: ${err.message}\n`);
    });
  });

  process.stderr.write(`[cavemem-mcp] MCP server started (project: ${PROJECT})\n`);
}

main();
