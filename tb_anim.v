// tb_anim.v -- self-checking test for the -DANIMATE telemetry line.
// Compile with -DANIMATE (see `make sim-anim`).

`timescale 1ns/1ps

module tb_anim;
    localparam CLKP = 20;
    localparam DIVC = 10;
    localparam real BIT_NS = DIVC * CLKP;

    reg clk = 1'b0;
    reg rst = 1'b1;
    always #(CLKP/2) clk = ~clk;

    integer errors = 0;

    reg  [31:0] value    = 32'd0;
    reg  [15:0] ocount   = 16'd0;
    reg  [7:0]  etype    = 8'h41;
    reg  [3:0]  esel     = 4'd0;
    reg         ev_stb   = 1'b0;
    wire [7:0]  ud;
    wire        us;
    wire        line;
    wire        ubusy;

    readout #(.CLK_HZ(1_000_000)) dut (
        .clk(clk), .rst(rst), .value(value),
        .ev_stb(ev_stb), .ev_type(etype), .ev_sel(esel), .order_count(ocount),
        .uart_data(ud), .uart_send(us), .uart_busy(ubusy)
    );
    uart_tx #(.CLK_HZ(1_000_000), .BAUD(100_000)) u (
        .clk(clk), .rst(rst), .data(ud), .send(us), .tx(line), .busy(ubusy)
    );

    task rx(output [7:0] b);
        integer k; reg s;
        begin
            @(negedge line);
            #(BIT_NS * 1.5);
            for (k = 0; k < 8; k = k + 1) begin s = line; b[k] = s; #(BIT_NS); end
        end
    endtask

    reg [8*24:1] got;
    reg [7:0]    c;
    integer      j;

    task expect_line(input [31:0] v, input [15:0] oc, input [7:0] t,
                     input [3:0] sel, input [8*20:1] want);
        begin
            @(negedge clk);
            value = v; ocount = oc; etype = t; esel = sel; ev_stb = 1'b1;
            @(negedge clk); ev_stb = 1'b0;
            got = 0;
            for (j = 0; j < 17; j = j + 1) begin
                rx(c);
                if (j < 16) got = (got << 8) | c;
            end
            $display("      line = '%s'  (last byte %02h)", got, c);
            if (got === want && c === 8'h0A) $display("PASS  %0s", want);
            else begin errors = errors + 1; $display("FAIL  got '%s' want '%s'", got, want); end
        end
    endtask

    initial begin
        repeat (4) @(negedge clk);
        rst = 1'b0;
        repeat (2) @(negedge clk);

        //            value      count  type   sel    expected "I DDDDDDDD CCC T"
        expect_line(32'd1625500, 16'd47,  8'h41, 4'd2, "2 01625500 047 A");
        expect_line(32'd0,       16'd0,   8'h44, 4'd0, "0 00000000 000 D");
        expect_line(32'd99999999,16'd256, 8'h45, 4'd3, "3 99999999 256 E");

        $display("----");
        if (errors == 0) $display("ALL TESTS PASSED");
        else             $display("TESTS FAILED");
        $finish;
    end

    initial begin
        #10_000_000;
        $display("FAIL  timeout");
        $display("TESTS FAILED");
        $finish;
    end
endmodule
