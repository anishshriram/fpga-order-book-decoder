// tb_parser.v -- self-checking testbench for parser.v
// Prints per-check PASS/FAIL and a final verdict line. Waveforms are for
// debugging only (build with -DDUMP).

`timescale 1ns/1ps

module tb_parser;

    reg         clk = 1'b0;
    reg         rst = 1'b1;
    reg  [7:0]  byte_in = 8'd0;
    reg         byte_valid = 1'b0;

    wire        event_valid;
    wire [7:0]  msg_type;
    wire [15:0] order_id;
    wire [31:0] price;
    wire [31:0] shares;
    wire        is_buy;

    integer errors = 0;
    integer checks = 0;

    parser dut (
        .clk(clk), .rst(rst),
        .byte_in(byte_in), .byte_valid(byte_valid),
        .event_valid(event_valid), .msg_type(msg_type),
        .order_id(order_id), .price(price), .shares(shares), .is_buy(is_buy)
    );

    always #5 clk = ~clk;

    // ---- capture of the most recent event -------------------------------
    integer     ev_count = 0;
    reg [7:0]   ev_type;
    reg [15:0]  ev_id;
    reg [31:0]  ev_price;
    reg [31:0]  ev_shares;
    reg         ev_is_buy;

    always @(posedge clk) begin
        if (event_valid) begin
            ev_count  <= ev_count + 1;
            ev_type   <= msg_type;
            ev_id     <= order_id;
            ev_price  <= price;
            ev_shares <= shares;
            ev_is_buy <= is_buy;
        end
    end

    // ---- helpers -------------------------------------------------------
    task send_byte(input [7:0] b);
        begin
            @(negedge clk);
            byte_in    = b;
            byte_valid = 1'b1;
            @(negedge clk);
            byte_valid = 1'b0;
        end
    endtask

    integer i;

    task send_add(input [63:0] oref, input [7:0] side,
                  input [31:0] sh, input [31:0] pr);
        begin
            send_byte(8'h41);
            send_byte(8'h00); send_byte(8'h01);          // stock locate
            send_byte(8'h00); send_byte(8'h00);          // tracking
            for (i = 0; i < 6; i = i + 1) send_byte(8'h00);   // timestamp
            for (i = 0; i < 8; i = i + 1) send_byte(oref  >> (8*(7-i)));
            send_byte(side);
            for (i = 0; i < 4; i = i + 1) send_byte(sh   >> (8*(3-i)));
            for (i = 0; i < 8; i = i + 1) send_byte(8'h00);   // ticker
            for (i = 0; i < 4; i = i + 1) send_byte(pr   >> (8*(3-i)));
        end
    endtask

    task send_delete(input [63:0] oref);
        begin
            send_byte(8'h44);
            send_byte(8'h00); send_byte(8'h01);
            send_byte(8'h00); send_byte(8'h00);
            for (i = 0; i < 6; i = i + 1) send_byte(8'h00);
            for (i = 0; i < 8; i = i + 1) send_byte(oref >> (8*(7-i)));
        end
    endtask

    task send_execute(input [63:0] oref, input [31:0] exec_sh);
        begin
            send_byte(8'h45);
            send_byte(8'h00); send_byte(8'h01);
            send_byte(8'h00); send_byte(8'h00);
            for (i = 0; i < 6; i = i + 1) send_byte(8'h00);
            for (i = 0; i < 8; i = i + 1) send_byte(oref >> (8*(7-i)));
            for (i = 0; i < 4; i = i + 1) send_byte(exec_sh >> (8*(3-i)));
            for (i = 0; i < 8; i = i + 1) send_byte(8'h00);   // match number
        end
    endtask

    task send_sysevent;   // 'S' System Event, 12 bytes -- must be skipped
        begin
            send_byte(8'h53);
            send_byte(8'h00); send_byte(8'h00);
            send_byte(8'h00); send_byte(8'h00);
            for (i = 0; i < 6; i = i + 1) send_byte(8'h00);
            send_byte(8'h4F);                                 // event code 'O'
        end
    endtask

    task chk(input [8*40:1] name, input cond);
        begin
            checks = checks + 1;
            if (cond) $display("PASS  %0s", name);
            else begin errors = errors + 1; $display("FAIL  %0s", name); end
        end
    endtask

    // ---- stimulus ----------------------------------------------------
    initial begin
`ifdef DUMP
        $dumpfile("tb_parser.vcd");
        $dumpvars(0, tb_parser);
`endif
        repeat (4) @(negedge clk);
        rst = 1'b0;
        @(negedge clk);

        // 1) Add Order: price 1502500 ($150.25), 100 shares, oref low16 = 0x2345
        send_add(64'h0000_0000_0001_2345, 8'h42, 32'd100, 32'd1502500);
        @(posedge clk); #1;
        chk("A: one event so far",     ev_count == 1);
        chk("A: msg_type == 0x41",     ev_type  == 8'h41);
        chk("A: order_id == 0x2345",   ev_id    == 16'h2345);
        chk("A: price == 1502500",     ev_price == 32'd1502500);
        chk("A: shares == 100",        ev_shares== 32'd100);
        chk("A: is_buy == 1",          ev_is_buy== 1'b1);

        // 2) Delete Order: oref low16 = 0xABCD
        send_delete(64'h0000_0000_00FF_ABCD);
        @(posedge clk); #1;
        chk("D: two events so far",    ev_count == 2);
        chk("D: msg_type == 0x44",     ev_type  == 8'h44);
        chk("D: order_id == 0xABCD",   ev_id    == 16'hABCD);

        // 3) Order Executed: oref low16 = 0x5678, executed 25 shares
        send_execute(64'h1234_5678_9ABC_5678, 32'd25);
        @(posedge clk); #1;
        chk("E: three events so far",  ev_count == 3);
        chk("E: msg_type == 0x45",     ev_type  == 8'h45);
        chk("E: order_id == 0x5678",   ev_id    == 16'h5678);
        chk("E: shares == 25",         ev_shares== 32'd25);

        // 4) Unknown/ignored type (System Event) immediately followed by a
        //    valid Add -- parser must resync and decode the Add.
        send_sysevent;
        send_add(64'h0000_0000_0000_0007, 8'h42, 32'd42, 32'd900000);
        @(posedge clk); #1;
        chk("unknown+A: four events",  ev_count == 4);
        chk("unknown+A: id == 0x0007", ev_id    == 16'h0007);
        chk("unknown+A: price 900000", ev_price == 32'd900000);

        // 5) Sell-side Add -> discarded (no event), then a buy Add fires.
        send_add(64'h0000_0000_0000_0099, 8'h53, 32'd10, 32'd9999999);
        @(posedge clk); #1;
        chk("A/S: still four events",  ev_count == 4);
        send_add(64'h0000_0000_0000_0011, 8'h42, 32'd5, 32'd123456);
        @(posedge clk); #1;
        chk("buy after A/S: five ev",  ev_count == 5);
        chk("buy after A/S: id 0x11",  ev_id    == 16'h0011);
        chk("buy after A/S: is_buy",   ev_is_buy== 1'b1);

        repeat (4) @(negedge clk);
        $display("----");
        $display("checks=%0d errors=%0d", checks, errors);
        if (errors == 0) $display("ALL TESTS PASSED");
        else             $display("TESTS FAILED");
        $finish;
    end

    // safety timeout
    initial begin
        #200000;
        $display("FAIL  timeout");
        $display("TESTS FAILED");
        $finish;
    end

endmodule
