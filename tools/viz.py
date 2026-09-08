#!/usr/bin/env python3
"""Live view of the FPGA order book(s).

Reads the per-message telemetry the -DANIMATE / multitop build streams over the
onboard USB serial:

    I DDDDDDDD CCC T\\n
      I         book index 0..3
      DDDDDDDD  that book's best bid in 1/10000 dollar
      CCC       that book's resting order count
      T         A / D / E

and draws a live chart -- one best-bid line per book. Book names come from
data/tickers.txt (written by `itch_to_hex.py --tickers`); otherwise "book N".

    make feed-multi ITCH=01302019.NASDAQ_ITCH50        # AMD,MSFT,AAPL,NVDA
    make flash-multi                                   # -> SPI flash, replug
    python3 tools/viz.py

matplotlib if it's installed, otherwise a scrolling terminal view.
"""

from __future__ import annotations

import argparse
import collections
import glob
import os
import sys
import time

try:
    import serial
except ImportError:
    sys.exit("need pyserial:  python3 -m pip install pyserial")

COLORS = ["#2f7ed8", "#8bbc21", "#e8710a", "#910000", "#1aadce", "#492970"]


def find_port() -> str:
    ports = sorted(glob.glob("/dev/cu.usbserial-*") + glob.glob("/dev/ttyUSB*"))
    if not ports:
        sys.exit("no /dev/cu.usbserial-* found -- is the board plugged in?")
    return ports[-1]                       # FT2232 ch B (UART) is the higher suffix


def load_names():
    path = os.path.join(os.path.dirname(__file__), "..", "data", "tickers.txt")
    names = {}
    try:
        with open(path) as f:
            for ln in f:
                p = ln.split()
                if len(p) >= 2:
                    names[int(p[0])] = p[1]
    except OSError:
        pass
    return names


def parse(line: bytes):
    """Accept both telemetry line shapes:
         multitop : "I DDDDDDDD CCC T"   -> (book, bid, count, type)
         single   :   "DDDDDDDD CCC T"   -> (0,    bid, count, type)
    """
    p = line.split()
    if len(p) == 3:
        p = [b"0"] + p
    if len(p) != 4 or p[3] not in (b"A", b"D", b"E"):
        return None
    try:
        return int(p[0]), int(p[1]) / 10000.0, int(p[2]), p[3].decode()
    except ValueError:
        return None


# ---------------------------------------------------------------------------
def run_mpl(ser, names, maxlen):
    import matplotlib.pyplot as plt
    from matplotlib.animation import FuncAnimation

    nb = max(names) + 1 if names else 4
    xs = [collections.deque(maxlen=maxlen) for _ in range(nb)]
    ys = [collections.deque(maxlen=maxlen) for _ in range(nb)]
    last_cnt = [0] * nb
    tally = {"A": 0, "D": 0, "E": 0}
    n = [0]
    buf = [b""]

    fig, ax = plt.subplots(figsize=(11, 6))
    fig.canvas.manager.set_window_title("FPGA order books")
    lines = []
    for i in range(nb):
        lbl = names.get(i, f"book {i}")
        (ln,) = ax.plot([], [], drawstyle="steps-post", lw=1.7,
                        color=COLORS[i % len(COLORS)], label=lbl)
        lines.append(ln)
    ax.set_ylabel("best bid ($)")
    ax.set_xlabel("message #")
    ax.grid(alpha=0.3)
    ax.legend(loc="upper left")

    def update(_):
        buf[0] += ser.read(ser.in_waiting or 1)
        while b"\n" in buf[0]:
            raw, buf[0] = buf[0].split(b"\n", 1)
            rec = parse(raw.strip())
            if not rec:
                continue
            bi, bid, cnt, t = rec
            if bi >= nb:
                continue
            n[0] += 1
            tally[t] += 1
            xs[bi].append(n[0]); ys[bi].append(bid); last_cnt[bi] = cnt
        all_x = [v for d in xs for v in d]
        if not all_x:
            return lines
        for i in range(nb):
            lines[i].set_data(xs[i], ys[i])
        ax.set_xlim(min(all_x), max(max(all_x), min(all_x) + 1))
        all_y = [v for d in ys for v in d]
        lo, hi = min(all_y), max(all_y)
        pad = (hi - lo) * 0.05 or 1
        ax.set_ylim(lo - pad, hi + pad)
        parts = [f"{names.get(i, i)} ${ys[i][-1]:,.2f} ({last_cnt[i]})"
                 for i in range(nb) if ys[i]]
        ax.set_title("   ".join(parts) +
                     f"      A {tally['A']}  D {tally['D']}  E {tally['E']}")
        return lines

    FuncAnimation(fig, update, interval=50, blit=False, cache_frame_data=False)
    plt.tight_layout()
    plt.show()


# ---------------------------------------------------------------------------
def run_terminal(ser, names):
    nb = max(names) + 1 if names else 4
    bid = [0.0] * nb
    cnt = [0] * nb
    tally = {"A": 0, "D": 0, "E": 0}
    n = 0
    buf = b""
    print("reading telemetry (Ctrl-C to stop)...\n")
    while True:
        buf += ser.read(ser.in_waiting or 1)
        while b"\n" in buf:
            raw, buf = buf.split(b"\n", 1)
            rec = parse(raw.strip())
            if not rec:
                continue
            bi, b, c, t = rec
            if bi >= nb:
                continue
            n += 1
            tally[t] += 1
            bid[bi] = b
            cnt[bi] = c
            cells = "  ".join(
                f"{names.get(i, f'b{i}')} ${bid[i]:>9,.2f}/{cnt[i]:<3}"
                for i in range(nb)
            )
            sys.stdout.write(f"\r#{n:<6} {cells}  "
                             f"A{tally['A']} D{tally['D']} E{tally['E']} ")
            sys.stdout.flush()
        time.sleep(0.02)


# ---------------------------------------------------------------------------
def main(argv):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", default=None)
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--window", type=int, default=600, help="points shown (mpl)")
    ap.add_argument("--terminal", action="store_true")
    a = ap.parse_args(argv[1:])

    names = load_names()
    port = a.port or find_port()
    print(f"port {port} @ {a.baud}   books: {names or 'unnamed'}")
    try:
        ser = serial.Serial()
        ser.port = port
        ser.baudrate = a.baud
        ser.timeout = 0
        ser.dsrdtr = False
        ser.rtscts = False
        ser.dtr = False        # don't pulse the FT2232 control lines on open
        ser.rts = False
        ser.open()
        ser.dtr = False
        ser.rts = False
    except serial.SerialException as e:
        sys.exit(f"{e}\n(the -DANIMATE build must be in SPI flash: `make flash-multi`, "
                 f"then replug. Close any other program holding the port.)")
    time.sleep(0.3)
    ser.reset_input_buffer()

    if a.terminal:
        run_terminal(ser, names)
        return 0
    try:
        run_mpl(ser, names, a.window)
    except ImportError:
        print("matplotlib not found -- terminal view\n")
        run_terminal(ser, names)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv))
    except KeyboardInterrupt:
        print()
