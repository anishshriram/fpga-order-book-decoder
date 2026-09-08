// readout.v -- periodically transmit `value` (price in 1/10000 dollar) over
// UART as ASCII "DDDDDD.DDDD\r\n", e.g. 1999900 -> "000199.9900".
//
// ~10 transmissions per second. Uses bin2bcd for the digits and uart_tx for
// the line. Synthesizable only.

`timescale 1ns/1ps

module readout #(
    parameter CLK_HZ  = 27_000_000,
    parameter TICK_HZ = 10
) (
    input  wire        clk,
    input  wire        rst,
    input  wire [31:0] value,

    output reg  [7:0]  uart_data,
    output reg         uart_send,
    input  wire        uart_busy
);
    localparam integer TDIV = CLK_HZ / TICK_HZ;
    localparam integer TW   = $clog2(TDIV);
    localparam integer LEN  = 13;

    reg [TW-1:0] tickcnt;
    wire tick = (tickcnt == TDIV[TW-1:0] - 1'b1);
    always @(posedge clk)
        tickcnt <= (rst || tick) ? {TW{1'b0}} : tickcnt + 1'b1;

    // bin2bcd instance
    reg  [31:0] val;
    reg         bcd_start;
    wire [39:0] bcd;
    wire        bcd_done;
    bin2bcd #(.IN_W(32), .DIGITS(10)) u_bcd (
        .clk(clk), .rst(rst), .start(bcd_start), .bin(val),
        .bcd(bcd), .done(bcd_done)
    );

    function [7:0] msgbyte(input [3:0] idx);
        case (idx)
            4'd0:  msgbyte = 8'h30 + bcd[39:36];
            4'd1:  msgbyte = 8'h30 + bcd[35:32];
            4'd2:  msgbyte = 8'h30 + bcd[31:28];
            4'd3:  msgbyte = 8'h30 + bcd[27:24];
            4'd4:  msgbyte = 8'h30 + bcd[23:20];
            4'd5:  msgbyte = 8'h30 + bcd[19:16];
            4'd6:  msgbyte = 8'h2E;                 // '.'
            4'd7:  msgbyte = 8'h30 + bcd[15:12];
            4'd8:  msgbyte = 8'h30 + bcd[11:8];
            4'd9:  msgbyte = 8'h30 + bcd[7:4];
            4'd10: msgbyte = 8'h30 + bcd[3:0];
            4'd11: msgbyte = 8'h0D;                 // '\r'
            default: msgbyte = 8'h0A;               // '\n'
        endcase
    endfunction

    localparam [1:0] S_WAIT = 2'd0, S_CONV = 2'd1, S_SEND = 2'd2, S_HOLD = 2'd3;
    reg [1:0] state;
    reg [3:0] idx;

    always @(posedge clk) begin
        if (rst) begin
            state     <= S_WAIT;
            bcd_start <= 1'b0;
            uart_send <= 1'b0;
            uart_data <= 8'd0;
            idx       <= 4'd0;
        end else begin
            bcd_start <= 1'b0;
            uart_send <= 1'b0;
            case (state)
                S_WAIT: if (tick) begin
                    val       <= value;
                    bcd_start <= 1'b1;
                    state     <= S_CONV;
                end
                S_CONV: if (bcd_done) begin
                    idx   <= 4'd0;
                    state <= S_SEND;
                end
                S_SEND: if (!uart_busy) begin
                    uart_data <= msgbyte(idx);
                    uart_send <= 1'b1;
                    state     <= S_HOLD;
                end
                S_HOLD: begin
                    if (idx == LEN - 1) state <= S_WAIT;
                    else begin
                        idx   <= idx + 4'd1;
                        state <= S_SEND;
                    end
                end
            endcase
        end
    end
endmodule
