# ITCH-to-Book FPGA -- build / sim / synth / flash
#
#   make feed     regenerate data/* from the synthetic ITCH feed
#   make feed-real ITCH=<file> [TICKER=AAPL] [LIMIT=800]   real ITCH slice
#   make sim      compile + run every self-checking testbench (fails on any FAIL)
#   make wave TB=tb_book    run one testbench with waveform dump, open GTKWave
#   make synth    yosys -> nextpnr-himbaechel -> gowin_pack  => build/top.fs
#   make blink    same flow for the Phase 1 LED bring-up     => build/blink.fs
#   make flash       build/top.fs -> SRAM (fast, volatile)
#   make flash-perm  build/top.fs -> SPI flash (survives power cycle AND the
#                    serial port being opened; required for the UART readout)
#   make flash-loop  replay variant -> SPI flash (feeder throttled + re-runs
#                    every ~0.5s; for a free-running logic-analyzer capture)
#   make flash-demo  animation variant -> SPI flash (paced feed + per-message
#                    telemetry for tools/viz.py)
#   make flash-blink
#   make clean

OSS ?= $(HOME)/oss-cad-suite
export PATH := $(OSS)/bin:$(PATH)

IVERILOG := iverilog -g2012 -Wall
VVP      := vvp
BUILD    := build

# integration RTL (order matters only for readability; iverilog resolves refs)
RTL := parser.v book.v bin2bcd.v display.v uart_tx.v readout.v rom.v top.v

# every testbench; each is compiled against all non-tb sources
TBS  := tb_parser tb_book tb_display tb_blink tb_uart tb_top
SRCS := $(filter-out tb_%,$(wildcard *.v))

DEVICE := GW2AR-LV18QN88C8/I7
FAMILY := GW2A-18C
GWDEV  := GW2A-18C

# ---------------------------------------------------------------------------
.PHONY: sim sim-anim feed feed-real wave synth blink flash flash-perm flash-loop flash-demo flash-blink clean \
        $(addprefix run-,$(TBS))

# `make sim` always runs the deterministic synthetic feed. To exercise the
# testbenches against a real slice instead: `make feed-real ITCH=...` then
# `make run-tb_top` (or run-tb_book) directly -- those use whatever feed is
# currently in data/.
sim: feed $(addprefix run-,$(TBS)) sim-anim
	@echo "-----------------------------------"
	@echo "all testbenches passed"

sim-anim: data/feed.vh | $(BUILD)          # the -DANIMATE telemetry path
	@echo "== tb_anim (-DANIMATE) =="
	@$(IVERILOG) -DANIMATE -s tb_anim -o $(BUILD)/tb_anim \
	    tb_anim.v readout.v bin2bcd.v uart_tx.v
	@$(VVP) $(BUILD)/tb_anim | tee $(BUILD)/tb_anim.log
	@grep -q "ALL TESTS PASSED" $(BUILD)/tb_anim.log || { echo ">>> tb_anim FAILED"; exit 1; }
	@echo "== tb_animtop (-DANIMATE -DSIMPACE) =="
	@$(IVERILOG) -DANIMATE -DSIMPACE -s tb_animtop -o $(BUILD)/tb_animtop \
	    tb_animtop.v $(filter-out tb_%,$(wildcard *.v))
	@$(VVP) $(BUILD)/tb_animtop | tee $(BUILD)/tb_animtop.log
	@grep -q "ALL TESTS PASSED" $(BUILD)/tb_animtop.log || { echo ">>> tb_animtop FAILED"; exit 1; }

$(addprefix run-,$(TBS)): run-%: %.v $(SRCS) data/feed.vh | $(BUILD)
	@echo "== $* =="
	@$(IVERILOG) -s $* -o $(BUILD)/$* $*.v $(SRCS)
	@$(VVP) $(BUILD)/$* | tee $(BUILD)/$*.log
	@grep -q "ALL TESTS PASSED" $(BUILD)/$*.log \
		|| { echo ">>> $* FAILED"; exit 1; }

# ---------------------------------------------------------------------------
feed: | $(BUILD)                        # always regenerate the synthetic feed
	python3 tools/itch_to_hex.py --synth

data/feed.vh: | $(BUILD)                # bootstrap a feed only if none exists
	python3 tools/itch_to_hex.py --synth

# real slice: ITCH=<file> [TICKER=AAPL] [LIMIT=800]
feed-real: | $(BUILD)
	@test -n "$(ITCH)" || { echo "usage: make feed-real ITCH=<file> [TICKER=AAPL] [LIMIT=800]"; exit 1; }
	python3 tools/itch_to_hex.py "$(ITCH)" \
	    --ticker "$(or $(TICKER),AAPL)" --limit "$(or $(LIMIT),800)"

# ---------------------------------------------------------------------------
wave: data/feed.vh | $(BUILD)
	@test -n "$(TB)" || { echo "usage: make wave TB=tb_book"; exit 1; }
	$(IVERILOG) -DDUMP -s $(TB) -o $(BUILD)/$(TB)_w $(TB).v $(SRCS)
	$(VVP) $(BUILD)/$(TB)_w
	gtkwave $(TB).vcd

# ---------------------------------------------------------------------------
synth: $(BUILD)/top.fs
blink: $(BUILD)/blink.fs

# synth/flash bake whatever feed is in data/ into the ROM -- choose it with
# `make feed` (synthetic) or `make feed-real ITCH=...` first.
# DEFS: pass VDEFS=-DREPLAY to build the replay variant (feed re-runs ~every
# 0.4s for a free-running logic-analyzer capture).
VDEFS ?=

$(BUILD)/%.fs: %.v $(RTL) tangnano20k.cst data/feed.vh | $(BUILD)
	yosys -p "read_verilog $(VDEFS) $(if $(filter blink,$*),blink.v,$(RTL)); \
	          synth_gowin -top $* -json $(BUILD)/$*.json"
	nextpnr-himbaechel --json $(BUILD)/$*.json --write $(BUILD)/$*_pnr.json \
	    --device $(DEVICE) --vopt family=$(FAMILY) --vopt cst=tangnano20k.cst \
	    --freq 27
	gowin_pack -d $(GWDEV) -o $@ $(BUILD)/$*_pnr.json

# ---------------------------------------------------------------------------
flash: $(BUILD)/top.fs
	openFPGALoader -b tangnano20k $<
flash-perm: $(BUILD)/top.fs
	openFPGALoader -b tangnano20k -f $<
flash-loop:                       # replay variant -> SPI flash
	rm -f $(BUILD)/top.fs $(BUILD)/top.json
	$(MAKE) VDEFS=-DREPLAY $(BUILD)/top.fs
	openFPGALoader -b tangnano20k -f $(BUILD)/top.fs
	rm -f $(BUILD)/top.fs $(BUILD)/top.json
flash-demo:                       # animation variant -> SPI flash (for tools/viz.py)
	rm -f $(BUILD)/top.fs $(BUILD)/top.json
	$(MAKE) VDEFS=-DANIMATE $(BUILD)/top.fs
	openFPGALoader -b tangnano20k -f $(BUILD)/top.fs
	rm -f $(BUILD)/top.fs $(BUILD)/top.json
flash-blink: $(BUILD)/blink.fs
	openFPGALoader -b tangnano20k $<

# ---------------------------------------------------------------------------
$(BUILD):
	mkdir -p $(BUILD)

clean:
	rm -rf $(BUILD) *.vcd
	rm -f data/feed.hex data/feed.bin data/feed.vh data/expected.txt data/events.txt
