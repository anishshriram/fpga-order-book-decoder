# ITCH-to-Book FPGA

Hardware limit order book on a Sipeed Tang Nano 20K (Gowin GW2AR-18, 27 MHz).
Reads a NASDAQ ITCH 5.0 byte stream, maintains a bid-side order book, shows the
best bid on a 7-segment display. See [SPEC.md](SPEC.md) for the full build spec;
it is authoritative.

## Status

| Phase | What | Sim | Hardware |
|---|---|---|---|
| 0 | Toolchain (oss-cad-suite) | done | — |
| 1 | LED blink bring-up | `tb_blink` pass | not flashed |
| 2 | Parser (`A`/`D`/`E`) | `tb_parser` pass | — |
| 3 | Order book + best bid | `tb_book` pass | — |
| 4 | 7-seg display + double-dabble | `tb_display` pass | not wired |
| 5 | ROM → parser → book → display | `tb_top` pass | not flashed |

`make synth` builds `build/top.fs` with the open-source flow: ~11% LUT4, ~5% FF,
18/46 BSRAM, Fmax ~93 MHz (clock is 27 MHz).

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
  - `--synth` emits a deterministic sequence with a known best-bid trajectory
    (this is what the testbenches use).
  - `tools/itch_to_hex.py <file.gz> --ticker AAPL` filters a real NASDAQ ITCH 5.0
    file (2-byte big-endian length prefix per message) to one ticker's `A`/`D`/`E`
    messages. Historical sample files are on the NASDAQ / LSE data portals; the
    multi-GB download is optional — the synthetic feed covers CI. The feed must
    fit `ROM_DEPTH` (32768 bytes); shorten the slice or raise it in both
    `itch_to_hex.py` and `rom.v` if needed.

Outputs: `feed.hex` ($readmemh, padded to ROM depth), `feed.bin` (raw, for the
model), `events.txt` (decoded events + expected best bid, for `tb_book`),
`expected.txt` (trajectory), `feed.vh` (`FEED_BYTES` / `FEED_FINAL_BEST`).

## Design notes

- **Parser** carries an ITCH 5.0 message-length LUT so it can count past any
  message type it does not decode; a type absent from the LUT is skipped one
  byte at a time to resync. Sell-side Adds (`buy/sell == 'S'`) are counted past
  with no event emitted.
- **Book** keeps `valid` bits in flip-flops and `{id, price, shares}` in BSRAM
  (1-cycle read). Every lookup is a linear scan sub-FSM; a delete/execute that
  removes the best price triggers a full rescan for the new maximum. Slow,
  correct.
- **Display** shows the low 16 bits of `best_bid` in hex. `bin2bcd.v`
  (double-dabble) is built and tested but not yet wired into `top.v` — decimal
  dollars is a follow-on.

## Hardware still to do

- Flash `blink.fs`, confirm a visible blink (LEDs are **active low**).
- Wire the 5641BH to the J5 header per `tangnano20k.cst`. The common anode
  sources the sum of all lit segment currents (~48 mA) — **drive the digit
  pins through PNP / P-MOSFET high-side switches**, not straight from GW2A
  pins (rated ~8 mA, not 5 V tolerant). ~220 Ω per segment line.
- Flash `top.fs`, confirm the displayed best bid matches the reference model's
  final state for a real ITCH slice.
