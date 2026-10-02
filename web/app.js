// Main-thread controller for the personal web player: loads the bundled
// sound ROMs (sound.zip, built locally by ./serve), starts audio, and maps
// buttons and keys to the core's events.
import { keyEvent, EVENT } from './keys.js';

const $ = (id) => document.getElementById(id);
const ui = { play: $('play'), fire: $('fire'), death: $('death'), status: $('status') };
let context = null;
let node = null;
let ready = false;
let paused = false;
let firing = false;

// Add ?DEBUG to the URL for stage-by-stage startup diagnostics.
const debug = new URLSearchParams(location.search).has('DEBUG');

function detail(text) {
	if (debug) status(text);
}

function status(text, error = false) {
	ui.status.textContent = text;
	ui.status.classList.toggle('error', error);
}

async function fetchBytes(path) {
	const response = await fetch(path);
	if (!response.ok) throw new Error(`${path} is missing (HTTP ${response.status})`);
	return response.arrayBuffer();
}

async function start() {
	ui.play.disabled = true;
	status('Booting the original sound boards…');
	try {
		// Create and resume audio synchronously inside the tap/click: iOS Safari
		// only unlocks audio for a context started by the user's gesture.
		// A "playback" session keeps Web Audio audible with the silent switch on.
		if (navigator.audioSession) navigator.audioSession.type = 'playback';
		context = new AudioContext({ sampleRate: 48000, latencyHint: 'interactive' });
		const resumed = context.resume();
		detail('Downloading the sound boards…');
		const [wasm, zip] = await Promise.all([fetchBytes('spy_hunter.wasm'), fetchBytes('sound.zip')]);
		detail('Loading the audio engine…');
		if (!context.audioWorklet) throw new Error('this browser has no AudioWorklet (needs HTTPS or localhost)');
		await context.audioWorklet.addModule('worklet.js');
		detail('Booting the original sound boards…');
		node = new AudioWorkletNode(context, 'spy-hunter', {
			numberOfInputs: 0,
			outputChannelCount: [1],
			processorOptions: { wasm, zip },
		});
		node.onprocessorerror = () => status('The audio engine crashed while starting.', true);
		node.port.onmessage = ({ data }) => {
			if (data.type === 'audio') {
				detail(`Playing (audio ${context.state}, ${context.sampleRate} Hz, boot ${data.bootMs} ms).`);
			} else if (data.type === 'ready') {
				ready = true;
				ui.play.disabled = false;
				ui.fire.disabled = false;
				ui.death.disabled = false;
				ui.play.textContent = 'Pause';
				status('Playing.');
			} else if (data.type === 'paused') {
				paused = data.paused;
				ui.play.textContent = paused ? 'Play' : 'Pause';
				status(paused ? 'Paused.' : 'Playing.');
			} else if (data.type === 'error') {
				status(`${data.message}. Rebuild the page with ./serve.`, true);
			}
		};
		node.connect(context.destination);
		await resumed;
	} catch (error) {
		context = null;
		ui.play.disabled = false;
		status(`Could not start: ${error.message}. Start the page with ./serve.`, true);
	}
}

function send(event) {
	if (!ready) return;
	node.port.postMessage({ event });
	if (event === EVENT.GUNS_DOWN || event === EVENT.GUNS_UP) {
		firing = event === EVENT.GUNS_DOWN && !paused;
		ui.fire.classList.toggle('active', firing);
	}
}

ui.play.addEventListener('click', () => (ready ? send(EVENT.PAUSE) : start()));
ui.death.addEventListener('click', () => send(EVENT.DEATH));
for (const button of [ui.play, ui.fire, ui.death]) button.addEventListener('contextmenu', (e) => e.preventDefault());
ui.fire.addEventListener('pointerdown', (e) => {
	e.preventDefault(); // no long-press selection or callout on touch screens
	ui.fire.setPointerCapture(e.pointerId);
	send(EVENT.GUNS_DOWN);
});
for (const type of ['pointerup', 'pointercancel', 'lostpointercapture']) {
	ui.fire.addEventListener(type, () => firing && send(EVENT.GUNS_UP));
}

for (const type of ['keydown', 'keyup']) {
	window.addEventListener(type, (e) => {
		const event = keyEvent(e);
		if (event === null) return;
		e.preventDefault();
		if (!ready) {
			// P (or the Play button) starts playback; browsers require a user gesture.
			if (event === EVENT.PAUSE && !context) start();
			return;
		}
		send(event);
	});
}
// A release can be lost when the window loses focus; never leave the guns on.
window.addEventListener('blur', () => firing && send(EVENT.GUNS_UP));
