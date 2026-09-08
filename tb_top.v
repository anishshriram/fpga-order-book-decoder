// tb_top.v -- self-checking end-to-end test: ROM -> parser -> book -> display.
// Replays the whole generated feed through the real top-level and checks the
// final best_bid against the reference model's value (data/feed.vh).

`timescale 1ns/1ps
`include "data/feed.vh"

module tb_top;
    reg clk = 1'b0;
    reg rst_n = 1'b0;

    wire [5:0] led;
    wire [7:0] seg;
    wire [3:0] dig;

    top dut (.clk(clk), .rst_n(rst_n), .led(led), .seg(seg), .dig(dig));

    always #18 clk = ~clk;      // ~27 MHz

    integer errors = 0;
    integer i;

    initial begin
`ifdef DUMP
        $dumpfile("tb_top.vcd");
        $dumpvars(0, tb_top);
`endif
        repeat (5) @(negedge clk);
        rst_n = 1'b1;

        // wait for the feeder to finish, then let the book fully drain:
        // require book_busy low continuously for longer than the worst-case
        // scan+rescan so a still-pending final event can't be missed.
        wait (dut.done === 1'b1);
        i = 0;
        while (i < 4000) begin
            @(negedge clk);
            if (dut.book_busy) i = 0;
            else               i = i + 1;
        end

        if (dut.best_bid === `FEED_FINAL_BEST)
            $display("PASS  final best_bid = %0d", dut.best_bid);
        else begin
            errors = errors + 1;
            $display("FAIL  final best_bid = %0d  expected %0d",
                     dut.best_bid, `FEED_FINAL_BEST);
        end

        // LEDs mirror the low 6 bits, active low
        if (led === ~dut.best_bid[5:0])
            $display("PASS  led mirrors best_bid[5:0]");
        else begin
            errors = errors + 1;
            $display("FAIL  led = %b  expected %b", led, ~dut.best_bid[5:0]);
        end

        $display("----");
        if (errors == 0) $display("ALL TESTS PASSED");
        else             $display("TESTS FAILED");
        $finish;
    end

    initial begin
        #20000000;                 // 20 ms safety timeout
        $display("FAIL  timeout (feeder never finished)");
        $display("TESTS FAILED");
        $finish;
    end
endmodule
