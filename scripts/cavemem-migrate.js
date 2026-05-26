#!/usr/bin/env node
/**
 * cavemem-migrate.js
 * ==================
 * Herramienta de migración y limpieza para las bases de datos de CaveMem.
 *
 * Uso:
 *   node cavemem-migrate.js [--dry-run] [--verbose]
 *
 * Flags:
 *   --dry-run   Muestra las acciones sin ejecutarlas.
 *   --verbose   Muestra el contenido de cada memoria migrada.
 *   --help      Muestra este mensaje.
 *
 * Funciones:
 *   1. Mueve memorias de un proyecto fuente a uno destino vía API REST.
 *   2. Elimina memorias del proyecto fuente tras confirmar la copia.
 *   3. Elimina archivos .db vacíos (0 memorias) de proyectos huérfanos.
 */

import fs from 'fs';
import path from 'path';

// ─── Configuración ───────────────────────────────────────────────────────────

const BASE_URL   = process.env.CAVEMEM_URL  || 'http://127.0.0.1:3000';
const DBS_DIR    = process.env.CAVEMEM_DBS_DIR || path.join(process.env.HOME, '.cavemem', 'dbs');
const DRY_RUN    = process.argv.includes('--dry-run');
const VERBOSE    = process.argv.includes('--verbose');
const HELP       = process.argv.includes('--help');

// ─── Reglas de migración ──────────────────────────────────────────────────────
//
// Cada regla tiene:
//   from    → proyecto fuente
//   to      → proyecto destino
//   filter  → función que recibe una memoria y devuelve true si debe migrar
//             (undefined = migrar todas)
//
const MIGRATION_RULES = [
  {
    description: 'common → solaria: mover reglas específicas de Solaria/ORM/FastAPI',
    from: 'common',
    to: 'solaria',
    filter: (mem) => {
      // Todas las memorias de common.db son reglas de Solaria según análisis
      return true;
    }
  }
];

// ─── Proyectos huérfanos a eliminar (vacíos) ─────────────────────────────────
const ORPHAN_PROJECTS = ['default_project', 'giskard', 'global'];

// ─── Helpers HTTP ─────────────────────────────────────────────────────────────

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

async function apiDelete(endpoint) {
  const res = await fetch(`${BASE_URL}${endpoint}`, { method: 'DELETE' });
  if (!res.ok) throw new Error(`DELETE ${endpoint} → ${res.status}`);
  return res.json();
}

// ─── Lógica principal ─────────────────────────────────────────────────────────

async function getAllMemories(project) {
  const data = await apiGet(`/api/memories?project=${project}&limit=1000`);
  return data.memories || [];
}

async function migrateRule(rule) {
  console.log(`\n📦 ${rule.description}`);
  console.log(`   ${rule.from} → ${rule.to}`);

  const memories = await getAllMemories(rule.from);
  const toMigrate = memories.filter(rule.filter || (() => true));

  console.log(`   Total en '${rule.from}': ${memories.length} | A migrar: ${toMigrate.length}`);

  if (toMigrate.length === 0) {
    console.log('   ✅ Nada que migrar.');
    return { migrated: 0, failed: 0 };
  }

  let migrated = 0, failed = 0;

  for (const mem of toMigrate) {
    if (VERBOSE) {
      console.log(`\n   [ID:${mem.id}] ${mem.content.slice(0, 80)}...`);
    }

    if (DRY_RUN) {
      console.log(`   [DRY-RUN] Movería ID:${mem.id} de '${rule.from}' → '${rule.to}'`);
      migrated++;
      continue;
    }

    try {
      // 1. Copiar al destino
      await apiPost('/api/memories', {
        project: rule.to,
        category: mem.category,
        content: mem.content,
        tags: mem.tags
      });

      // 2. Eliminar del origen
      await apiDelete(`/api/memories/${mem.id}?project=${rule.from}`);

      migrated++;
      process.stdout.write('.');
    } catch (err) {
      failed++;
      console.error(`\n   ❌ Error migrando ID:${mem.id}: ${err.message}`);
    }
  }

  if (!DRY_RUN) process.stdout.write('\n');
  console.log(`   ✅ Migrados: ${migrated} | ❌ Fallidos: ${failed}`);
  return { migrated, failed };
}

