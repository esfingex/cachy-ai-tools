import { pipeline, env } from '@huggingface/transformers';
import path from 'path';
import { fileURLToPath } from 'url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

// 100% offline after initial model download
env.cacheDir = path.join(__dirname, '.cache');
env.allowLocalModels = true;

// Force fully-offline mode when CAVEMEM_OFFLINE=1.
// Useful behind corporate firewalls that intercept HuggingFace TLS once the
// model files are cached. Requires the model to already be in .cache/.
if (process.env.CAVEMEM_OFFLINE === '1') {
  env.allowRemoteModels = false;
}

const MODEL_ID = process.env.CAVEMEM_MODEL || 'Xenova/all-MiniLM-L6-v2';

let extractorInstance = null;
let extractorPromise = null;

export async function getExtractor() {
  if (extractorInstance) return extractorInstance;
  if (extractorPromise) return extractorPromise;

  extractorPromise = (async () => {
    console.log(`[Search Engine] Loading model: ${MODEL_ID}`);
    const ext = await pipeline('feature-extraction', MODEL_ID, {
      progress_callback: (info) => {
        if (info.status === 'downloading' && info.progress) {
          console.log(`[Search Engine] Downloading ${info.file} (${Math.round(info.progress)}%)`);
        }
      }
    });
    extractorInstance = ext;
    console.log('[Search Engine] Model loaded.');
    return ext;
  })();

  return extractorPromise;
}

export async function getEmbedding(text) {
  const extractor = await getExtractor();
  const output = await extractor(text, { pooling: 'mean', normalize: true });
  return Array.from(output.data);
}

export function cosineSimilarity(a, b) {
  if (a.length !== b.length) {
    throw new Error(`Vector dimension mismatch: a (${a.length}) vs b (${b.length})`);
  }
  let dotProduct = 0;
  let normA = 0;
  let normB = 0;
  for (let i = 0; i < a.length; i++) {
    dotProduct += a[i] * b[i];
    normA += a[i] * a[i];
    normB += b[i] * b[i];
  }
  if (normA === 0 || normB === 0) return 0;
  return dotProduct / (Math.sqrt(normA) * Math.sqrt(normB));
}
