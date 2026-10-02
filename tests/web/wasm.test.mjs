// Drives the same spy_hunter.wasm the page loads, through web/core.js, with
// synthetic (non-ROM) board images: admission errors, render, guns, pause.
import { readFileSync } from 'node:fs';
import { instantiateCore } from '../../web/core.js';
import { EVENT } from '../../web/keys.js';

const failures = [];
const check = (ok, what) => { if (!ok) failures.push(what); };
const core = instantiateCore(readFileSync(process.argv[2]));

const loadEmbedded = core.exports.sh_load_embedded;
if (typeof loadEmbedded !== 'function') {
	check(false, 'wasm exports sh_load_embedded');
} else {
	const loaded = loadEmbedded();
	check(loaded === 0, `embedded sound image loads (${loaded})`);
	check(core.boot(48000, 1), 'embedded sound image boots');
	const played = core.render(24000, 48000, 0.65);
	let audible = false;
	for (const sample of played) if (sample !== 0) { audible = true; break; }
	check(audible, 'embedded sound image renders audio');
}

const bad = core.admitZip(new TextEncoder().encode('not a ZIP'));
check(!bad.ok && bad.reason === 1 && bad.member === 'csd_u7a.u7', `malformed ZIP rejected: ${JSON.stringify(bad)}`);
check(core.describe(bad).includes('Not a readable ZIP'), `admission message: ${core.describe(bad)}`);

const music = new Uint8Array(32768);
music.set([0, 1, 0xcf, 0xfc, 0, 0, 0, 8, 0x60, 0xfe]); // vectors + BRA.S *
check(core.loadImages(music, new Uint8Array(8192), new Uint8Array(32)), 'synthetic images load');
const out = core.render(128, 48000, 0.65);
check(out instanceof Float32Array && out.length === 128, 'render returns 128 samples');

core.event(EVENT.GUNS_DOWN, 1);
check(core.latch(1) === 0x22 && core.latch(0) === 128, `guns start on latch 1: ${core.latch(1)}`);
core.event(EVENT.GUNS_UP, 2);
check(core.latch(1) === 0x23, 'guns stop on release');
check((core.event(EVENT.PAUSE, 3) & core.FLAG.PAUSED) !== 0, 'pause flag set');
const silent = core.render(128, 48000, 0.65);
check(silent.every((s) => s === 0), 'paused render is silent');
check((core.event(EVENT.PAUSE, 4) & core.FLAG.PAUSED) === 0, 'pause flag cleared');

if (failures.length) { console.error('FAIL: ' + failures.join('\nFAIL: ')); process.exit(1); }
console.log('PASS: wasm core through web/core.js (admission, render, guns, pause)');
