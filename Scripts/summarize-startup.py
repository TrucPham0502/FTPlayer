#!/usr/bin/env python3
"""Summarize the SDK opt-in daily startup benchmark without exposing source URLs."""
import argparse
import collections
import csv
import json
import math
from pathlib import Path
import statistics


def read(path):
    return [json.loads(line) for line in Path(path).read_text().splitlines() if line.strip()]


def intervals(row):
    events = row.get("states", [])
    return {event["state"]: max(0, events[i + 1]["uptime"] - event["uptime"])
            for i, event in enumerate(events[:-1])}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("results", type=Path)
    parser.add_argument("--output", type=Path, required=True, help="Output filename prefix")
    parser.add_argument("--repeats", type=Path)
    args = parser.parse_args()
    rows = read(args.results)
    if not rows:
        parser.error("Results must contain at least one recording")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    states = list(dict.fromkeys(e["state"] for r in rows for e in r.get("states", [])))
    fields = ["index", "start", "end", "result", "firstFrameSeconds", "apiDuration",
              "frames", "currentTime", "hardwareFrames", "ffmpegFrames", "vtSoftwareFrames",
              "callbacksMain", "newCacheBeforeOpen", "cacheDirectory"]
    with args.output.with_suffix(".csv").open("w", newline="") as file:
        writer = csv.DictWriter(file, fieldnames=fields + ["longestState", "longestStateSeconds"]
                                + [s + "Seconds" for s in states])
        writer.writeheader()
        for row in rows:
            durations = intervals(row)
            longest = max(durations, key=durations.get) if durations else ""
            item = {f: row.get(f, "") for f in fields}
            item.update(longestState=longest, longestStateSeconds=durations.get(longest, 0))
            item.update({s + "Seconds": durations.get(s, "") for s in states})
            writer.writerow(item)
    times = sorted(r["firstFrameSeconds"] for r in rows if "firstFrameSeconds" in r)
    lines = ["# Daily startup benchmark", "", f"Date: {rows[0].get('date', '')}", "",
             "Result: " + str(dict(collections.Counter(r.get("result") for r in rows))), ""]
    if times:
        lines += [f"First frame: min {min(times):.3f}s, median {statistics.median(times):.3f}s, "
                  f"mean {statistics.mean(times):.3f}s, p95 {times[math.ceil(.95 * len(times)) - 1]:.3f}s, max {max(times):.3f}s.",
                  "", ", ".join(f"≤{limit:g}s: {sum(t <= limit for t in times)}/{len(rows)}" for limit in [.5, 1, 2]), ""]
    lines += ["Fresh FTPlayer/session byte cache per video; sequential in one app process with a shared Metal view. "
              "OS/DNS/server caches are not reset. First frame means the SDK delivered a decoded image to the renderer; "
              "GPU scanout is not timed. Each clip then requires ≥3 output frames and playback time ≥0.15s (or finished). "
              "This checks startup and short playback, not the complete recording.", "",
              "State intervals measure main-queue delegate delivery, including I/O/waits within a state. "
              "They are not pure CPU or decoder execution time. CSV contains every state interval.", "",
              "## Slowest recordings", "",
              "| Index | Start (+07:00) | First frame (s) | Longest state | State interval (s) |",
              "|---:|---|---:|---|---:|"]
    for r in sorted(rows, key=lambda r: r.get("firstFrameSeconds", -1), reverse=True)[:10]:
        d = intervals(r); state = max(d, key=d.get) if d else ""
        lines.append(f"| {r['index']} | {r['start']} | {r.get('firstFrameSeconds', 0):.3f} | {state} | {d.get(state, 0):.3f} |")
    if args.repeats:
        repeat = read(args.repeats)
        lines += ["", "## Fresh-cache repeats of slow recordings", "",
                  "| Original index | Start (+07:00) | Original (s) | Repeat first-frame times (s) |",
                  "|---:|---|---:|---|"]
        for r in rows:
            matches = [v for v in repeat if v["start"] == r["start"]]
            if matches:
                values = ", ".join(f"{v.get('firstFrameSeconds', 0):.3f} ({v['result']})" for v in matches)
                lines.append(f"| {r['index']} | {r['start']} | {r.get('firstFrameSeconds', 0):.3f} | {values} |")
    lines += ["", "## All recordings (newest first)", "",
              "| Index | Start (+07:00) | Duration (s, API) | First frame (s) | Output frames | HW decoded frames | Result |",
              "|---:|---|---:|---:|---:|---:|---|"]
    for r in rows:
        first = f"{r['firstFrameSeconds']:.3f}" if "firstFrameSeconds" in r else "—"
        lines.append(f"| {r['index']} | {r['start']} | {r.get('apiDuration', 0):g} | {first} | {r.get('frames', 0)} | {r.get('hardwareFrames', 0)} | {r['result']} |")
    args.output.with_suffix(".md").write_text("\n".join(lines) + "\n")
    print(f"Wrote {len(rows)} recordings: {args.output.with_suffix('.csv')} and .md")


if __name__ == "__main__":
    main()
