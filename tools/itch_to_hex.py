#!/usr/bin/env python3
"""Turn an ITCH slice into a byte feed for the FPGA.

Two modes:

  --synth
      Emit a deterministic, hand-checked sequence of A/D/E messages (plus one
      unknown type and one sell-side Add) with a known best-bid trajectory.
      No external data needed. This is what the testbenches use.

  <file>
      Read a real NASDAQ ITCH 5.0 file (BinaryFILE framing: each message is
      preceded by a 2-byte big-endian length; .gz is auto-decompressed).
      Resolve the stock locate for --ticker from the 'R' directory messages,
      then emit every A/D/E message for that locate, length-prefix stripped.

Outputs (paths are relative to the current working directory):
  --out-hex   one "%02x" byte per line, for $readmemh   (default data/feed.hex)
  --out-bin   the same bytes, raw                        (default data/feed.bin)
  --out-exp   best_bid after every accepted event + final (default data/expected.txt)
  --out-ev    decoded events "TYPE id price shares", one per line, for tb_book
              (default data/events.txt)

The expected file is produced by tools/reference_book.py so sim and model can
never drift.
"""

from __future__ import annotations

import argparse
import gzip
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from reference_book import MSG_LEN, replay  # noqa: E402


# ---------------------------------------------------------------------------
# message builders (big-endian, offsets exactly per SPEC.md)
# ---------------------------------------------------------------------------
def add_order(ref: int, side: bytes, shares: int, price: int,
              locate: int = 1, ticker: bytes = b"TEST    ") -> bytes:
    assert side in (b"B", b"S")
    m = bytearray(36)
    m[0:1] = b"A"
    struct.pack_into(">H", m, 1, locate)          # stock locate
    struct.pack_into(">H", m, 3, 0)               # tracking number
    m[5:11] = (0).to_bytes(6, "big")              # timestamp
    struct.pack_into(">Q", m, 11, ref)            # order reference number
    m[19:20] = side                               # buy/sell
    struct.pack_into(">I", m, 20, shares)         # shares
    m[24:32] = ticker[:8].ljust(8)                # stock
    struct.pack_into(">I", m, 32, price)          # price
    return bytes(m)


def delete_order(ref: int, locate: int = 1) -> bytes:
    m = bytearray(19)
    m[0:1] = b"D"
    struct.pack_into(">H", m, 1, locate)
    struct.pack_into(">H", m, 3, 0)
    m[5:11] = (0).to_bytes(6, "big")
    struct.pack_into(">Q", m, 11, ref)
    return bytes(m)


def order_executed(ref: int, exec_shares: int, match: int = 0,
                   locate: int = 1) -> bytes:
    m = bytearray(31)
    m[0:1] = b"E"
    struct.pack_into(">H", m, 1, locate)
    struct.pack_into(">H", m, 3, 0)
    m[5:11] = (0).to_bytes(6, "big")
    struct.pack_into(">Q", m, 11, ref)
    struct.pack_into(">I", m, 19, exec_shares)
    struct.pack_into(">Q", m, 23, match)
    return bytes(m)


def system_event(code: bytes = b"O") -> bytes:
    """'S' System Event, 12 bytes. Book must count past and ignore it."""
    m = bytearray(12)
    m[0:1] = b"S"
    struct.pack_into(">H", m, 1, 0)
    struct.pack_into(">H", m, 3, 0)
    m[5:11] = (0).to_bytes(6, "big")
    m[11:12] = code
    return bytes(m)


