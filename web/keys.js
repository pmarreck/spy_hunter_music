// Browser key mapping for the web player: real keydown/keyup events, so
// space is hold-to-fire exactly. Values match SH_EVENT_* in spy_hunter.h.
export const EVENT = Object.freeze({ GUNS_DOWN: 1, GUNS_UP: 2, DEATH: 3, PAUSE: 4 });

// Map a keyboard event ({type, key, repeat, ctrlKey, altKey, metaKey}) to a
// core event number, or null. Autorepeat is ignored; releasing space always
// stops the guns, even with a modifier held. There are no quit keys here.
export function keyEvent(e) {
	if (e.key === ' ' && e.type === 'keyup') return EVENT.GUNS_UP;
	if (e.type !== 'keydown' || e.repeat || e.ctrlKey || e.altKey || e.metaKey) return null;
	if (e.key === ' ') return EVENT.GUNS_DOWN;
	if (e.key === 'd') return EVENT.DEATH;
	if (e.key === 'p' || e.key === 'P') return EVENT.PAUSE;
	return null;
}
