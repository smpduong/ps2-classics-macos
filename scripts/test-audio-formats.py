#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Independent audio fixtures and spectral checks; FFmpeg is a test-only dependency."""
import argparse
import array
import hashlib
import json
import math
import os
from pathlib import Path
import subprocess
import tempfile
import wave

ROOT = Path(__file__).resolve().parents[1]


def run(*args, **kwargs):
    result = subprocess.run(list(map(str, args)), capture_output=True, **kwargs)
    if result.returncode:
        raise RuntimeError(f"Command failed: {args}\n{result.stdout.decode()}\n{result.stderr.decode()}")
    return result


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def check_pcm(path):
    with wave.open(str(path), 'rb') as audio:
        assert (audio.getnchannels(), audio.getframerate(), audio.getsampwidth()) == (2, 44100, 2)
        frames = audio.getnframes()
        assert 0.95 <= frames / 44100 <= 1.15, (path, frames)
        samples = array.array('h', audio.readframes(frames))
    checks = []
    for channel, frequency in enumerate((440, 1000)):
        # Ignore codec priming and tail padding. Distinct tones catch channel
        # swaps/downmixes as well as wrong speed, silence, and heavy distortion.
        values = samples[channel::2][4096:-4096]
        peak = max(map(abs, values))
        energy = sum(v*v for v in values) / len(values)
        sine = sum(v * math.sin(2*math.pi*frequency*i/44100) for i, v in enumerate(values)) * 2 / len(values)
        cosine = sum(v * math.cos(2*math.pi*frequency*i/44100) for i, v in enumerate(values)) * 2 / len(values)
        tone_energy = (sine*sine + cosine*cosine) / 2
        purity = tone_energy / energy if energy else 0
        assert 3000 < peak < 16000 and purity > 0.95, (path, channel, peak, purity)
        checks.append({'frequencyHz': frequency, 'peak': peak, 'toneEnergyFraction': purity})
    return {'durationSeconds': frames/44100, 'channels': checks}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--ffmpeg', required=True)
    parser.add_argument('--helper', type=Path, default=ROOT/'dist/ps2-at3')
    parser.add_argument('--report', type=Path, default=ROOT/'test-results/audio-formats.json')
    parser.add_argument('--all-swift-tests', action='store_true', help='Run the full Swift suite with these audio fixtures available.')
    args = parser.parse_args()
    formats = [('pcm24.wav', 'pcm_s24le'), ('float.wav', 'pcm_f32le'), ('pcm.aiff', 'pcm_s24be'),
               ('lossless.flac', 'flac'), ('lossy.mp3', 'libmp3lame'), ('aac.m4a', 'aac'),
               ('lossless.m4a', 'alac'), ('aac.aac', 'aac')]
    report = {'ffmpeg': run(args.ffmpeg, '-version').stdout.decode().splitlines()[0], 'formats': []}
    with tempfile.TemporaryDirectory(prefix='ps2-audio-reference-') as tmp:
        folder = Path(tmp)
        for name, codec in formats:
            run(args.ffmpeg, '-v', 'error', '-f', 'lavfi', '-i',
                'aevalsrc=0.25*sin(2*PI*440*t)|0.25*sin(2*PI*1000*t):s=48000:d=1',
                '-c:a', codec, folder/name)
        (folder/'inputs.json').write_text(json.dumps([n for n, _ in formats]))
        original = {n: digest(folder/n) for n, _ in formats}
        env = dict(os.environ, PS2_TEST_AUDIO_FIXTURES=str(folder), PS2_TEST_AT3_HELPER=str(args.helper.resolve()))
        selection = [] if args.all_swift_tests else ['--filter', 'AudioNormalizerTests.testIndependentFormatFixtures']
        result = run('swift', 'test', *selection, cwd=ROOT, env=env)
        log = result.stdout.decode() + result.stderr.decode()
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.with_suffix('.swift.log').write_text(log)
        assert '0 failures' in log, log
        if not args.all_swift_tests:
            assert 'Test skipped' not in log, log
        for name, _ in formats:
            decoded = folder/(name+'.decoded.wav')
            run(args.ffmpeg, '-v', 'error', '-i', folder/(name+'.at3'), '-c:a', 'pcm_s16le', decoded)
            assert digest(folder/name) == original[name]
            report['formats'].append({'input': name, 'sourceUnchanged': True,
                'normalized': check_pcm(folder/(name+'.normalized.wav')), 'encoded': check_pcm(decoded)})
        # Carry newly converted audio through the real package pipeline and
        # independently compare SND0.AT3 bytes in single- and multi-disc PKGs.
        package_report = folder/'package-report.json'
        run('python3', ROOT/'scripts/test-package-workflow.py', '--sound', folder/'aac.m4a.at3', '--report', package_report)
        packages = json.loads(package_report.read_text())
        assert packages['passed']
        report['packageWorkflow'] = {'passed': True, 'soundBytesCompared': True,
            'cases': [entry['case'] for entry in packages['results']]}
    report['passed'] = True
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, indent=2)+'\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