# ---------------------------------------------------------------------------
# synthetic feed
# ---------------------------------------------------------------------------
def build_synth() -> bytes:
    """Trajectory (dollars are price/10000):

      1  A buy  ref=1      100.2000  x100   -> best 1002000
      2  A buy  ref=2      150.2500  x50    -> best 1502500
      3  A buy  ref=3      130.0000  x200   -> best 1502500
      4  S system event                     -> best 1502500 (skipped)
      5  A SELL ref=4      999.9999  x10     -> best 1502500 (dropped, side S)
      6  E ref=2 exec 50   -> ref2 empties  -> best 1300000 (rescan)
      7  D ref=3           -> ref3 removed   -> best 1002000 (rescan)
      8  E ref=1 exec 40   -> ref1 has 60    -> best 1002000
      9  D ref=1           -> book empty      -> best 0
     10  A buy  ref=5      123.4567  x5      -> best 1234567
     11  A buy  ref=6      123.4567  x8      -> best 1234567 (duplicate best price)
     12  D ref=5           -> ref6 remains   -> best 1234567 (rescan finds the dup)
     13  A buy  ref=7      200.0000  x1      -> best 2000000
     14  E ref=7 exec 1    -> ref7 empties   -> best 1234567 (rescan)
     15  E ref=6 exec 3    -> ref6 has 5      -> best 1234567 (partial fill)
     16  D ref=6           -> book empty      -> best 0
     17  A buy  ref=8      199.9900  x12     -> best 1999900 (empty -> live again)
    """
    parts = [
        add_order(1, b"B", 100, 1002000),
        add_order(2, b"B", 50, 1502500),
        add_order(3, b"B", 200, 1300000),
        system_event(),
        add_order(4, b"S", 10, 9999999),
        order_executed(2, 50),
        delete_order(3),
        order_executed(1, 40),
        delete_order(1),
        add_order(5, b"B", 5, 1234567),
        add_order(6, b"B", 8, 1234567),
        delete_order(5),
        add_order(7, b"B", 1, 2000000),
        order_executed(7, 1),
        order_executed(6, 3),
        delete_order(6),
        add_order(8, b"B", 12, 1999900),
    ]
    return b"".join(parts)


# ---------------------------------------------------------------------------
# real ITCH 5.0 file
# ---------------------------------------------------------------------------
def _open(path: str):
    if path.endswith(".gz"):
        return gzip.open(path, "rb")
    return open(path, "rb")


def build_from_file(path: str, ticker: str, limit: int | None,
                    chunk: int = 1 << 24) -> bytes:
    """Scan a BinaryFILE-framed ITCH 5.0 stream (2-byte BE length prefix).

    Reads the type byte and stock-locate from fixed offsets without copying
    every message -- only messages we actually keep are materialized. Stops as
    soon as `limit` kept messages are reached (for a liquid ticker that is
    early in the file)."""
    want = ticker.encode().ljust(8)[:8]
    A, D, E, R = ord("A"), ord("D"), ord("E"), ord("R")
    keep_types = frozenset((A, D, E))
    target_locate = None
    keep = bytearray()
    kept = 0

    buf = b""
    base = 0            # file offset of buf[0]
    pos = 0
    next_mark = 1 << 30

    with _open(path) as f:
        while True:
            if len(buf) - pos < 2:
                buf = buf[pos:]
                base += pos
                pos = 0
                more = f.read(chunk)
                if not more:
                    break
                buf += more
                continue
            n = (buf[pos] << 8) | buf[pos + 1]
            end = pos + 2 + n
            if end > len(buf):
                buf = buf[pos:]
                base += pos
                pos = 0
                more = f.read(chunk)
                if not more:
                    break
                buf += more
                continue

            t = buf[pos + 2]
            if t == R:
                if n >= 18 and bytes(buf[pos + 13:pos + 21]) == want:
                    target_locate = (buf[pos + 3] << 8) | buf[pos + 4]
            elif target_locate is not None and t in keep_types:
                if ((buf[pos + 3] << 8) | buf[pos + 4]) == target_locate \
                        and n == MSG_LEN[t]:
                    keep += buf[pos + 2:end]
                    kept += 1
                    if (limit is not None and kept >= limit) \
                            or len(keep) > ROM_DEPTH:
                        pos = end
                        break
            pos = end

            if base + pos >= next_mark:
                print(f"  ... scanned {(base + pos) >> 30} GiB, kept {kept}",
                      file=sys.stderr, flush=True)
                next_mark += 1 << 30

    if target_locate is None:
        sys.exit(f"ticker {ticker!r} not found in stock directory messages")
    print(f"ticker {ticker} -> stock_locate {target_locate}, kept {kept} "
          f"A/D/E messages ({len(keep)} bytes)", file=sys.stderr, flush=True)
    return bytes(keep)


