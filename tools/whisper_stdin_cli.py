#!/usr/bin/env python3
"""Stream raw PCM from stdin into whisper.cpp with lightweight energy VAD.

The helper deliberately owns only the stdin topology.  Direct microphone
capture stays with whisper-stream, while this process turns a namespace-backed
s16le stream into newline-delimited partial/final records for speechshim9p.
"""

import argparse
import array
import collections
import json
import math
import os
import shutil
import subprocess
import sys
import tempfile
import wave


def parse_args():
    parser = argparse.ArgumentParser(
        description="InferNode whisper.cpp stdin-PCM streaming adapter"
    )
    parser.add_argument("--model", required=True)
    parser.add_argument("--rate", type=int, default=16000)
    parser.add_argument("--chans", type=int, default=1)
    parser.add_argument("--length", type=int, default=15000,
                        help="maximum utterance length in milliseconds")
    parser.add_argument("--stdin", action="store_true")
    return parser.parse_args()


def whisper_cli():
    explicit = os.environ.get("INFERNODE_WHISPER_CLI", "")
    if explicit:
        return explicit
    found = shutil.which("whisper-cli")
    if found:
        return found
    brew = shutil.which("brew")
    if brew:
        try:
            prefix = subprocess.check_output(
                [brew, "--prefix", "whisper-cpp"], text=True,
                stderr=subprocess.DEVNULL,
            ).strip()
            candidate = os.path.join(prefix, "bin", "whisper-cli")
            if os.access(candidate, os.X_OK):
                return candidate
        except (OSError, subprocess.SubprocessError):
            pass
    return ""


def rms(frame):
    samples = array.array("h")
    samples.frombytes(frame[: len(frame) - (len(frame) % 2)])
    if sys.byteorder != "little":
        samples.byteswap()
    if not samples:
        return 0.0
    return math.sqrt(sum(sample * sample for sample in samples) / len(samples))


def clean_text(text):
    return " ".join(text.replace("\r", " ").replace("\n", " ").split())


def transcribe(binary, model, rate, pcm):
    with tempfile.TemporaryDirectory(prefix="infernode-whisper-") as work:
        audio = os.path.join(work, "utterance.wav")
        output = os.path.join(work, "transcript")
        with wave.open(audio, "wb") as wav:
            wav.setnchannels(1)
            wav.setsampwidth(2)
            wav.setframerate(rate)
            wav.writeframes(pcm)

        command = [
            binary, "--model", model, "--file", audio,
            "--language", "en", "--no-timestamps", "--no-prints",
            "--output-json-full", "--output-file", output,
        ]
        try:
            result = subprocess.run(
                command, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                text=True, timeout=120,
            )
        except (OSError, subprocess.SubprocessError) as exc:
            raise RuntimeError(str(exc)) from exc
        if result.returncode != 0:
            detail = clean_text(result.stderr)[-300:]
            raise RuntimeError(detail or "whisper-cli exited with status %d" % result.returncode)

        try:
            with open(output + ".json", encoding="utf-8") as stream:
                data = json.load(stream)
        except (OSError, ValueError) as exc:
            raise RuntimeError("whisper-cli produced no valid JSON result") from exc

    segments = data.get("transcription", [])
    text = clean_text(" ".join(str(segment.get("text", "")) for segment in segments))
    probabilities = []
    for segment in segments:
        for token in segment.get("tokens", []):
            value = token.get("p")
            if isinstance(value, (int, float)) and value > 0:
                probabilities.append(max(1.0e-6, min(1.0, float(value))))
    confidence = 0.0
    if probabilities:
        confidence = math.exp(sum(math.log(value) for value in probabilities) / len(probabilities))
    return text, confidence


def emit(kind, text, confidence):
    if text:
        print("%s confidence=%.4f %s" % (kind, confidence, text), flush=True)


def main():
    args = parse_args()
    if args.chans != 1:
        print("error: whisper stdin PCM requires one channel", flush=True)
        return 0
    if args.rate < 8000 or args.rate > 48000:
        print("error: whisper stdin PCM rate must be 8000-48000", flush=True)
        return 0
    if not os.path.isfile(args.model):
        print("error: whisper model not found: %s" % args.model, flush=True)
        return 0
    binary = whisper_cli()
    if not binary:
        print("error: whisper-cli binary not found; install whisper-cpp", flush=True)
        return 0

    frame_ms = int(os.environ.get("INFERNODE_STT_FRAME_MS", "20"))
    silence_ms = int(os.environ.get("INFERNODE_STT_SILENCE_MS", "700"))
    partial_ms = int(os.environ.get("INFERNODE_STT_PARTIAL_MS", "1500"))
    threshold = float(os.environ.get("INFERNODE_STT_RMS_THRESHOLD", "350"))
    start_ms = int(os.environ.get("INFERNODE_STT_START_MS", "60"))
    preroll_ms = int(os.environ.get("INFERNODE_STT_PREROLL_MS", "300"))
    frame_bytes = max(2, args.rate * 2 * frame_ms // 1000)
    frame_bytes -= frame_bytes % 2
    start_frames = max(1, start_ms // frame_ms)
    preroll = collections.deque(maxlen=max(1, preroll_ms // frame_ms))

    active = []
    voiced_run = 0
    trailing_silence = 0
    elapsed = 0
    next_partial = partial_ms
    last_partial = ""
    pending = b""

    def recognize(kind):
        nonlocal last_partial
        try:
            text, confidence = transcribe(binary, args.model, args.rate, b"".join(active))
        except RuntimeError as exc:
            print("error: whisper stdin transcription failed: %s" % clean_text(str(exc)), flush=True)
            return
        if kind == "partial":
            if not text or text == last_partial:
                return
            last_partial = text
        emit(kind, text, confidence)

    while True:
        chunk = sys.stdin.buffer.read(frame_bytes - len(pending))
        if not chunk:
            if active:
                recognize("final")
            return 0
        pending += chunk
        if len(pending) < frame_bytes:
            continue
        frame, pending = pending[:frame_bytes], pending[frame_bytes:]
        voiced = rms(frame) >= threshold

        if not active:
            preroll.append(frame)
            voiced_run = voiced_run + 1 if voiced else 0
            if voiced_run < start_frames:
                continue
            active = list(preroll)
            elapsed = len(active) * frame_ms
            trailing_silence = 0
            next_partial = max(partial_ms, elapsed + frame_ms)
            continue

        active.append(frame)
        elapsed += frame_ms
        trailing_silence = 0 if voiced else trailing_silence + frame_ms

        if partial_ms > 0 and elapsed >= next_partial and trailing_silence < silence_ms:
            recognize("partial")
            next_partial += partial_ms

        if trailing_silence >= silence_ms or elapsed >= args.length:
            recognize("final")
            active = []
            preroll.clear()
            voiced_run = 0
            trailing_silence = 0
            elapsed = 0
            last_partial = ""


if __name__ == "__main__":
    raise SystemExit(main())
