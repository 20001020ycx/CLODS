# NOTE: copied verbatim from evaluations/Zookeeper/Zookeeper-1900/private/merge_logs.py
# (itself Zookeeper-1851's tool) so every bug merges into its system's production log the
# same way. HBase daemon logs use the same 'YYYY-MM-DD HH:MM:SS,mmm' leading timestamp as
# the ZooKeeper ones, and production-logs/HBase/production.log is likewise a bundle of
# per-host sections, so --interleave position applies here too. Unmodified below this line.
#!/usr/bin/env python3
"""merge_logs.py — METHODOLOGY.md §5/M3 step 8: merge a reproduction log into the shared,
read-only, GB-scale production log so the result reads as one naturally-occurring
production trace.

    merge_logs.py --production P --repro R --out O [--rename map.json]

Rules implemented (retime, do not rewrite):
  * A **record** = one timestamped line plus any immediately following non-timestamped
    continuation lines (stack frames, blank separators, collection headers). Retiming is
    per record; continuation lines are carried verbatim.
  * Production records are emitted verbatim with their original timestamps.
  * Reproduction records keep every character except their leading timestamp token, which is
    linearly warped from the reproduction span onto the **full** production span:
        t' = T_p0 + (t_r - T_r0)/(T_r1 - T_r0) * (T_p1 - T_p0)
    so the reproduction keeps its relative ordering and gaps but is spread across the whole
    production timeline instead of sitting in one contiguous foreign block. A zero-span
    reproduction is distributed evenly across [T_p0, T_p1].
  * Interleaving (--interleave):
      - `timestamp` is the spec's literal rule and is correct when the production log is one
        globally sorted timeline: 2-way merge by timestamp, production first on ties.
      - `position` (default here) is required when the production log is a **bundle of
        per-host logs** rather than a timeline. The shared ZooKeeper production log is 10
        concatenated per-host sections (zk1..zk7 + rotations), each restarting the clock over
        the same ~47-minute window, so it is not globally sorted. A pure timestamp merge then
        degenerates: every reproduction record is "later" than the head of each new section,
        so the whole reproduction collapses into the FIRST section as one contiguous foreign
        block (measured: 80% of it inside the first 500k of 8.07M lines) - exactly what the
        methodology forbids. `position` keeps the retiming rule above unchanged and only
        changes the interleaving key: record k is placed at production-record index
        f_k * N_production, where f_k is its warped fraction of the reproduction span. The
        reproduction is then spread across all 10 host sections in order, and because every
        section covers the same wall-clock window, each inserted record's warped timestamp
        still lands close to its neighbours' local clock.
  * Nothing is loaded into memory beyond one record at a time.

--rename applies a token map to the **production** stream only (the reproduction stream is
already anonymized when this runs at M4). It exists because the shared production log is
real ZooKeeper output and therefore contains the very class names M4 renames on the failure
path; without it the merged log would contradict `source/` and leak the original names. The
shared production log itself is never modified.
"""
import argparse
import json
import os
import re
import sys
from datetime import date

TS = re.compile(rb"^(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2}):(\d{2}),(\d{3})")
_ORD = {}


def ts_ms(m):
    """Parse a matched timestamp to epoch-ish milliseconds (ordinal-based, no strptime)."""
    y, mo, d = m.group(1), m.group(2), m.group(3)
    key = (y, mo, d)
    o = _ORD.get(key)
    if o is None:
        o = date(int(y), int(mo), int(d)).toordinal()
        _ORD[key] = o
    return ((((o * 24 + int(m.group(4))) * 60 + int(m.group(5))) * 60
             + int(m.group(6))) * 1000 + int(m.group(7)))