# ---------------------------------------------------------------------------
# multi-ticker feed: keep the first `limit` A/D/E per ticker, interleaved in
# file (timestamp) order, and rewrite each message's stock-locate field to the
# book index 0..N-1 so the FPGA routes with a 2-bit select.
# ---------------------------------------------------------------------------
def build_multi(path: str, tickers: list[str], limit: int,
                chunk: int = 1 << 24):
    wants = {t.encode().ljust(8)[:8]: i for i, t in enumerate(tickers)}
    A, D, E, R = ord("A"), ord("D"), ord("E"), ord("R")
    loc2idx: dict[int, int] = {}
    kept = [0] * len(tickers)
    out = bytearray()

    buf = b""; pos = 0
    with _open(path) as f:
        while sum(1 for k in kept if k >= limit) < len(tickers):
            if len(buf) - pos < 2 or (len(buf) - pos - 2) < ((buf[pos] << 8) | buf[pos + 1]):
                buf = buf[pos:]; pos = 0
                more = f.read(chunk)
                if not more:
                    break
                buf += more
                continue
            n = (buf[pos] << 8) | buf[pos + 1]
            msg = buf[pos + 2: pos + 2 + n]
            pos += 2 + n
            t = msg[0]
            if t == R and len(msg) >= 21 and msg[11:19] in wants:
                loc2idx[(msg[1] << 8) | msg[2]] = wants[msg[11:19]]
            elif t in (A, D, E):
                loc = (msg[1] << 8) | msg[2]
                idx = loc2idx.get(loc)
                if idx is not None and kept[idx] < limit and len(msg) == MSG_LEN[t]:
                    m = bytearray(msg)
                    m[1] = 0; m[2] = idx            # locate -> book index
                    out += m
                    kept[idx] += 1

    missing = [tickers[i] for i in range(len(tickers)) if i not in loc2idx.values()]
    if missing:
        sys.exit(f"tickers not found: {missing}")
    print(f"kept per book: {dict(zip(tickers, kept))}, {len(out)} bytes",
          file=sys.stderr)
    return bytes(out)


# ---------------------------------------------------------------------------
TYPE_CODE = {'A': 0x41, 'D': 0x44, 'E': 0x45}
ROM_DEPTH = 32768         # single-ticker: rom.v DEPTH / top.v
MULTI_ROM_DEPTH = 32768   # 4-ticker interleaved feed: multitop.v (32K flash-boots
                          # reliably on the Tang Nano 20K; 64K did not)


def write_outputs(stream: bytes, hex_path: str, bin_path: str, exp_path: str,
                  ev_path: str) -> None:
    for p in (hex_path, bin_path, exp_path, ev_path):
        d = os.path.dirname(p)
        if d:
            os.makedirs(d, exist_ok=True)
    if len(stream) > ROM_DEPTH:
        sys.exit(f"feed is {len(stream)} bytes but ROM_DEPTH is {ROM_DEPTH}; "
                 f"shorten the slice or raise ROM_DEPTH here and rom.v DEPTH")
    with open(bin_path, "wb") as f:
        f.write(stream)
    # pad the $readmemh file to the ROM depth so the simulator does not warn
    # about a short file; the feeder in top.v stops at FEED_BYTES regardless.
    with open(hex_path, "w") as f:
        for b in stream:
            f.write(f"{b:02x}\n")
        for _ in range(ROM_DEPTH - len(stream)):
            f.write("00\n")
    traj, final, events = replay(stream)
    with open(exp_path, "w") as f:
        for k, v in enumerate(traj):
            f.write(f"{k} {v}\n")
        f.write(f"final {final}\n")
    # events.txt: hex type code, then decimal id / price / shares, then the
    # expected best_bid after this event -- tb_book checks the last column.
    with open(ev_path, "w") as f:
        for (t, oid, price, shares), v in zip(events, traj):
            f.write(f"{TYPE_CODE[t]:02x} {oid} {price} {shares} {v}\n")
    # feed.vh: byte count for the ROM feeder in top.v / tb_top.v
    vh_path = os.path.join(os.path.dirname(hex_path) or ".", "feed.vh")
    with open(vh_path, "w") as f:
        f.write("// generated by tools/itch_to_hex.py -- do not edit\n")
        f.write(f"`define FEED_BYTES {len(stream)}\n")
        f.write(f"`define FEED_FINAL_BEST {final}\n")
    print(f"wrote {len(stream)} bytes -> {hex_path}, {bin_path}", file=sys.stderr)
    print(f"{len(traj)} events, final best_bid = {final} -> {exp_path}, {ev_path}",
          file=sys.stderr)


