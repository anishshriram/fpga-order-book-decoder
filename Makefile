# ITCH-to-Book FPGA -- build / sim / synth / flash
#
#   make feed     regenerate data/*.{hex,bin,txt} from the synthetic ITCH feed
#   make sim      compile + run every self-checking testbench (fails on any FAIL)
#   make wave TB=tb_book    run one testbench with waveform dump, open GTKWave
#   make synth    yosys -> nextpnr-himbaechel -> gowin_pack  => build/top.fs
#   make blink    same flow for the Phase 1 LED bring-up     => build/blink.fs
#   make flash    openFPGALoader build/top.fs   (needs the board)
#   make flash-blink
#   make clean

OSS ?= $(HOME)/oss-cad-suite
export PATH := $(OSS)/bin:$(PATH)

IVERILOG := iverilog -g2012 -Wall
VVP      := vvp
BUILD    := build

# integration RTL (order matters only for readability; iverilog resolves refs)
RTL := parser.v book.v bin2bcd.v display.v rom.v top.v

# every testbench; each is compiled against all non-tb sources
TBS  := tb_parser tb_book tb_display tb_blink tb_top
SRCS := $(filter-out tb_%,$(wildcard *.v))

DEVICE := GW2AR-LV18QN88C8/I7
FAMILY := GW2A-18C
GWDEV  := GW2A-18C

# ---------------------------------------------------------------------------
.PHONY: sim feed wave synth blink flash flash-blink clean $(addprefix run-,$(TBS))

sim: feed $(addprefix run-,$(TBS))
	@echo "-----------------------------------"
	@echo "all testbenches passed"

$(addprefix run-,$(TBS)): run-%: %.v $(SRCS) | $(BUILD)
	@echo "== $* =="
	@$(IVERILOG) -s $* -o $(BUILD)/$* $*.v $(SRCS)
	@$(VVP) $(BUILD)/$* | tee $(BUILD)/$*.log
	@grep -q "ALL TESTS PASSED" $(BUILD)/$*.log \
		|| { echo ">>> $* FAILED"; exit 1; }

# ---------------------------------------------------------------------------
feed: | $(BUILD)
	python3 tools/itch_to_hex.py --synth

# ---------------------------------------------------------------------------
wave: feed | $(BUILD)
	@test -n "$(TB)" || { echo "usage: make wave TB=tb_book"; exit 1; }
	$(IVERILOG) -DDUMP -s $(TB) -o $(BUILD)/$(TB)_w $(TB).v $(SRCS)
	$(VVP) $(BUILD)/$(TB)_w
	gtkwave $(TB).vcd

# ---------------------------------------------------------------------------
synth: $(BUILD)/top.fs
blink: $(BUILD)/blink.fs

$(BUILD)/%.fs: %.v $(RTL) tangnano20k.cst feed | $(BUILD)
	yosys -p "read_verilog $(if $(filter blink,$*),blink.v,$(RTL)); \
	          synth_gowin -top $* -json $(BUILD)/$*.json"
	nextpnr-himbaechel --json $(BUILD)/$*.json --write $(BUILD)/$*_pnr.json \
	    --device $(DEVICE) --vopt family=$(FAMILY) --vopt cst=tangnano20k.cst \
	    --freq 27
	gowin_pack -d $(GWDEV) -o $@ $(BUILD)/$*_pnr.json

# ---------------------------------------------------------------------------
flash: $(BUILD)/top.fs
	openFPGALoader -b tangnano20k $<
flash-blink: $(BUILD)/blink.fs
	openFPGALoader -b tangnano20k $<

# ---------------------------------------------------------------------------
$(BUILD):
	mkdir -p $(BUILD)

clean:
	rm -rf $(BUILD) *.vcd
	rm -f data/feed.hex data/feed.bin data/feed.vh data/expected.txt data/events.txt
