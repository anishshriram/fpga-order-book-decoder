// tb_animtop.v -- integration test for the -DANIMATE telemetry path.
// Instantiates the real top-level, sniffs the telemetry UART, and checks the
// first handful of lines decode as "DDDDDDDD CCC T" with a sane trajectory.
// Full-feed correctness is covered by tb_top. Build with -DANIMATE -DSIMPACE.

`timescale 1ns/1ps
`include "data/feed.vh"

module tb_animtop;
    reg clk = 1'b0, rst_n = 1'b0;
    wire [5:0] led;  wire [7:0] seg;  wire [3:0] dig;
    wire uart_tx;    wire [7:0] dbg;

    top dut (.clk(clk), .rst_n(rst_n), .led(led), .seg(seg), .dig(dig),
             .uart_tx(uart_tx), .dbg(dbg));

    always #18 clk = ~clk;
    localparam real BITNS = 1_000_000_000.0 / 115200;

    integer errors = 0, nlines = 0;
    integer last_best = -1, last_cnt = -1, max_best = 0;
    reg [7:0] last_type;

    task uart_byte(output [7:0] b);
        integer k; reg s;
        begin
            @(negedge uart_tx); #(BITNS*1.5);
            for (k = 0; k < 8; k = k + 1) begin s = uart_tx; b[k] = s; #(BITNS); end
        end
    endtask

    reg [7:0] c;
    integer f, best, cnt, li;
    task get_line;
        begin
            best = 0;
            for (f = 0; f < 8; f = f + 1) begin
                uart_byte(c);
                if (c < 8'h30 || c > 8'h39) errors = errors + 1;
                best = best*10 + (c - 8'h30);
            end
            uart_byte(c); if (c !== 8'h20) errors = errors + 1;
            cnt = 0;
            for (f = 0; f < 3; f = f + 1) begin
                uart_byte(c);
                if (c < 8'h30 || c > 8'h39) errors = errors + 1;
                cnt = cnt*10 + (c - 8'h30);
            end
            uart_byte(c); if (c !== 8'h20) errors = errors + 1;
            uart_byte(last_type);
            uart_byte(c); if (c !== 8'h0A) errors = errors + 1;
            if (last_type !== "A" && last_type !== "D" && last_type !== "E")
                errors = errors + 1;
            last_best = best; last_cnt = cnt;
            if (best > max_best) max_best = best;
            nlines = nlines + 1;
            $display("  line %0d: best=%0d cnt=%0d type=%s", nlines, best, cnt,
                     last_type);
        end
    endtask

    initial begin
        repeat (5) @(negedge clk);
        rst_n = 1'b1;

        for (li = 0; li < 12; li = li + 1) get_line;

        if (max_best > 0) $display("PASS  telemetry shows a non-zero best bid");
        else begin errors = errors + 1; $display("FAIL  best bid never moved"); end

        if (last_cnt >= 0 && last_cnt < 256) $display("PASS  order count in range");
        else begin errors = errors + 1; $display("FAIL  order count %0d", last_cnt); end

        $display("----");
        if (errors == 0) $display("ALL TESTS PASSED");
        else             $display("TESTS FAILED");
        $finish;
    end

    initial begin
        #60_000_000;
        $display("FAIL  timeout  (%0d lines)", nlines);
        $display("TESTS FAILED");
        $finish;
    end
endmodule