async function cleanOrphans() {
  console.log('\n🗑️  Limpiando proyectos huérfanos vacíos...');

  for (const project of ORPHAN_PROJECTS) {
    const dbFile = path.join(DBS_DIR, `${project}.db`);
    const shmFile = `${dbFile}-shm`;
    const walFile = `${dbFile}-wal`;

    if (!fs.existsSync(dbFile)) {
      console.log(`   ⏭️  '${project}' — archivo no encontrado, skip.`);
      continue;
    }

    // Verificar que realmente esté vacío via API
    try {
      const memories = await getAllMemories(project);
      if (memories.length > 0) {
        console.log(`   ⚠️  '${project}' tiene ${memories.length} memorias — NO se elimina.`);
        continue;
      }
    } catch {
      console.log(`   ⚠️  '${project}' — error consultando API, skip por seguridad.`);
      continue;
    }

    if (DRY_RUN) {
      console.log(`   [DRY-RUN] Eliminaría: ${dbFile} (+ -shm, -wal)`);
      continue;
    }

    try {
      for (const f of [dbFile, shmFile, walFile]) {
        if (fs.existsSync(f)) fs.unlinkSync(f);
      }
      console.log(`   ✅ Eliminado: ${project}.db`);
    } catch (err) {
      console.error(`   ❌ Error eliminando ${project}.db: ${err.message}`);
    }
  }
}

async function printSummary() {
  console.log('\n📊 Estado final de proyectos:');
  try {
    const data = await apiGet('/api/projects');
    for (const proj of data.projects) {
      const stats = await apiGet(`/api/status?project=${proj}`);
      const count = stats.stats?.count ?? '?';
      const size  = stats.stats?.sizeBytes ? `${(stats.stats.sizeBytes / 1024).toFixed(1)} KB` : '?';
      console.log(`   ${proj.padEnd(20)} ${String(count).padStart(4)} memorias   ${size}`);
    }
  } catch (err) {
    console.error('   Error obteniendo resumen:', err.message);
  }
}

async function main() {
  if (HELP) {
    console.log(`
cavemem-migrate.js — Reorganizador de bases de datos CaveMem

Uso: node cavemem-migrate.js [--dry-run] [--verbose] [--help]

  --dry-run   Simula todo sin modificar datos
  --verbose   Muestra contenido de cada memoria migrada

Variables de entorno:
  CAVEMEM_URL      URL del servidor (default: http://127.0.0.1:3000)
  CAVEMEM_DBS_DIR  Directorio de archivos .db (default: ~/.cavemem/dbs)
`);
    process.exit(0);
  }

  console.log('╔══════════════════════════════════════════════╗');
  console.log('║       CaveMem Migration Tool                 ║');
  console.log(`║  ${DRY_RUN ? '🔍 MODO DRY-RUN (sin cambios reales)    ' : '🚀 Ejecutando migraciones...              '} ║`);
  console.log('╚══════════════════════════════════════════════╝');

  // Verificar que el servidor esté corriendo
  try {
    await apiGet('/api/health');
    console.log('\n✅ Servidor CaveMem activo en', BASE_URL);
  } catch {
    console.error('\n❌ No se puede conectar al servidor CaveMem en', BASE_URL);
    console.error('   Asegúrate de que el servicio esté corriendo:');
    console.error('   systemctl --user start cavemem-stack');
    process.exit(1);
  }

  // Ejecutar reglas de migración
  let totalMigrated = 0, totalFailed = 0;
  for (const rule of MIGRATION_RULES) {
    const { migrated, failed } = await migrateRule(rule);
    totalMigrated += migrated;
    totalFailed += failed;
  }

  // Limpiar huérfanos
  await cleanOrphans();

  // Resumen
  await printSummary();

  console.log('\n══════════════════════════════════════════════');
  console.log(`Total migradas: ${totalMigrated} | Fallidas: ${totalFailed}`);
  if (DRY_RUN) console.log('ℹ️  Modo DRY-RUN — ningún dato fue modificado.');
  console.log('══════════════════════════════════════════════\n');
}

main().catch(err => {
  console.error('\n💥 Error fatal:', err.message);
  process.exit(1);
});
