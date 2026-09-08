// blink.v -- Phase 1 hardware bring-up. Validates the flash path before any
// real logic exists. Counter off the 27 MHz clock, a high bit to one LED.
//
// The Tang Nano 20K LEDs are ACTIVE LOW: drive 0 to light. led[0] blinks at
// ~1.6 Hz off the 27 MHz clock (bit 23 of a free-running counter); the other
// five stay off (driven high).
//
// CW/BIT are parameters only so the testbench can use a tiny counter; the
// synthesized top keeps the defaults.

`timescale 1ns/1ps

module blink #(
    parameter CW  = 25,
    parameter BIT = 23
) (
    input  wire       clk,
    input  wire       rst_n,      // button, active low; optional
    output wire [5:0] led
);
    reg [CW-1:0] cnt;

    always @(posedge clk) begin
        if (!rst_n) cnt <= {CW{1'b0}};
        else        cnt <= cnt + 1'b1;
    end

    assign led = {5'b11111, ~cnt[BIT]};
endmodule
