// The sound clean-up chain shared by the camera page and the sound lab.
//
//   input → high-pass → boost → denoiser → presence EQ → low-pass → gate → limiter → output
//   (the AI denoisers expect normal speech levels, so they come after the boost)
//
// Every setting can change while sound is playing. The AudioContext must run at 48 kHz
// (RNNoise only works at 48 kHz; GTCRN and Speex resample inside).

import { RnnoiseWorkletNode, GtcrnWorkletNode, SpeexWorkletNode, loadRnnoise, loadGtcrn, loadSpeex } from './noise/index.js';

const here = new URL('.', import.meta.url);
const at = p => new URL(p, here).href;

export const DENOISERS = {
  off: 'Off',
  rnnoise: 'RNNoise (AI, light)',
  gtcrn: 'GTCRN (AI, newer)',
  speex: 'Speex (classic)',
};

export const PRESETS = {
  raw:     { name: 'Raw',          denoiser: 'off',     gainDb: 0,  highpass: 20, lowpass: 16000, presenceDb: 0, gate: false, gateDb: -55, limiter: false },
  boosted: { name: 'Boost only',   denoiser: 'off',     gainDb: 30, highpass: 90, lowpass: 16000, presenceDb: 0, gate: true,  gateDb: -55, limiter: true },
  clean:   { name: 'Clean voice',  denoiser: 'rnnoise', gainDb: 30, highpass: 90, lowpass: 8500,  presenceDb: 3, gate: false, gateDb: -55, limiter: true },
  newer:   { name: 'Clean (GTCRN)', denoiser: 'gtcrn',  gainDb: 30, highpass: 90, lowpass: 8500,  presenceDb: 3, gate: false, gateDb: -55, limiter: true },
};
export const DEFAULT_SETTINGS = PRESETS.clean;

export function savedSettings() {
  try { return { ...DEFAULT_SETTINGS, ...JSON.parse(localStorage.getItem('kc.sound') || '{}') }; }
  catch { return { ...DEFAULT_SETTINGS }; }
}
export function saveSettings(s) { try { localStorage.setItem('kc.sound', JSON.stringify(s)); } catch {} }

// Worklet modules and wasm binaries, loaded once per AudioContext / page.
const wasm = {};
const modules = new WeakMap();
async function ensureModule(ctx, file) {
  let set = modules.get(ctx); if (!set) modules.set(ctx, set = new Map());
  if (!set.has(file)) set.set(file, ctx.audioWorklet.addModule(at(file)));
  return set.get(file);
}
async function makeDenoiser(ctx, kind) {
  if (kind === 'rnnoise') {
    wasm.rnnoise ||= loadRnnoise({ url: at('noise/rnnoise.wasm'), simdUrl: at('noise/rnnoise_simd.wasm') });
    await ensureModule(ctx, 'noise/rnnoise-worklet.js');
    return new RnnoiseWorkletNode(ctx, { maxChannels: 1, wasmBinary: await wasm.rnnoise });
  }
  if (kind === 'gtcrn') {
    wasm.gtcrn ||= loadGtcrn({ url: at('noise/gtcrn.wasm') });
    await ensureModule(ctx, 'noise/gtcrn-worklet.js');
    return new GtcrnWorkletNode(ctx, { maxChannels: 1, wasmBinary: await wasm.gtcrn });
  }
  if (kind === 'speex') {
    wasm.speex ||= loadSpeex({ url: at('noise/speex.wasm') });
    await ensureModule(ctx, 'noise/speex-worklet.js');
    return new SpeexWorkletNode(ctx, { maxChannels: 1, wasmBinary: await wasm.speex });
  }
  return null;
}

export async function loadWorklets(ctx) { await ensureModule(ctx, 'kc-worklets.js'); }

/** Builds the chain. Returns { input, output, set(settings), bypass(on), destroy() }. */
export async function createChain(ctx, settings = DEFAULT_SETTINGS) {
  await loadWorklets(ctx);
  const input = ctx.createGain(), output = ctx.createGain();
  const wet = ctx.createGain(), dry = ctx.createGain(); dry.gain.value = 0;
  // Web Audio gives lowpass/highpass Q in dB: −3.01 dB = Q 0.707 (Butterworth).
  const hp = ctx.createBiquadFilter(); hp.type = 'highpass'; hp.Q.value = -3.01;
  const den = ctx.createGain();                 // where the denoiser plugs in
  const denOut = ctx.createGain();
  const eq = ctx.createBiquadFilter(); eq.type = 'peaking'; eq.frequency.value = 3000; eq.Q.value = 0.9;
  const lp1 = ctx.createBiquadFilter(), lp2 = ctx.createBiquadFilter(); lp1.type = lp2.type = 'lowpass'; lp1.Q.value = -5.33; lp2.Q.value = 2.33; // 4th-order Butterworth (Q 0.541 and 1.307)
  const boost = ctx.createGain();
  const gate = new AudioWorkletNode(ctx, 'kc-gate', { outputChannelCount: [1] });
  const limiter = ctx.createDynamicsCompressor();
  const limOff = ctx.createGain(), limOn = ctx.createGain();

  input.connect(hp); hp.connect(boost); boost.connect(den);
  denOut.connect(eq); eq.connect(lp1); lp1.connect(lp2); lp2.connect(gate);
  gate.connect(limOn); limOn.connect(limiter); limiter.connect(wet);
  gate.connect(limOff); limOff.connect(wet);
  wet.connect(output);
  input.connect(dry); dry.connect(output);

  let current = { ...settings }, denKind = null, denNode = null, building = Promise.resolve();
  const smooth = (param, v) => param.setTargetAtTime(v, ctx.currentTime, 0.02);

  async function useDenoiser(kind) {
    if (kind === denKind) return;
    denKind = kind;
    const node = await makeDenoiser(ctx, kind).catch(e => { console.error('denoiser failed', kind, e); return null; });
    if (denKind !== kind) { node?.destroy?.(); return; }      // changed again meanwhile
    den.disconnect(); denNode?.disconnect(); denNode?.destroy?.();
    denNode = node;
    if (node) { den.connect(node); node.connect(denOut); } else den.connect(denOut);
  }

  function set(s) {
    current = { ...current, ...s };
    const c = current;
    smooth(hp.frequency, c.highpass);
    smooth(eq.gain, c.presenceDb);
    smooth(lp1.frequency, Math.min(c.lowpass, 20000)); smooth(lp2.frequency, Math.min(c.lowpass, 20000));
    smooth(boost.gain, 10 ** (c.gainDb / 20));
    gate.parameters.get('enabled').value = c.gate ? 1 : 0;
    gate.parameters.get('threshold').value = c.gateDb;
    // Limiter: fast, high ratio, just under full scale. Off = straight through.
    limiter.threshold.value = -10; limiter.knee.value = 6; limiter.ratio.value = 20; limiter.attack.value = 0.002; limiter.release.value = 0.15;
    smooth(limOn.gain, c.limiter ? 1 : 0); smooth(limOff.gain, c.limiter ? 0 : 1);
    building = building.then(() => useDenoiser(c.denoiser));
    return building;
  }

  function bypass(on) { smooth(wet.gain, on ? 0 : 1); smooth(dry.gain, on ? 1 : 0); }

  function destroy() { denNode?.destroy?.(); input.disconnect(); output.disconnect(); }

  await set(current);
  return { input, output, set, bypass, destroy, get settings() { return { ...current }; } };
}