def fmt_ms(t):
    """Render epoch-ish ms back into the production log's timestamp format."""
    ms = t % 1000
    t //= 1000
    s = t % 60
    t //= 60
    mi = t % 60
    t //= 60
    h = t % 24
    d = date.fromordinal(t // 24)
    return b"%04d-%02d-%02d %02d:%02d:%02d,%03d" % (d.year, d.month, d.day, h, mi, s, ms)


def records(path):
    """Yield (ts_ms_or_None, [lines], ts_index) records.

    ts_index is where the timestamped line sits inside the record: 0 normally, but >0 for
    the first record of a file that opens with untimestamped header lines (those are kept
    as a prefix so no line is ever dropped or reordered within a record)."""
    with open(path, "rb") as f:
        cur, cur_ts, cur_i, pending = None, None, 0, []
        for line in f:
            m = TS.match(line)
            if m:
                if cur is not None:
                    yield cur_ts, cur, cur_i
                cur_i = len(pending)
                cur = pending + [line]
                pending = []
                cur_ts = ts_ms(m)
            elif cur is None:
                pending.append(line)          # header block before the first timestamp
            else:
                cur.append(line)              # continuation of the current record
        if cur is not None:
            cur[len(cur):] = pending
            yield cur_ts, cur, cur_i
        elif pending:
            yield None, pending, 0


def span(path):
    """(first_ts, last_ts) without reading the whole file: head scan + tail seek."""
    first = last = None
    with open(path, "rb") as f:
        for line in f:
            m = TS.match(line)
            if m:
                first = ts_ms(m)
                break
        size = os.path.getsize(path)
        f.seek(max(0, size - (1 << 20)))
        tail = f.read()
        for line in reversed(tail.split(b"\n")):
            m = TS.match(line)
            if m:
                last = ts_ms(m)
                break
    if first is None or last is None:
        sys.exit(f"no timestamps found in {path}")
    return first, last


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--production", required=True)
    ap.add_argument("--repro", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--span-mode", choices=("full", "natural"), default="full",
                    help="full (spec): warp the reproduction span onto the WHOLE production "
                         "span - preserves relative gaps but scales them (here x42), so the "
                         "reproduction's own timestamps stop agreeing with its message text "
                         "(a '6666ms' client timeout ends up surrounded by minutes of "
                         "apparent silence). natural: keep the reproduction's real duration "
                         "and only SHIFT it to --offset-frac of the production window, so "
                         "elapsed times in the log are physically true; the reproduction is "
                         "still interleaved among production noise, just within the window it "
                         "actually occupied (~2.4% of the file, ~12 production lines per "
                         "reproduction line) rather than smeared over all of it.")
    ap.add_argument("--offset-frac", type=float, default=0.35,
                    help="natural mode: where in the production window the incident starts")
    ap.add_argument("--interleave", choices=("position", "timestamp"), default="position",
                    help="position (default): spread by proportional file position - required "
                         "for a per-host-bundle production log; timestamp: the spec's literal "
                         "2-way merge, correct only for a globally sorted production log")
    ap.add_argument("--rename", default=None,
                    help="JSON {original: replacement} applied to production lines only")
    a = ap.parse_args()

    sub = None
    if a.rename:
        m = json.load(open(a.rename))
        if m:
            pat = re.compile(b"|".join(re.escape(k.encode()) for k in
                                       sorted(m, key=len, reverse=True)))
            tbl = {k.encode(): v.encode() for k, v in m.items()}
            sub = lambda line: pat.sub(lambda x: tbl[x.group(0)], line)  # noqa: E731

    p0, p1 = span(a.production)
    r0, r1 = span(a.repro)
    n_repro = sum(1 for _ in records(a.repro))
    print(f"[merge] production span {fmt_ms(p0).decode()} .. {fmt_ms(p1).decode()}")
    print(f"[merge] repro span      {fmt_ms(r0).decode()} .. {fmt_ms(r1).decode()} "
          f"({n_repro} records)")

    # natural mode: pure shift (no scaling) to --offset-frac of the production window
    shift = p0 + int((p1 - p0) * a.offset_frac) - r0
    lo_frac = a.offset_frac
    hi_frac = a.offset_frac + (r1 - r0) / max(1, p1 - p0)

    def retimed():
        i = 0
        for ts, lines, ti in records(a.repro):
            if ts is None:
                continue
            if a.span_mode == "natural":
                t = ts + shift
            elif r1 > r0:
                t = p0 + (ts - r0) * (p1 - p0) // (r1 - r0)
            else:
                t = p0 + (p1 - p0) * i // max(1, n_repro - 1)
            i += 1
            head = lines[ti]
            lines[ti] = fmt_ms(t) + head[TS.match(head).end():]
            yield t, lines

    np_ = nr = 0
    if a.interleave == "position":
        n_prod = sum(1 for _ in records(a.production))
        print(f"[merge] production records: {n_prod}")
        if a.span_mode == "natural":
            # confine the insertion to the slice of the file matching the incident's real
            # duration, so timestamps stay physically consistent with their neighbourhood
            lo, hi = int(n_prod * lo_frac), int(n_prod * min(1.0, hi_frac))
            step = max(1e-9, (hi - lo) / max(1, n_repro))
            base = lo
        else:
            step, base = n_prod / max(1, n_repro), 0
        print(f"[merge] span-mode={a.span_mode} "
              f"insertion window = records {int(base)}..{int(base + step * n_repro)}")
        rep = retimed()
        with open(a.out, "wb") as out:
            rt, rl = next(rep, (None, None))
            for i, (_, pl, _i) in enumerate(records(a.production)):
                while rl is not None and base + nr * step <= i:
                    out.writelines(rl)
                    nr += 1
                    rt, rl = next(rep, (None, None))
                out.writelines([sub(x) for x in pl] if sub else pl)
                np_ += 1
            while rl is not None:
                out.writelines(rl)
                nr += 1
                rt, rl = next(rep, (None, None))
    else:
        prod = records(a.production)
        rep = retimed()
        with open(a.out, "wb") as out:
            pt, pl, _ = next(prod, (None, None, 0))
            rt, rl = next(rep, (None, None))
            while pl is not None or rl is not None:
                take_p = rl is None or (pl is not None and pt <= rt)   # production wins ties
                if take_p:
                    out.writelines([sub(x) for x in pl] if sub else pl)
                    np_ += 1
                    pt, pl, _ = next(prod, (None, None, 0))
                else:
                    out.writelines(rl)
                    nr += 1
                    rt, rl = next(rep, (None, None))
    print(f"[merge] wrote {a.out}: {np_} production + {nr} reproduction records "
          f"(interleave={a.interleave})")


if __name__ == "__main__":
    main()
