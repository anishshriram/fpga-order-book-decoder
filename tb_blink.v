// tb_blink.v -- self-checking testbench for blink.v
// Uses a tiny counter (CW=4, BIT=2) so the LED toggles every 4 clocks, then
// checks it is active-low idle and toggles on schedule.

`timescale 1ns/1ps

module tb_blink;
    reg        clk = 1'b0;
    reg        rst_n = 1'b0;
    wire [5:0] led;

    integer errors = 0;
    integer checks = 0;

    blink #(.CW(4), .BIT(2)) dut (.clk(clk), .rst_n(rst_n), .led(led));

    always #5 clk = ~clk;

    task chk(input [8*40:1] name, input cond);
        begin
            checks = checks + 1;
            if (cond) $display("PASS  %0s", name);
            else begin errors = errors + 1; $display("FAIL  %0s", name); end
        end
    endtask

    integer toggles;
    reg prev;
    integer i;

    initial begin
`ifdef DUMP
        $dumpfile("tb_blink.vcd");
        $dumpvars(0, tb_blink);
`endif
        repeat (3) @(negedge clk);
        rst_n = 1'b1;
        @(negedge clk);

        chk("upper 5 LEDs off (high)", led[5:1] == 5'b11111);

        // BIT=2 -> led[0] flips every 4 clocks. Count edges over 32 clocks:
        // expect 8 toggles.
        toggles = 0;
        prev = led[0];
        for (i = 0; i < 32; i = i + 1) begin
            @(negedge clk);
            if (led[0] !== prev) toggles = toggles + 1;
            prev = led[0];
        end
        chk("led[0] toggled ~8x in 32 clk", toggles >= 7 && toggles <= 9);

        repeat (2) @(negedge clk);
        $display("----");
        $display("checks=%0d errors=%0d", checks, errors);
        if (errors == 0) $display("ALL TESTS PASSED");
        else             $display("TESTS FAILED");
        $finish;
    end

    initial begin
        #100000;
        $display("FAIL  timeout");
        $display("TESTS FAILED");
        $finish;
    end
endmodule
