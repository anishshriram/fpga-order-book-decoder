// tb_uart.v -- self-checking testbench for uart_tx.v and readout.v.

`timescale 1ns/1ps

module tb_uart;
    localparam CLKP   = 20;                 // 20 ns clock
    localparam DIVC   = 10;                 // uart DIV (clocks per bit)
    localparam real BIT_NS = DIVC * CLKP;

    reg clk = 1'b0;
    reg rst = 1'b1;
    always #(CLKP/2) clk = ~clk;

    integer errors = 0;
    integer checks = 0;

    task chk(input [8*48:1] name, input cond);
        begin
            checks = checks + 1;
            if (cond) $display("PASS  %0s", name);
            else begin errors = errors + 1; $display("FAIL  %0s", name); end
        end
    endtask

    // ---- uart_tx under test ----------------------------------------
    reg  [7:0] tx_data = 8'd0;
    reg        tx_send = 1'b0;
    wire       tx_line;
    wire       tx_busy;

    uart_tx #(.CLK_HZ(1_000_000), .BAUD(100_000)) dut_tx (
        .clk(clk), .rst(rst), .data(tx_data), .send(tx_send),
        .tx(tx_line), .busy(tx_busy)
    );

    // ---- readout + its uart, chained ------------------------------
    reg  [31:0] ro_value = 32'd0;
    wire [7:0]  ro_data;
    wire        ro_send;
    wire        ro_line;
    wire        ro_busy;

    readout #(.CLK_HZ(1_000_000), .TICK_HZ(2_000)) dut_ro (   // tick every 500 clk
        .clk(clk), .rst(rst), .value(ro_value),
        .uart_data(ro_data), .uart_send(ro_send), .uart_busy(ro_busy)
    );
    uart_tx #(.CLK_HZ(1_000_000), .BAUD(100_000)) ro_uart (
        .clk(clk), .rst(rst), .data(ro_data), .send(ro_send),
        .tx(ro_line), .busy(ro_busy)
    );

    // ---- a UART receiver for the tb ------------------------------
    task uart_rx(input line_sel, output [7:0] b);
        integer k;
        reg sbit;
        begin
            // wait for the start-bit falling edge on the selected line
            if (line_sel) @(negedge ro_line); else @(negedge tx_line);
            #(BIT_NS * 1.5);                       // middle of bit 0
            for (k = 0; k < 8; k = k + 1) begin
                sbit = line_sel ? ro_line : tx_line;
                b[k] = sbit;
                #(BIT_NS);
            end
        end
    endtask

    reg [7:0] got;
    reg [7:0] cr_byte;
    reg [8*16:1] str;
    integer i;

    task send_tx(input [7:0] d);
        begin
            wait (tx_busy === 1'b0);
            @(negedge clk);
            tx_data = d; tx_send = 1'b1;
            @(negedge clk);
            tx_send = 1'b0;
        end
    endtask

    initial begin
`ifdef DUMP
        $dumpfile("tb_uart.vcd");
        $dumpvars(0, tb_uart);
`endif
        repeat (4) @(negedge clk);
        rst = 1'b0;
        @(negedge clk);

        chk("tx idle high", tx_line === 1'b1);

        // send 0xA5, read it back
        send_tx(8'hA5);
        uart_rx(1'b0, got);
        chk("uart_tx byte 0xA5", got === 8'hA5);

        // send 0x3C
        send_tx(8'h3C);
        uart_rx(1'b0, got);
        chk("uart_tx byte 0x3C", got === 8'h3C);

        // ---- readout: 1999900 -> "000199.9900" CR LF --------------
        ro_value = 32'd1999900;
        str = 0;
        cr_byte = 8'd0;
        for (i = 0; i < 13; i = i + 1) begin
            uart_rx(1'b1, got);
            if (i < 11)      str = (str << 8) | got;
            else if (i == 11) cr_byte = got;
        end
        $display("      readout string = '%s'", str);
        chk("readout formats dollars", str === "000199.9900");
        chk("readout ends CR LF", cr_byte === 8'h0D && got === 8'h0A);

        // a second value
        ro_value = 32'd1625500;
        str = 0;
        for (i = 0; i < 11; i = i + 1) begin uart_rx(1'b1, got); str = (str << 8) | got; end
        uart_rx(1'b1, got); uart_rx(1'b1, got);      // consume CR LF
        $display("      readout string = '%s'", str);
        chk("readout second value", str === "000162.5500");

        repeat (4) @(negedge clk);
        $display("----");
        $display("checks=%0d errors=%0d", checks, errors);
        if (errors == 0) $display("ALL TESTS PASSED");
        else             $display("TESTS FAILED");
        $finish;
    end

    initial begin
        #5_000_000;
        $display("FAIL  timeout");
        $display("TESTS FAILED");
        $finish;
    end
endmodule
