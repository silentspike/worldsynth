// IPC bridge — TypeScript side of WebKitGTK UserMessage API (WP-030)
// Framework-agnostic: no Svelte imports, no DOM manipulation.
// Types must stay consistent with Zig structs in src/io/user_message.zig.

// ── Commands (UI → DSP) ────────────────────────────────────────────

export interface ParamCommand {
  cmd: 'set_param' | 'note_on' | 'note_off' | 'preset_load';
  id: number;
  val: number;
}

// ── Queries (DSP → UI) ─────────────────────────────────────────────

export interface MeteringData {
  level: [number, number];     // L/R RMS  (matches Zig level_l, level_r)
  peak: [number, number];      // L/R Peak (matches Zig peak_l, peak_r)
  fft: Float32Array;           // 512 bins (matches Zig fft_bins: [512]f32)
  waveform: Float32Array;      // 512 samples (matches Zig waveform: [512]f32)
  cpu: number;                 // 0.0–1.0 (matches Zig cpu_total: f32)
}

// ── WebKit Window Extension ─────────────────────────────────────────

declare global {
  interface Window {
    webkit?: {
      messageHandlers: {
        synth: {
          postMessage(msg: ParamCommand): void;
        };
      };
    };
  }
}

// ── Custom Event Types ──────────────────────────────────────────────

export interface SynthMeterEvent extends CustomEvent<MeteringData> {
  type: 'synth:meter';
}

// ── SynthBridge ─────────────────────────────────────────────────────

export class SynthBridge {
  private listeners: Array<(data: MeteringData) => void> = [];

  sendParam(id: number, val: number): void {
    this.postMessage({ cmd: 'set_param', id, val });
  }

  sendNoteOn(note: number, velocity: number): void {
    this.postMessage({ cmd: 'note_on', id: note, val: velocity / 127 });
  }

  sendNoteOff(note: number): void {
    this.postMessage({ cmd: 'note_off', id: note, val: 0 });
  }

  onMeteringData(callback: (data: MeteringData) => void): () => void {
    this.listeners.push(callback);
    return () => {
      this.listeners = this.listeners.filter((l) => l !== callback);
    };
  }

  // Called from Zig via WebKitGTK UserMessage callback
  _receiveMetering(data: MeteringData): void {
    for (const listener of this.listeners) {
      listener(data);
    }
    window.dispatchEvent(
      new CustomEvent<MeteringData>('synth:meter', { detail: data }),
    );
  }

  private postMessage(msg: ParamCommand): void {
    if (window.webkit?.messageHandlers?.synth) {
      window.webkit.messageHandlers.synth.postMessage(msg);
    }
  }
}

export const bridge = new SynthBridge();
