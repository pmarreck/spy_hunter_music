// Render through the web build's wasm core exactly as the CLI's WAV path
// does (sh_render + sh_pcm16), writing raw PCM16 to stdout. Used to compare
// the browser's audio with the native render byte for byte.
import { readFileSync } from 'node:fs';
import { instantiateCore } from '../../web/core.js';

const [wasmPath, zipPath, seconds, command] = process.argv.slice(2);
const core = instantiateCore(readFileSync(wasmPath));
const admission = core.admitZip(new Uint8Array(readFileSync(zipPath)));
if (!admission.ok) { console.error(core.describe(admission)); process.exit(1); }
const x = core.exports, rate = 48000, chunk = 4800, volume = 0.65;
if (!core.boot(rate, Number(command))) { console.error('boot failed'); process.exit(1); }
const floats = x.sh_alloc(chunk * 4), pcm = x.sh_alloc(chunk * 2);
const parts = [];
for (let done = 0, total = Math.floor(Number(seconds) * rate); done < total; done += chunk) {
	const n = Math.min(chunk, total - done);
	if (x.sh_render(floats, n, rate) !== 0) { console.error('render failed'); process.exit(1); }
	x.sh_pcm16(floats, n, volume, pcm, 0, 0);
	parts.push(Buffer.from(new Uint8Array(x.memory.buffer, pcm, n * 2)));
}
process.stdout.write(Buffer.concat(parts));
