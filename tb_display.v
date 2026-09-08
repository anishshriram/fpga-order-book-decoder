// tb_display.v -- self-checking testbench for display.v and bin2bcd.v.
// Visual flicker / brightness is a hardware exit test; here we check the
// mechanically verifiable parts: refresh divider period, one-hot anode
// sweep, segment patterns, and the double-dabble conversion.

`timescale 1ns/1ps

module tb_display;
    reg         clk = 1'b0;
    reg         rst = 1'b1;
    reg  [15:0] value = 16'h0000;
    wire [7:0]  seg;
    wire [3:0]  an;

    integer errors = 0;
    integer checks = 0;

    // CLK_HZ/REFRESH chosen so DIV = 32000/(1000*4) = 8 clocks per digit
    display #(.CLK_HZ(32000), .REFRESH_HZ(1000)) dut (
        .clk(clk), .rst(rst), .value(value), .seg(seg), .an(an)
    );

    reg          bcd_start = 1'b0;
    reg  [31:0]  bcd_bin   = 32'd0;
    wire [39:0]  bcd_out;
    wire         bcd_done;
    bin2bcd #(.IN_W(32), .DIGITS(10)) b2b (
        .clk(clk), .rst(rst), .start(bcd_start), .bin(bcd_bin),
        .bcd(bcd_out), .done(bcd_done)
    );

    always #5 clk = ~clk;

    task chk(input [8*44:1] name, input cond);
        begin
            checks = checks + 1;
            if (cond) $display("PASS  %0s", name);
            else begin errors = errors + 1; $display("FAIL  %0s", name); end
        end
    endtask

    function [7:0] hseg(input [3:0] n);
        case (n)
            4'h0: hseg = 8'b1100_0000;
            4'h1: hseg = 8'b1111_1001;
            4'h2: hseg = 8'b1010_0100;
            4'h5: hseg = 8'b1001_0010;
            default: hseg = 8'hxx;
        endcase
    endfunction

    function is_onehot(input [3:0] v);
        is_onehot = (v == 4'b0001) || (v == 4'b0010) ||
                    (v == 4'b0100) || (v == 4'b1000);
    endfunction

    integer i, span;
    reg [3:0] seen;
    reg [3:0] an_prev;
    reg       onehot_ok;

    initial begin
`ifdef DUMP
        $dumpfile("tb_display.vcd");
        $dumpvars(0, tb_display);
`endif
        value = 16'h2510;               // digits 0..3 : 0, 1, 5, 2
        repeat (4) @(negedge clk);
        rst = 1'b0;

        // --- one-hot + all four anodes exercised over a full sweep ----
        seen = 4'b0000;
        onehot_ok = 1'b1;
        for (i = 0; i < 8*4 + 6; i = i + 1) begin
            @(negedge clk);
            if (!is_onehot(an)) onehot_ok = 1'b0;
            case (an)
                4'b0001: seen[0] = 1'b1;
                4'b0010: seen[1] = 1'b1;
                4'b0100: seen[2] = 1'b1;
                4'b1000: seen[3] = 1'b1;
            endcase
        end
        chk("anode always one-hot", onehot_ok);
        chk("all four anodes driven", seen == 4'b1111);

        // --- divider period: count anode transitions over 80 clocks.
        //     DIV = 8 -> idx advances every 8 clocks -> 10 transitions.
        an_prev = an;
        span = 0;
        for (i = 0; i < 80; i = i + 1) begin
            @(negedge clk);
            if (an !== an_prev) span = span + 1;
            an_prev = an;
        end
        chk("10 anode steps in 80 clk", span == 10);

        // --- segment pattern tracks the active digit -----------------
        wait (an === 4'b0001); @(negedge clk);
        chk("digit0 shows 0", seg === hseg(4'h0));
        wait (an === 4'b0010); @(negedge clk);
        chk("digit1 shows 1", seg === hseg(4'h1));
        wait (an === 4'b0100); @(negedge clk);
        chk("digit2 shows 5", seg === hseg(4'h5));
        wait (an === 4'b1000); @(negedge clk);
        chk("digit3 shows 2", seg === hseg(4'h2));

        // --- bin2bcd -------------------------------------------------
        run_bcd(32'd1502500);
        chk("bin2bcd(1502500)", bcd_out === 40'h00_0150_2500);
        run_bcd(32'd0);
        chk("bin2bcd(0)", bcd_out === 40'h00_0000_0000);
        run_bcd(32'd4294967295);
        chk("bin2bcd(2^32-1)", bcd_out === 40'h42_9496_7295);

        repeat (2) @(negedge clk);
        $display("----");
        $display("checks=%0d errors=%0d", checks, errors);
        if (errors == 0) $display("ALL TESTS PASSED");
        else             $display("TESTS FAILED");
        $finish;
    end

    task run_bcd(input [31:0] v);
        begin
            @(negedge clk);
            bcd_bin = v; bcd_start = 1'b1;
            @(negedge clk);
            bcd_start = 1'b0;
            wait (bcd_done === 1'b1);
            @(negedge clk);
        end
    endtask

    initial begin
        #500000;
        $display("FAIL  timeout");
        $display("TESTS FAILED");
        $finish;
    end
endmodule
