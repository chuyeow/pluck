#!/usr/bin/env python3
"""Synthesizes Pluck's capture sounds into Resources/Sounds. Stdlib only; deterministic."""
import math
import random
import struct
import wave
from pathlib import Path

RATE = 44100
OUT = Path(__file__).resolve().parent.parent / "Resources" / "Sounds"


def tone(freq, seconds, partials, sweep=None):
    """Sum of decaying sine partials: (ratio, amplitude, decay tau in seconds).
    sweep(t) optionally scales frequency over time for pitch bends."""
    out, phases = [], [0.0] * len(partials)
    for n in range(int(seconds * RATE)):
        t = n / RATE
        f = freq * (sweep(t) if sweep else 1)
        s = 0.0
        for i, (ratio, amp, tau) in enumerate(partials):
            phases[i] += 2 * math.pi * f * ratio / RATE
            s += amp * math.exp(-t / tau) * math.sin(phases[i])
        out.append(s)
    return out


def string(freq, seconds, damping=0.996, seed=1):
    """Karplus-Strong plucked string."""
    rng = random.Random(seed)
    buf = [rng.uniform(-1, 1) for _ in range(int(RATE / freq))]
    out = []
    for n in range(int(seconds * RATE)):
        i = n % len(buf)
        out.append(buf[i])
        buf[i] = damping * 0.5 * (buf[i] + buf[(i + 1) % len(buf)])
    return out


def mix(length_s, *parts):
    """parts: (start seconds, gain, samples)."""
    out = [0.0] * int(length_s * RATE)
    for start, gain, samples in parts:
        offset = int(start * RATE)
        for i, s in enumerate(samples[: len(out) - offset]):
            out[offset + i] += gain * s
    return out


def write(name, samples, rms=0.1, peak=0.9):
    # 2 ms fade-in avoids a click; 30 ms fade-out avoids a cut-off tail.
    fade_in, fade_out = int(0.002 * RATE), int(0.03 * RATE)
    for i in range(fade_in):
        samples[i] *= i / fade_in
    for i in range(fade_out):
        samples[-1 - i] *= i / fade_out
    # Match loudness (RMS) across sounds; cap the peak so none clips.
    current = math.sqrt(sum(s * s for s in samples) / len(samples))
    scale = min(rms / current, peak / max(abs(s) for s in samples))
    with wave.open(str(OUT / f"{name}.wav"), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(b"".join(struct.pack("<h", int(s * scale * 32767)) for s in samples))


SOUNDS = {
    # Plucked string with a fifth above, like a koto.
    "Koto": lambda: mix(0.9, (0, 1, string(659.3, 0.9)), (0.045, 0.55, string(987.8, 0.85, seed=2))),
    # Metal tine: strong fundamental, short inharmonic overtone. Two notes rising.
    "Kalimba": lambda: mix(0.7, *[
        (start, 1, tone(f, 0.6, [(1, 1, 0.18), (5.4, 0.25, 0.02), (2.0, 0.08, 0.05)]))
        for start, f in [(0, 1046.5), (0.07, 1568.0)]
    ]),
    # Rising sine blip, like a drop hitting water.
    "Droplet": lambda: mix(0.3, (0, 1, tone(520, 0.25, [(1, 1, 0.035)], sweep=lambda t: 1 + 1.6 * (1 - math.exp(-t / 0.02))))),
    # Hollow wooden knock.
    "Woodblock": lambda: mix(0.2, (0, 1, tone(820, 0.2, [(1, 1, 0.03), (2.72, 0.5, 0.012), (4.1, 0.2, 0.006)]))),
    # Struck glass: slowly beating bell partials.
    "Chime": lambda: mix(1.1, (0, 1, tone(1318.5, 1.1, [(1, 1, 0.45), (2.32, 0.4, 0.2), (4.25, 0.2, 0.08), (1.003, 0.6, 0.45)]))),
    # Soft low marimba bloop that dips in pitch.
    "Seed": lambda: mix(0.4, (0, 1, tone(523.3, 0.4, [(1, 1, 0.09), (4.0, 0.15, 0.02)], sweep=lambda t: 1 - 0.06 * min(t / 0.1, 1)))),
}

if __name__ == "__main__":
    OUT.mkdir(parents=True, exist_ok=True)
    for name, make in SOUNDS.items():
        write(name, make())
        print(f"wrote {OUT / name}.wav")
