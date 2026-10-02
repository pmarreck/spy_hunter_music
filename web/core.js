// JavaScript adapter for spy_hunter.wasm (the Zig core's C ABI compiled to
// wasm32-wasi). Synchronous so it can run inside an AudioWorklet. The core
// performs no I/O; the WASI imports are inert stubs.

const REASONS = {
	1: 'Not a readable ZIP archive',
	2: 'Unsupported ZIP feature (ZIP64, encryption or compression method) at',
	3: 'Duplicate ROM member',
	4: 'Missing ROM',
	5: 'Wrong size',
	6: 'ROM SHA-1 mismatch',
	7: 'Corrupt ZIP member',
};
const ADMISSION_BYTES = 72; // wasm32 sh_admission: int, size_t, char[64]

export function instantiateCore(bytes) {
	let memory;
	const view = () => new DataView(memory.buffer);
	const wasi = {
		args_get: () => 0,
		args_sizes_get: (argc, size) => { view().setUint32(argc, 0, true); view().setUint32(size, 0, true); return 0; },
		fd_write: (fd, iovs, count, written) => {
			let total = 0;
			for (let i = 0; i < count; i++) total += view().getUint32(iovs + 8 * i + 4, true);
			view().setUint32(written, total, true);
			return 0;
		},
		fd_seek: () => 70, // ESPIPE
		fd_close: () => 0,
		proc_exit: (code) => { throw new Error(`spy_hunter.wasm exited (${code})`); },
	};
	const instance = new WebAssembly.Instance(new WebAssembly.Module(bytes), { wasi_snapshot_preview1: wasi });
	const x = instance.exports;
	memory = x.memory;

	const copyIn = (data) => {
		const ptr = x.sh_alloc(data.length || 1);
		if (!ptr) throw new Error('wasm allocation failed');
		new Uint8Array(memory.buffer, ptr, data.length).set(data);
		return ptr;
	};
	let renderPtr = 0, renderCap = 0;

	return {
		FLAG: Object.freeze({ QUIT: 1, KITTY: 2, PAUSED: 4 }),
		// Admit a spyhunt.zip (Uint8Array); returns {ok, reason, member}.
		admitZip(zip) {
			const zipPtr = copyIn(zip);
			const result = x.sh_alloc(ADMISSION_BYTES);
			const status = x.sh_admit_zip(zipPtr, zip.length, result);
			const v = view();
			const reason = v.getInt32(result, true);
			const len = v.getUint32(result + 4, true);
			// TextDecoder is unavailable in some AudioWorklet scopes; names are ASCII.
			const member = String.fromCharCode(...new Uint8Array(memory.buffer, result + 8, len));
			x.sh_free(result, ADMISSION_BYTES);
			x.sh_free(zipPtr, zip.length || 1);
			return { ok: status === 0, reason, member };
		},
		describe(admission) {
			if (admission.ok) return 'ROM verified';
			const text = REASONS[admission.reason] || 'ROM admission failed';
			return admission.reason === 1 ? text : `${text}: ${admission.member}`;
		},
		loadImages(music, effects, prom) {
			const ptrs = [music, effects, prom].map(copyIn);
			const status = x.sh_load_images(ptrs[0], music.length, ptrs[1], effects.length, ptrs[2], prom.length);
			[music, effects, prom].forEach((d, i) => x.sh_free(ptrs[i], d.length || 1));
			return status === 0;
		},
		boot: (rate, command = 1) => x.sh_boot(rate, command) === 0,
		// Render `count` samples with output gain; returns a view valid until the next call.
		render(count, rate, volume) {
			if (count > renderCap) {
				if (renderPtr) x.sh_free(renderPtr, renderCap * 4);
				renderPtr = x.sh_alloc(count * 4);
				renderCap = count;
			}
			if (x.sh_render(renderPtr, count, rate) !== 0) throw new Error('render failed');
			x.sh_apply_gain(renderPtr, count, volume);
			return new Float32Array(memory.buffer, renderPtr, count);
		},
		event: (event, now) => x.sh_event(event, now),
		tick: (now) => x.sh_tick(now),
		latch: (n) => x.sh_latch(n),
		// Raw exports for checks that need the C ABI directly.
		exports: x,
	};
}
