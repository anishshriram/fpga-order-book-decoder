// rom.v -- byte ROM preloaded from a $readmemh hex file.
//
// In simulation the testbench also reads the file directly; on hardware this
// same file initializes a BSRAM ROM. $readmemh in an initial block is the
// accepted synthesis idiom for block-RAM preload (yosys synth_gowin supports
// it) and is the one place SPEC.md calls for `initial` in a design file.
//
// $readmemh resolves the path relative to the simulator's working directory,
// not this file -- run from the repo root (the Makefile does).

`timescale 1ns/1ps

module rom #(
    parameter FILE  = "data/feed.hex",
    parameter DEPTH = 32768,
    parameter AW    = 15
) (
    input  wire          clk,
    input  wire [AW-1:0] addr,
    output reg  [7:0]    data
);
    reg [7:0] mem [0:DEPTH-1];

    initial $readmemh(FILE, mem);

    always @(posedge clk)
        data <= mem[addr];
endmodule
