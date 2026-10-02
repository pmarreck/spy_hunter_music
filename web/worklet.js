// AudioWorklet processor: runs the Spy Hunter sound-board core (wasm) on the
// audio thread, rendering each 128-sample quantum and using the audio clock
// for the death-cue and fire timers.
import { instantiateCore } from './core.js';

const VOLUME = 0.65; // same default output level as the CLI

class SpyHunterProcessor extends AudioWorkletProcessor {
	constructor(options) {
		super();
		this.paused = false;
		this.quanta = 0;
		this.reported = false;
		const { wasm } = options.processorOptions;
		try {
			this.core = instantiateCore(new Uint8Array(wasm));
			this.core.loadEmbedded();
			const started = Date.now();
			if (!this.core.boot(sampleRate, 1)) throw new Error('Sound-board boot failed');
			this.bootMs = Date.now() - started;
			this.port.postMessage({ type: 'ready' });
		} catch (error) {
			this.core = null;
			this.port.postMessage({ type: 'error', message: String(error.message || error) });
		}
		this.port.onmessage = (message) => {
			if (this.core) this.report(this.core.event(message.data.event, currentTime));
		};
	}

	report(flags) {
		const paused = (flags & this.core.FLAG.PAUSED) !== 0;
		if (paused !== this.paused) {
			this.paused = paused;
			this.port.postMessage({ type: 'paused', paused });
		}
	}

	process(_inputs, outputs) {
		const out = outputs[0] && outputs[0][0];
		if (!this.core || !out) return true;
		this.report(this.core.tick(currentTime));
		out.set(this.core.render(out.length, sampleRate, VOLUME));
		// Confirm once that the audio thread is really pulling samples.
		if (!this.reported && ++this.quanta >= 375) {
			this.reported = true;
			this.port.postMessage({ type: 'audio', bootMs: this.bootMs });
		}
		return true;
	}
}

registerProcessor('spy-hunter', SpyHunterProcessor);
