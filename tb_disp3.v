// tb_disp3.v -- self-checking test for disp3.v (7-seg name/price/count format).

`timescale 1ns/1ps

module tb_disp3;
    reg         clk = 1'b0;
    reg         rst = 1'b1;
    reg  [31:0] name;
    reg  [31:0] best_bid;
    reg  [15:0] order_count;
    wire [95:0] patt;

    disp3 dut (.clk(clk), .rst(rst), .name(name), .best_bid(best_bid),
               .order_count(order_count), .patt(patt));

    always #5 clk = ~clk;

    integer errors = 0, checks = 0;
    task chk(input [8*32:1] nm, input [7:0] got, input [7:0] exp);
        begin
            checks = checks + 1;
            if (got === exp) $display("PASS  %0s = %0d", nm, got);
            else begin errors = errors + 1;
                $display("FAIL  %0s = %0d  exp %0d", nm, got, exp); end
        end
    endtask

    // segment patterns (active-high a=1..g=64,dp=128)
    localparam SA=119, SP=115, SL=56;              // A P L
    localparam D1=6, D2=91, D6=125, D7=7, D0=63;

    initial begin
        name        = "AAPL";
        best_bid    = 32'd1627500;                 // $162.7500
        order_count = 16'd67;
        repeat (4) @(negedge clk);
        rst = 1'b0;
        repeat (120) @(negedge clk);               // let the shared bin2bcd settle

        // name -> digits 0..3  (patt bytes 0..3)
        chk("name0 'A'", patt[7:0],    SA);
        chk("name1 'A'", patt[15:8],   SA);
        chk("name2 'P'", patt[23:16],  SP);
        chk("name3 'L'", patt[31:24],  SL);

        // price 162.7 -> digits 4..7 (patt bytes 4..7), dp on byte 6
        chk("price0 '1'", patt[39:32], D1);
        chk("price1 '6'", patt[47:40], D6);
        chk("price2 '2.'", patt[55:48], D2 | 8'h80);
        chk("price3 '7'", patt[63:56], D7);

        // count 67 -> digits 8..11: blank blank 6 7
        chk("cnt0 blank", patt[71:64], 8'd0);
        chk("cnt1 blank", patt[79:72], 8'd0);
        chk("cnt2 '6'",   patt[87:80], D6);
        chk("cnt3 '7'",   patt[95:88], D7);

        // a lower price to exercise the count-blanking with 3 digits
        order_count = 16'd128;
        repeat (120) @(negedge clk);
        chk("cnt 128 -> '1'", patt[79:72], D1);
        chk("cnt 128 -> '2'", patt[87:80], D2);
        chk("cnt 128 -> '8'", patt[95:88], 8'd127);

        $display("----");
        $display("checks=%0d errors=%0d", checks, errors);
        if (errors == 0) $display("ALL TESTS PASSED");
        else             $display("TESTS FAILED");
        $finish;
    end

    initial begin
        #200000;
        $display("FAIL  timeout");
        $display("TESTS FAILED");
        $finish;
    end
endmodule
