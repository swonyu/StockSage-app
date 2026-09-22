#!/usr/bin/env python3
"""Rebuild StockSage's original, softly plucked notification motifs (no samples)."""
import math
from pathlib import Path
import struct
import wave

ROOT = Path(__file__).resolve().parents[1] / 'StockSage/Sources/Resources'
RATE = 44100
MOTIFS = {
    'buy': [(0, 72), (.13, 76), (.26, 79), (.43, 84)],
    'sell': [(0, 79), (.14, 76), (.28, 74), (.45, 72)],
    'price': [(0, 76), (.20, 79), (.40, 76)],
    'research': [(0, 72), (.11, 79), (.23, 76), (.36, 84), (.51, 79)],
}

def render(notes):
    duration = 1.45
    samples = [0.0] * int(RATE * duration)
    for start, midi in notes:
        frequency = 440 * 2 ** ((midi - 69) / 12)
        offset = round(start * RATE)
        for i in range(min(round(.9 * RATE), len(samples) - offset)):
            t = i / RATE
            # Gentle pitch scoop and a soft pluck: playful, no alarm buzz or jackpot loop.
            phase = 2 * math.pi * frequency * (t - .0025 * (1 - math.exp(-t * 35)))
            tone = math.sin(phase) + .22 * math.sin(2 * phase) * math.exp(-t * 7)
            tone += .07 * math.sin(3 * phase) * math.exp(-t * 12)
            envelope = (1 - math.exp(-t * 220)) * math.exp(-t * 6.5)
            tail = min(1, max(0, (.9 - t) / .08))
            samples[offset + i] += tone * envelope * tail
    peak = max(abs(x) for x in samples)
    return [round(x / peak * .30 * 32767) for x in samples]

if __name__ == '__main__':
    ROOT.mkdir(parents=True, exist_ok=True)
    for name, notes in MOTIFS.items():
        data = render(notes)
        with wave.open(str(ROOT / f'stocksage-{name}.wav'), 'wb') as output:
            output.setparams((1, 2, RATE, len(data), 'NONE', 'not compressed'))
            output.writeframes(struct.pack('<' + 'h' * len(data), *data))
        print(f'{name}: {len(data) / RATE:.2f}s, mono PCM16, peak -10.5 dBFS')
