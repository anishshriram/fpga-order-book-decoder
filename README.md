# ITCH-to-Book FPGA

Hardware limit order book on a Sipeed Tang Nano 20K (Gowin GW2AR-18, 27 MHz).
Reads a NASDAQ ITCH 5.0 byte stream, maintains a bid-side order book, shows the
best bid on a 7-segment display. See [SPEC.md](SPEC.md) for the full build spec;
it is authoritative.

## Status

| Phase | What | Sim | Hardware |
|---|---|---|---|
| 0 | Toolchain (oss-cad-suite) | done | — |
| 1 | LED blink bring-up | `tb_blink` pass | **PASS** (all 6 blink) |
| 2 | Parser (`A`/`D`/`E`) | `tb_parser` pass | runs in `top` |
| 3 | Order book (CAM, ~4-cycle ops) | `tb_book`, `tb_book_equiv` pass | runs in `top` |
| 4 | 7-seg display + double-dabble | `tb_display` pass | not wired |
| 5 | ROM → parser → book → display | `tb_top` `tb_uart` `tb_multitop` pass | **PASS** (LEDs + UART) |

On hardware `top` reports the best bid two ways with no wiring: all 6 LEDs lit
when it equals the reference model, and an ASCII dollar value streamed over the
onboard USB serial (`000199.9900` for the synthetic feed).

`make synth` builds `build/top.fs` with the open-source flow: 45% LUT4, 33% FF,
17/46 BSRAM (the CAM book dominates), closes timing at the 27 MHz clock.

## Toolchain