def write_multi_outputs(stream: bytes, tickers: list[str],
                        hex_path: str, bin_path: str) -> None:
    from reference_book import OrderBook, iter_messages
    d = os.path.dirname(hex_path) or "."
    os.makedirs(d, exist_ok=True)
    if len(stream) > MULTI_ROM_DEPTH:
        sys.exit(f"feed is {len(stream)} bytes but MULTI_ROM_DEPTH is "
                 f"{MULTI_ROM_DEPTH}; lower --limit or raise it and multitop.v")

    with open(bin_path, "wb") as f:
        f.write(stream)
    with open(hex_path, "w") as f:
        for b in stream:
            f.write(f"{b:02x}\n")
        for _ in range(MULTI_ROM_DEPTH - len(stream)):
            f.write("00\n")

    # per-book replay for the expected final best bids + a per-event trace
    books = [OrderBook() for _ in tickers]
    trace = []            # (book_idx, best, count, type_char)
    for msg in iter_messages(stream):
        bi = msg[2]
        ev = books[bi].decode(msg)
        if ev is None:
            continue
        books[bi].apply(msg)
        live = sum(1 for s in books[bi].slots if s[0])
        trace.append((bi, books[bi].best_bid, live, ev[0]))
    finals = [b.best_bid for b in books]

    with open(os.path.join(d, "tickers.txt"), "w") as f:
        for i, t in enumerate(tickers):
            f.write(f"{i} {t} {finals[i]}\n")
    with open(os.path.join(d, "trace.txt"), "w") as f:
        for bi, best, cnt, tc in trace:
            f.write(f"{bi} {best} {cnt} {tc}\n")
    with open(os.path.join(d, "feed.vh"), "w") as f:
        f.write("// generated by tools/itch_to_hex.py --tickers -- do not edit\n")
        f.write(f"`define FEED_BYTES {len(stream)}\n")
        f.write(f"`define FEED_NBOOK {len(tickers)}\n")
        for i, (t, v) in enumerate(zip(tickers, finals)):
            f.write(f"`define FEED_FINAL{i} {v}   // {t}\n")
        f.write(f"`define FEED_FINAL_BEST {finals[0]}\n")   # tb_top compat
    print(f"finals: {dict(zip(tickers, finals))}", file=sys.stderr)
    print(f"wrote {len(stream)} bytes, {len(trace)} events -> {hex_path}",
          file=sys.stderr)


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("infile", nargs="?", help="real ITCH 5.0 file (.gz ok)")
    ap.add_argument("--synth", action="store_true", help="emit the built-in feed")
    ap.add_argument("--ticker", default="AAPL", help="ticker to keep (real file mode)")
    ap.add_argument("--tickers", help="comma list, e.g. AMD,MSFT,AAPL,NVDA -- one "
                    "interleaved feed, locate rewritten to book index 0..N-1")
    ap.add_argument("--limit", type=int, default=800,
                    help="max A/D/E messages to keep from a real file "
                         "(must fit ROM_DEPTH=%d bytes; default 800)" % ROM_DEPTH)
    ap.add_argument("--out-hex", default="data/feed.hex")
    ap.add_argument("--out-bin", default="data/feed.bin")
    ap.add_argument("--out-exp", default="data/expected.txt")
    ap.add_argument("--out-ev", default="data/events.txt")
    a = ap.parse_args(argv[1:])

    if a.tickers:
        if not a.infile:
            ap.error("--tickers needs an ITCH file")
        names = [t.strip().upper() for t in a.tickers.split(",") if t.strip()]
        stream = build_multi(a.infile, names, a.limit)
        write_multi_outputs(stream, names, a.out_hex, a.out_bin)
        return 0

    if a.synth:
        stream = build_synth()
    elif a.infile:
        stream = build_from_file(a.infile, a.ticker, a.limit)
    else:
        ap.error("give a file or --synth")

    write_outputs(stream, a.out_hex, a.out_bin, a.out_exp, a.out_ev)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
