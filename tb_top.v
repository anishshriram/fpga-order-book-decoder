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
    wire       uart_tx;
    wire [7:0] dbg;

    top dut (.clk(clk), .rst_n(rst_n), .led(led), .seg(seg), .dig(dig),
             .uart_tx(uart_tx), .dbg(dbg));

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

        // all six LEDs lit (active low -> 000000) = done && best_bid matches
        if (led === 6'b000000)
            $display("PASS  all six LEDs lit (done + match)");
        else begin
            errors = errors + 1;
            $display("FAIL  led = %b  expected 000000", led);
        end

        // debug taps: dbg[3]=done should be high, dbg[2]=book_busy low now
        if (dbg[3] === 1'b1 && dbg[2] === 1'b0)
            $display("PASS  dbg taps sane (done=1 busy=0)");
        else begin
            errors = errors + 1;
            $display("FAIL  dbg = %b", dbg);
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