Native darwin-arm64 [oss-cad-suite](https://github.com/YosysHQ/oss-cad-suite-build)
(Yosys, nextpnr-himbaechel, Apicula, Icarus Verilog, GTKWave, openFPGALoader).
Installed at `~/oss-cad-suite`; the Makefile puts `~/oss-cad-suite/bin` on PATH
itself. For an interactive shell:

```sh
export PATH="$HOME/oss-cad-suite/bin:$PATH"
```

Apicula and nextpnr-himbaechel both ship `GW2A-18C` device data, so the Tang
Nano 20K part is fully supported by the open flow — no Gowin EDA needed.

Board enumeration (when plugged in): `ls /dev/tty.*` shows two `usbserial`
ports from the BL616; macOS may prompt to allow the USB device.

## Make targets

```
make feed              regenerate data/*.{hex,bin,txt,vh} from the synthetic feed
make sim               compile + run every self-checking testbench
make wave TB=tb_book   run one testbench with a waveform dump, open GTKWave
make synth             yosys → nextpnr-himbaechel → gowin_pack  ⇒ build/top.fs
make blink             same flow for the Phase 1 bring-up       ⇒ build/blink.fs
make flash             openFPGALoader build/top.fs   (needs the board)
make flash-blink
make clean
```

Run everything from the repo root — `$readmemh` and the testbench file reads
resolve paths against the working directory.

## Data tooling

- `tools/reference_book.py` — golden model, mirrors `parser.v` + `book.v` exactly
  (16-bit truncated order ids, bid side only, `A`/`D`/`E`, slot-array book).
  Also runnable: `python3 tools/reference_book.py data/feed.bin`.
- `tools/itch_to_hex.py` — feed generator.
  - `--synth` emits a deterministic sequence with a known best-bid trajectory.
  - `tools/itch_to_hex.py <file> --ticker AAPL --limit 800` filters a real
    NASDAQ ITCH 5.0 file (BinaryFILE framing: 2-byte big-endian length prefix
    per message; `.gz` auto-decompressed) to one ticker's first `--limit`
    `A`/`D`/`E` messages. It reads type + stock-locate from fixed offsets and
    stops early, so a liquid ticker is seconds even on a 10 GB file. The slice
    must fit `ROM_DEPTH` (32768 bytes) — raise it here and in `rom.v` for a
    bigger window. Sample files: the NASDAQ historical ITCH archive
    (`emi.nasdaq.com`), no account, ~5 GB gz.
  - `make feed` → synthetic feed. `make feed-real ITCH=<file> [TICKER=AAPL]
    [LIMIT=800]` → real slice (survives a later `make sim`, which only
    regenerates the synthetic feed if it is missing).

Outputs: `feed.hex` ($readmemh, padded to ROM depth), `feed.bin` (raw, for the
model), `events.txt` (decoded events + expected best bid, for `tb_book`),
`expected.txt` (trajectory), `feed.vh` (`FEED_BYTES` / `FEED_FINAL_BEST`).

## Design notes

- **Parser** carries an ITCH 5.0 message-length LUT so it can count past any
  message type it does not decode; a type absent from the LUT is skipped one
  byte at a time to resync. Sell-side Adds (`buy/sell == 'S'`) are counted past
  with no event emitted.
- **Book** (`book.v`): the 256 order ids live in flip-flops as a CAM, matched
  in parallel, so Delete/Execute find their slot in 1 clock (fixed ~4 clocks
  total) instead of scanning. A running count of orders at the best price means
  the O(n) rescan only fires when the top price level fully clears. `{price,
  shares}` stay in BSRAM. Synth: 45% LUT4, 33% FF, closes at 27 MHz.
- **`book_scan.v`**: the original linear-scan book (BSRAM payload, O(n) every
  op, up to ~1500 clocks for a delete that empties the top of book). Kept for
  `tb_book_equiv`, which asserts the two are bit-identical every event.
- **Display** (7-seg) shows the low 16 bits of `best_bid` in hex. `bin2bcd.v`
  (double-dabble) is built and tested but not wired into the 7-seg path.
- **UART readout** (`readout.v` + `uart_tx.v`): ~10×/s `top` converts `best_bid`
  with `bin2bcd` and transmits `"DDDDDD.DDDD\r\n"` (dollars) on pin 69, which
  routes to the onboard FT2232 channel B — no wiring.

## Live chart (`tools/viz.py`)

The `-DANIMATE` builds pace the feed to ~12 messages/s, loop it, and after each
message transmit one telemetry line — `I DDDDDDDD CCC T` (book index, best bid
in 1/10000 $, resting order count, `A`/`D`/`E`). `tools/viz.py` reads that and
draws a live best-bid chart — one line per book (matplotlib, or a scrolling
terminal view with `--terminal`).

**Four books at once** (`multitop.v` — parser routes each event by stock locate
to one of four `book_scan` instances):

```
make feed-multi ITCH=01302019.NASDAQ_ITCH50    # AMD,MSFT,AAPL,NVDA (TICKERS= to change)
make flash-multi                               # -> SPI flash; replug
python3 tools/viz.py                            # 4 live lines, names from data/tickers.txt
```

**One book** (`top.v` with `-DANIMATE`):

```
make feed-real ITCH=01302019.NASDAQ_ITCH50 TICKER=MSFT
make flash-demo
python3 tools/viz.py
```

**One book + three physical 7-segment displays** (`-DSSEG3`, `sseg12.v` + `disp3.v`):
`make flash-demo3` drives three CL5641BH (common anode) showing **ticker name /
best bid `DDD.D` / resting order count**. Wire per `tangnano20k.cst`: 8 shared
segment lines (220 Ω each) + 12 digit-selects, each through a PNP high-side
switch (1 kΩ base) to 3.3 V. The `dbg[]` logic-analyzer taps are dropped in this
build (the count digits reuse those pins). Renders cleanly for tickers whose
letters exist on 7-seg (AAPL yes; MSFT/NVDA/AMD have M/V that don't).

`make flash-perm` restores the normal full-speed one-shot build.
The `-DANIMATE` builds use `book_scan` (the CAM book misses 27 MHz once the
telemetry logic is added); `make synth` / `flash-perm` keep the CAM book.

## Reading it on the computer

`top` must be in **SPI flash**, not SRAM — opening the serial port toggles DTR
and wipes an SRAM config:

```
make flash-perm          # top.fs -> SPI flash
# replug the board, then:
python3 -c "import serial;s=serial.Serial('/dev/cu.usbserial-XXXXXXXX1',115200,timeout=2);\
import time;time.sleep(.3);print(s.read(200).decode('ascii','replace'))"
#   or:  screen /dev/cu.usbserial-XXXXXXXX1 115200      (exit: Ctrl-A K)
```

The `...0` port is the FT2232 JTAG channel; the `...1` port is the UART.

## Logic-analyzer taps

`top` drives 8 debug signals on the **J6 header** for the HiLetgo/sigrok analyzer:

| CH | signal | J6 pin | note |
|---|---|---|---|
| 0 | `byte_valid` | 73 | one pulse per ROM byte into the parser |
| 1 | `event_valid` | 74 | one pulse per decoded A/D/E |
| 2 | `book_busy` | 76 | high while the book scans |
| 3 | `done` | 77 | high once the whole feed is consumed |
| 4 | `uart_tx` | 27 | the serial line — sigrok's UART decoder reads it |
| 5 | `best_bid[0]` | 28 | |
| 6 | `best_bid[8]` | 29 | |
| 7 | `best_bid[16]` | 30 | |

Analyzer GND → any board GND pin. Leave the analyzer's `VCC` pin unconnected.

`byte_valid`/`event_valid` on the taps are stretched to ~1.2 us so a 24 MHz
analyzer can see them (the real signals into parser/book are untouched).

The feed runs once at power-up in ~1 ms. `make flash-loop` builds a **replay
variant** that throttles the feeder (~150 us/byte) and re-runs it every ~0.5 s,
so a free-running capture always catches a full pass:

```
make flash-loop     # replay build -> SPI flash; replug
sigrok-cli --driver fx2lafw --config samplerate=4m \
  --channels D0=byte_valid,D1=event_valid,D2=book_busy,D3=done,D4=uart_tx,D5=bb0,D6=bb8,D7=bb16 \
  --time 600 -o cap.sr
sigrok-cli -i cap.sr -O vcd > cap.vcd && gtkwave cap.vcd
sigrok-cli -i cap.sr -P uart:rx=D4:baudrate=115200 -A uart=rx-data   # -> ASCII
```

`make flash-perm` puts back the normal full-speed one-shot build.

## Hardware still to do

- Wire the 5641BH to the J5 header per `tangnano20k.cst`. The common anode
  sources the sum of all lit segment currents (~48 mA) — **drive the digit
  pins through PNP / P-MOSFET high-side switches**, not straight from GW2A
  pins (rated ~8 mA, not 5 V tolerant). ~220 Ω per segment line.
- `make feed-real ITCH=… && make flash-perm`, confirm the UART value matches the
  reference model for a real ITCH slice.
