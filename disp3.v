// disp3.v -- format the book state for the three 7-segment displays.
//
//   left   (digits 0-3)  : ticker name, 4 chars (static, from feed.vh)
//   middle (digits 4-7)  : best bid as  DDD.D  dollars  (< $1000)
//   right  (digits 8-11) : resting order count, right-aligned, leading blanks
//
// Emits the 96-bit segment-pattern bus for sseg12. A single bin2bcd is shared
// between the price and the count. Synthesizable only.

`timescale 1ns/1ps

module disp3 (
    input  wire        clk,
    input  wire        rst,
    input  wire [31:0] name,          // 4 ASCII chars, char 0 = MSB
    input  wire [31:0] best_bid,      // 1/10000 dollar
    input  wire [15:0] order_count,
    output wire [95:0] patt
);
    // ---- ASCII / nibble -> 7-seg pattern (active high a..g,dp) -------
    function [7:0] d2seg(input [3:0] n);   // decimal digit
        case (n)
            4'd0: d2seg = 8'd63;  4'd1: d2seg = 8'd6;   4'd2: d2seg = 8'd91;
            4'd3: d2seg = 8'd79;  4'd4: d2seg = 8'd102; 4'd5: d2seg = 8'd109;
            4'd6: d2seg = 8'd125; 4'd7: d2seg = 8'd7;   4'd8: d2seg = 8'd127;
            default: d2seg = 8'd111;
        endcase
    endfunction

    function [7:0] a2seg(input [7:0] c);   // ASCII letter/space -> best effort
        case (c)
            "0": a2seg = 8'd63;   "1": a2seg = 8'd6;    "2": a2seg = 8'd91;
            "3": a2seg = 8'd79;   "4": a2seg = 8'd102;  "5": a2seg = 8'd109;
            "6": a2seg = 8'd125;  "7": a2seg = 8'd7;    "8": a2seg = 8'd127;
            "9": a2seg = 8'd111;
            "A": a2seg = 8'd119;  "B": a2seg = 8'd124;  "C": a2seg = 8'd57;
            "D": a2seg = 8'd94;   "E": a2seg = 8'd121;  "F": a2seg = 8'd113;
            "G": a2seg = 8'd61;   "H": a2seg = 8'd118;  "I": a2seg = 8'd48;
            "J": a2seg = 8'd14;   "L": a2seg = 8'd56;   "N": a2seg = 8'd84;
            "O": a2seg = 8'd63;   "P": a2seg = 8'd115;  "Q": a2seg = 8'd103;
            "R": a2seg = 8'd80;   "S": a2seg = 8'd109;  "T": a2seg = 8'd120;
            "U": a2seg = 8'd62;   "V": a2seg = 8'd62;   "Y": a2seg = 8'd110;
            "Z": a2seg = 8'd91;
            "K": a2seg = 8'd118;  "M": a2seg = 8'd84;   "W": a2seg = 8'd62;
            "X": a2seg = 8'd118;  "-": a2seg = 8'd64;
            default: a2seg = 8'd0;                              // blank
        endcase
    endfunction

    // ---- shared bin2bcd -------------------------------------------
    reg  [31:0] bin;
    reg         start;
    wire [39:0] bcd;
    wire        done;
    bin2bcd #(.IN_W(32), .DIGITS(10)) u_bcd (
        .clk(clk), .rst(rst), .start(start), .bin(bin), .bcd(bcd), .done(done)
    );

    reg [39:0] price_bcd, cnt_bcd;
    reg [1:0]  st;
    localparam P_START = 2'd0, P_WAIT = 2'd1, C_START = 2'd2, C_WAIT = 2'd3;

    always @(posedge clk) begin
        if (rst) begin
            st <= P_START; start <= 1'b0; price_bcd <= 40'd0; cnt_bcd <= 40'd0;
        end else begin
            start <= 1'b0;
            case (st)
                P_START: begin bin <= best_bid;            start <= 1'b1; st <= P_WAIT; end
                P_WAIT:  if (done) begin price_bcd <= bcd;                st <= C_START; end
                C_START: begin bin <= {16'd0, order_count}; start <= 1'b1; st <= C_WAIT; end
                C_WAIT:  if (done) begin cnt_bcd <= bcd;                  st <= P_START; end
            endcase
        end
    end

    // ---- assemble the 12 digit patterns --------------------------
    // price digits: price_bcd nibbles d6 d5 d4 . d3   ->  "162.7"
    wire [3:0] pd6 = price_bcd[27:24];
    wire [3:0] pd5 = price_bcd[23:20];
    wire [3:0] pd4 = price_bcd[19:16];
    wire [3:0] pd3 = price_bcd[15:12];
    // count digits d2 d1 d0, blank leading zeros
    wire [3:0] cd2 = cnt_bcd[11:8];
    wire [3:0] cd1 = cnt_bcd[7:4];
    wire [3:0] cd0 = cnt_bcd[3:0];

    wire [7:0] name0 = a2seg(name[31:24]);
    wire [7:0] name1 = a2seg(name[23:16]);
    wire [7:0] name2 = a2seg(name[15:8]);
    wire [7:0] name3 = a2seg(name[7:0]);

    wire [7:0] price0 = d2seg(pd6);
    wire [7:0] price1 = d2seg(pd5);
    wire [7:0] price2 = d2seg(pd4) | 8'h80;             // decimal point here
    wire [7:0] price3 = d2seg(pd3);

    wire [7:0] cnt0 = 8'd0;                             // always blank (< 1000)
    wire [7:0] cnt1 = (cd2 == 4'd0) ? 8'd0 : d2seg(cd2);
    wire [7:0] cnt2 = (cd2 == 4'd0 && cd1 == 4'd0) ? 8'd0 : d2seg(cd1);
    wire [7:0] cnt3 = d2seg(cd0);

    assign patt = { cnt3, cnt2, cnt1, cnt0,
                    price3, price2, price1, price0,
                    name3, name2, name1, name0 };
endmodule
