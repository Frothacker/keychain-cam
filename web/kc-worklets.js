// Small AudioWorklet processors for Keychain Cam.

// Smooth noise gate, same idea as the Mac app: follow the average level over ~20 ms,
// fully open above the threshold, below it turn down by (level/threshold)^2 to a floor,
// opening in ~3 ms and closing over ~150 ms so it never clicks.
class KcGate extends AudioWorkletProcessor {
  static get parameterDescriptors() {
    return [
      { name: 'threshold', defaultValue: -55, minValue: -100, maxValue: 0, automationRate: 'k-rate' }, // dBFS
      { name: 'enabled', defaultValue: 1, minValue: 0, maxValue: 1, automationRate: 'k-rate' },
    ];
  }
  constructor() {
    super();
    const k = ms => Math.exp(-1 / (sampleRate * ms / 1000));
    this.envCoef = k(20); this.openCoef = k(3); this.closeCoef = k(150);
    this.env = 0; this.gate = 1;
  }
  process(inputs, outputs, params) {
    const input = inputs[0], output = outputs[0];
    if (!input || !input[0]) return true;
    const thr = 10 ** (params.threshold[0] / 20), on = params.enabled[0] >= 0.5;
    const x = input[0];
    for (let i = 0; i < x.length; i++) {
      this.env = this.envCoef * this.env + (1 - this.envCoef) * Math.abs(x[i]);
      const r = this.env / thr;
      const target = !on || r >= 1 ? 1 : Math.max(0.06, r * r);
      const c = target > this.gate ? this.openCoef : this.closeCoef;
      this.gate = c * this.gate + (1 - c) * target;
      for (let ch = 0; ch < output.length; ch++) output[ch][i] = (input[ch] || x)[i] * this.gate;
    }
    return true;
  }
}
registerProcessor('kc-gate', KcGate);

// Records raw samples (first channel) and posts them to the page in ~0.1 s chunks.
class KcRecorder extends AudioWorkletProcessor {
  constructor() { super(); this.buf = []; this.n = 0; }
  process(inputs, outputs) {
    const x = inputs[0] && inputs[0][0];
    if (x) {
      this.buf.push(x.slice()); this.n += x.length;
      if (this.n >= sampleRate / 10) {
        const out = new Float32Array(this.n); let o = 0;
        for (const b of this.buf) { out.set(b, o); o += b.length; }
        this.port.postMessage(out, [out.buffer]); this.buf = []; this.n = 0;
      }
    }
    if (outputs[0] && outputs[0][0] && x) outputs[0][0].set(x);
    return true;
  }
}
registerProcessor('kc-recorder', KcRecorder);
