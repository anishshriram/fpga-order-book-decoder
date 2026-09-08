// readout.v -- transmit the order book state over UART.
//
// Default build: poll `value` ~10x/s and send "DDDDDD.DDDD\r\n" dollars.
//
// -DANIMATE build: event-driven. On every `ev_stb` (one message finished
// processing) send one fixed-width line for tools/viz.py:
//
//     DDDDDDDD CCC T\n
//
//   DDDDDDDD  best bid in 1/10000 dollar, 8 digits zero-padded
//   CCC       resting order count, 3 digits zero-padded
//   T         'A' / 'D' / 'E'  (ev_type is already ASCII)
//
// Synthesizable only.

`timescale 1ns/1ps

module readout #(
    parameter CLK_HZ  = 27_000_000,
    parameter TICK_HZ = 10
) (
    input  wire        clk,
    input  wire        rst,
    input  wire [31:0] value,        // best bid

    input  wire        ev_stb,       // -DANIMATE: one pulse per processed msg
    input  wire [7:0]  ev_type,      // -DANIMATE: 'A'/'D'/'E'
    input  wire [15:0] order_count,  // -DANIMATE: resting orders

    output reg  [7:0]  uart_data,
    output reg         uart_send,
    input  wire        uart_busy
);
    // shared bin2bcd
    reg  [31:0] val;
    reg         bcd_start;
    wire [39:0] bcd;
    wire        bcd_done;
    bin2bcd #(.IN_W(32), .DIGITS(10)) u_bcd (
        .clk(clk), .rst(rst), .start(bcd_start), .bin(val),
        .bcd(bcd), .done(bcd_done)
    );

`ifdef ANIMATE
    // ------------------------------------------------------------------
    //  event-driven line: "DDDDDDDD CCC T\n"   (15 bytes)
    // ------------------------------------------------------------------
    localparam LEN = 15;
    localparam [2:0] S_IDLE = 0, S_CB = 1, S_CC = 2, S_SEND = 3, S_HOLD = 4;
    reg [2:0]  state;
    reg [3:0]  idx;
    reg [39:0] best_dig, cnt_dig;
    reg [7:0]  type_c;

    function [7:0] linebyte(input [3:0] i);
        case (i)                                           // low 8 decimal digits
            4'd0:  linebyte = 8'h30 + best_dig[31:28];
            4'd1:  linebyte = 8'h30 + best_dig[27:24];
            4'd2:  linebyte = 8'h30 + best_dig[23:20];
            4'd3:  linebyte = 8'h30 + best_dig[19:16];
            4'd4:  linebyte = 8'h30 + best_dig[15:12];
            4'd5:  linebyte = 8'h30 + best_dig[11:8];
            4'd6:  linebyte = 8'h30 + best_dig[7:4];
            4'd7:  linebyte = 8'h30 + best_dig[3:0];
            4'd8:  linebyte = 8'h20;                       // ' '
            4'd9:  linebyte = 8'h30 + cnt_dig[11:8];
            4'd10: linebyte = 8'h30 + cnt_dig[7:4];
            4'd11: linebyte = 8'h30 + cnt_dig[3:0];
            4'd12: linebyte = 8'h20;                       // ' '
            4'd13: linebyte = type_c;
            default: linebyte = 8'h0A;                     // '\n'
        endcase
    endfunction

    always @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE; bcd_start <= 1'b0;
            uart_send <= 1'b0; uart_data <= 8'd0; idx <= 4'd0;
        end else begin
            bcd_start <= 1'b0;
            uart_send <= 1'b0;
            case (state)
                S_IDLE: if (ev_stb) begin
                    val       <= value;
                    type_c    <= ev_type;
                    bcd_start <= 1'b1;
                    state     <= S_CB;
                end
                S_CB: if (bcd_done) begin
                    best_dig  <= bcd;
                    val       <= {16'd0, order_count};
                    bcd_start <= 1'b1;
                    state     <= S_CC;
                end
                S_CC: if (bcd_done) begin
                    cnt_dig <= bcd;
                    idx     <= 4'd0;
                    state   <= S_SEND;
                end
                S_SEND: if (!uart_busy) begin
                    uart_data <= linebyte(idx);
                    uart_send <= 1'b1;
                    state     <= S_HOLD;
                end
                S_HOLD: begin
                    if (idx == LEN - 1) state <= S_IDLE;
                    else begin idx <= idx + 4'd1; state <= S_SEND; end
                end
                default: state <= S_IDLE;
            endcase
        end
    end

`else
    // ------------------------------------------------------------------
    //  polled dollars: "DDDDDD.DDDD\r\n"   (13 bytes)
    // ------------------------------------------------------------------
    localparam integer TDIV = CLK_HZ / TICK_HZ;
    localparam integer TW   = $clog2(TDIV);
    localparam LEN = 13;

    reg [TW-1:0] tickcnt;
    wire tick = (tickcnt == TDIV[TW-1:0] - 1'b1);
    always @(posedge clk)
        tickcnt <= (rst || tick) ? {TW{1'b0}} : tickcnt + 1'b1;

    function [7:0] msgbyte(input [3:0] i);
        case (i)
            4'd0:  msgbyte = 8'h30 + bcd[39:36];
            4'd1:  msgbyte = 8'h30 + bcd[35:32];
            4'd2:  msgbyte = 8'h30 + bcd[31:28];
            4'd3:  msgbyte = 8'h30 + bcd[27:24];
            4'd4:  msgbyte = 8'h30 + bcd[23:20];
            4'd5:  msgbyte = 8'h30 + bcd[19:16];
            4'd6:  msgbyte = 8'h2E;
            4'd7:  msgbyte = 8'h30 + bcd[15:12];
            4'd8:  msgbyte = 8'h30 + bcd[11:8];
            4'd9:  msgbyte = 8'h30 + bcd[7:4];
            4'd10: msgbyte = 8'h30 + bcd[3:0];
            4'd11: msgbyte = 8'h0D;
            default: msgbyte = 8'h0A;
        endcase
    endfunction

    localparam [1:0] S_WAIT = 0, S_CONV = 1, S_SEND = 2, S_HOLD = 3;
    reg [1:0] state;
    reg [3:0] idx;

    always @(posedge clk) begin
        if (rst) begin
            state <= S_WAIT; bcd_start <= 1'b0;
            uart_send <= 1'b0; uart_data <= 8'd0; idx <= 4'd0;
        end else begin
            bcd_start <= 1'b0;
            uart_send <= 1'b0;
            case (state)
                S_WAIT: if (tick) begin val <= value; bcd_start <= 1'b1; state <= S_CONV; end
                S_CONV: if (bcd_done) begin idx <= 4'd0; state <= S_SEND; end
                S_SEND: if (!uart_busy) begin
                    uart_data <= msgbyte(idx); uart_send <= 1'b1; state <= S_HOLD;
                end
                S_HOLD: begin
                    if (idx == LEN - 1) state <= S_WAIT;
                    else begin idx <= idx + 4'd1; state <= S_SEND; end
                end
            endcase
        end
    end
`endif
endmodule
