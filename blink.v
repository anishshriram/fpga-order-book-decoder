// blink.v -- Phase 1 hardware bring-up. Validates the flash path before any
// real logic exists.
//
// Free-running counter off the 27 MHz clock; a high bit drives ALL SIX LEDs
// together so the blink is unmistakable. The Tang Nano 20K LEDs are ACTIVE
// LOW (drive 0 to light). The counter is NOT gated on the reset button --
// this is a pure "is the clock reaching the fabric and can we flash" test.
//
// CW/BIT are parameters only so the testbench can use a tiny counter; the
// synthesized top keeps the defaults (~1.6 Hz at 27 MHz).

`timescale 1ns/1ps

module blink #(
    parameter CW  = 25,
    parameter BIT = 23
) (
    input  wire       clk,
    input  wire       rst_n,      // intentionally unused (kept for the .cst)
    output wire [5:0] led
);
    wire _unused = rst_n;

    reg [CW-1:0] cnt = {CW{1'b0}};

    always @(posedge clk)
        cnt <= cnt + 1'b1;

    assign led = {6{~cnt[BIT]}};   // all six blink together, active low
endmodule
