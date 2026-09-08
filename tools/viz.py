#!/usr/bin/env python3
"""Live view of the FPGA order book.

Reads the per-message telemetry the -DANIMATE build streams over the onboard
USB serial ("DDDDDDDD CCC T\\n": best bid in 1/10000 dollar, resting order
count, and A/D/E) and draws a live best-bid chart.

    make feed-real ITCH=01302019.NASDAQ_ITCH50 TICKER=MSFT   # pick a stock
    make flash-demo                                          # -> SPI flash, replug
    python3 tools/viz.py

matplotlib if it's installed, otherwise a scrolling terminal view.
"""

from __future__ import annotations

import argparse
import collections
import glob
import sys
import time

try:
    import serial
except ImportError:
    sys.exit("need pyserial:  python3 -m pip install pyserial")


def find_port() -> str:
    ports = sorted(glob.glob("/dev/cu.usbserial-*") + glob.glob("/dev/ttyUSB*"))
    if not ports:
        sys.exit("no /dev/cu.usbserial-* found -- is the board plugged in?")
    # FT2232: channel A is JTAG, channel B (higher suffix) is the UART
    return ports[-1]


def parse(line: bytes):
    try:
        p = line.split()
        if len(p) != 3 or p[2] not in (b"A", b"D", b"E"):
            return None
        return int(p[0]) / 10000.0, int(p[1]), p[2].decode()
    except ValueError:
        return None


# ---------------------------------------------------------------------------
def run_mpl(ser, maxlen):
    import matplotlib
    import matplotlib.pyplot as plt
    from matplotlib.animation import FuncAnimation

    xs = collections.deque(maxlen=maxlen)
    bids = collections.deque(maxlen=maxlen)
    counts = collections.deque(maxlen=maxlen)
    tally = {"A": 0, "D": 0, "E": 0}
    n = [0]

    fig, (ax, ax2) = plt.subplots(2, 1, figsize=(10, 6), height_ratios=[3, 1],
                                  sharex=True)
    fig.canvas.manager.set_window_title("FPGA order book")
    (line_bid,) = ax.plot([], [], drawstyle="steps-post", lw=1.8, color="#2f7ed8")
    (line_cnt,) = ax2.plot([], [], drawstyle="steps-post", lw=1.2, color="#8bbc21")
    ax.set_ylabel("best bid ($)")
    ax2.set_ylabel("orders")
    ax2.set_xlabel("message #")
    for a in (ax, ax2):
        a.grid(alpha=0.3)

    def update(_):
        raw = ser.read(ser.in_waiting or 1)
        buf[0] += raw
        while b"\n" in buf[0]:
            ln, buf[0] = buf[0].split(b"\n", 1)
            rec = parse(ln.strip())
            if not rec:
                continue
            bid, cnt, t = rec
            n[0] += 1
            tally[t] += 1
            xs.append(n[0]); bids.append(bid); counts.append(cnt)
        if xs:
            line_bid.set_data(xs, bids)
            line_cnt.set_data(xs, counts)
            ax.set_xlim(xs[0], max(xs[-1], xs[0] + 1))
            lo, hi = min(bids), max(bids)
            pad = (hi - lo) * 0.1 or 1
            ax.set_ylim(lo - pad, hi + pad)
            ax2.set_ylim(0, max(counts) * 1.2 + 1)
            ax.set_title(f"${bids[-1]:,.4f}    {counts[-1]} resting orders    "
                         f"A {tally['A']}  D {tally['D']}  E {tally['E']}")
        return line_bid, line_cnt

    buf = [b""]
    _anim = FuncAnimation(fig, update, interval=50, blit=False,
                          cache_frame_data=False)
    plt.tight_layout()
    plt.show()


# ---------------------------------------------------------------------------
def run_terminal(ser):
    tally = {"A": 0, "D": 0, "E": 0}
    hist = collections.deque(maxlen=60)
    n = 0
    blocks = "▁▂▃▄▅▆▇█"
    buf = b""
    print("reading telemetry (Ctrl-C to stop)...\n")
    while True:
        buf += ser.read(ser.in_waiting or 1)
        while b"\n" in buf:
            ln, buf = buf.split(b"\n", 1)
            rec = parse(ln.strip())
            if not rec:
                continue
            bid, cnt, t = rec
            n += 1
            tally[t] += 1
            hist.append(bid)
            lo, hi = min(hist), max(hist)
            spark = "".join(
                blocks[min(7, int((v - lo) / ((hi - lo) or 1) * 7))] for v in hist
            )
            sys.stdout.write(
                f"\r#{n:<6} ${bid:>12,.4f}  orders {cnt:>3}  "
                f"A{tally['A']} D{tally['D']} E{tally['E']}  {spark} "
            )
            sys.stdout.flush()
        time.sleep(0.02)


# ---------------------------------------------------------------------------
def main(argv):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", default=None, help="serial port (default: auto)")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--window", type=int, default=400, help="points shown (mpl)")
    ap.add_argument("--terminal", action="store_true", help="force terminal view")
    a = ap.parse_args(argv[1:])

    port = a.port or find_port()
    print(f"port {port} @ {a.baud}")
    try:
        ser = serial.Serial(port, a.baud, timeout=0)
    except serial.SerialException as e:
        sys.exit(f"{e}\n(the -DANIMATE build must be in SPI flash: `make flash-demo`, "
                 f"then replug -- opening the port wipes an SRAM config)")
    time.sleep(0.2)
    ser.reset_input_buffer()

    if a.terminal:
        run_terminal(ser)
        return 0
    try:
        run_mpl(ser, a.window)
    except ImportError:
        print("matplotlib not found -- terminal view "
              "(pip install matplotlib for the chart)\n")
        run_terminal(ser)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv))
    except KeyboardInterrupt:
        print()
