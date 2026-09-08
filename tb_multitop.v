// tb_multitop.v -- end-to-end test of the 4-book multitop.
// Replays the interleaved 4-ticker feed and checks each book's final best bid
// against tools/itch_to_hex.py's per-book reference values in data/feed.vh.
// Build: iverilog -DSIMPACE (see `make sim-multi`).

`timescale 1ns/1ps
`include "data/feed.vh"

module tb_multitop;
    reg clk = 1'b0;
    reg rst_n = 1'b0;
    wire [5:0] led;
    wire       uart_tx;
    wire [7:0] dbg;

    multitop dut (.clk(clk), .rst_n(rst_n), .led(led), .uart_tx(uart_tx), .dbg(dbg));

    always #18 clk = ~clk;           // ~27 MHz

    integer errors = 0, i;

    task chk(input [8*24:1] name, input [31:0] got, input [31:0] exp);
        begin
            if (got === exp) $display("PASS  %-6s best bid = %0d", name, got);
            else begin
                errors = errors + 1;
                $display("FAIL  %-6s best bid = %0d  expected %0d", name, got, exp);
            end
        end
    endtask

    initial begin
`ifdef DUMP
        $dumpfile("tb_multitop.vcd"); $dumpvars(0, tb_multitop);
`endif
        repeat (5) @(negedge clk);
        rst_n = 1'b1;

        wait (dut.done === 1'b1);
        // let the last book drain: require all-idle for a good while
        i = 0;
        while (i < 4000) begin
            @(negedge clk);
            if (dut.any_busy) i = 0; else i = i + 1;
        end

        chk("book0", dut.bk_best0, `FEED_FINAL0);
        chk("book1", dut.bk_best1, `FEED_FINAL1);
        chk("book2", dut.bk_best2, `FEED_FINAL2);
        chk("book3", dut.bk_best3, `FEED_FINAL3);

        $display("----");
        if (errors == 0) $display("ALL TESTS PASSED");
        else             $display("TESTS FAILED");
        $finish;
    end

    initial begin
        #200_000_000;
        $display("FAIL  timeout");
        $display("TESTS FAILED");
        $finish;
    end
endmodule
