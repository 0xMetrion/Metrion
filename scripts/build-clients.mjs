import { build } from 'esbuild';
import { mkdir } from 'node:fs/promises';
await mkdir('dist/agents', { recursive: true });
for (const name of ['service-worker', 'service-client', 'contribution-worker']) {
  await build({ entryPoints: [`scripts/${name}.mjs`], outfile: `dist/agents/${name}.mjs`,
    bundle: true, platform: 'node', format: 'esm', target: 'node22', packages: 'external', legalComments: 'eof' });
}
console.log('Public agent clients built.');
