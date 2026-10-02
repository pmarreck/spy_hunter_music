// Classifier test over the full set of relevant keys (and decoys), not
// single examples: every (type, key, repeat, modifier) combination.
import { keyEvent, EVENT } from '../../web/keys.js';

const keys = [' ', 'd', 'D', 'p', 'P', 'q', 'Q', 'Escape', 'Enter', 'x', 'Spacebar'];
const failures = [];
function expected(e) {
	if (e.type === 'keyup' && e.key === ' ') return EVENT.GUNS_UP; // a release must never be ignored
	if (e.ctrlKey || e.altKey || e.metaKey) return null;
	if (e.key === ' ') return e.type === 'keydown' ? (e.repeat ? null : EVENT.GUNS_DOWN) : EVENT.GUNS_UP;
	if (e.type !== 'keydown' || e.repeat) return null;
	if (e.key === 'd') return EVENT.DEATH;
	if (e.key === 'p' || e.key === 'P') return EVENT.PAUSE;
	return null;
}
let count = 0;
for (const type of ['keydown', 'keyup'])
	for (const key of keys)
		for (const repeat of [false, true])
			for (const mod of [null, 'ctrlKey', 'altKey', 'metaKey']) {
				const e = { type, key, repeat, ctrlKey: false, altKey: false, metaKey: false };
				if (mod) e[mod] = true;
				count++;
				const got = keyEvent(e), want = expected(e);
				if (got !== want) failures.push(`${JSON.stringify(e)} -> ${got}, want ${want}`);
			}
// The oracle above restates the rules; pin the essential cases literally too.
const literal = [
	[{ type: 'keydown', key: ' ', repeat: false }, EVENT.GUNS_DOWN],
	[{ type: 'keyup', key: ' ', repeat: false }, EVENT.GUNS_UP],
	[{ type: 'keyup', key: ' ', repeat: false, ctrlKey: true }, EVENT.GUNS_UP],
	[{ type: 'keydown', key: 'D', repeat: false }, null], // uppercase D quits only in the CLI
	[{ type: 'keydown', key: 'q', repeat: false }, null],
];
for (const [e, want] of literal) if (keyEvent(e) !== want) failures.push(`literal ${JSON.stringify(e)} -> ${keyEvent(e)}`);
if (failures.length) {
	console.error(`FAIL: ${failures.length} of ${count + literal.length} key cases\n` + failures.slice(0, 10).join('\n'));
	process.exit(1);
}
console.log(`PASS: web key mapping over ${count + literal.length} cases`);
