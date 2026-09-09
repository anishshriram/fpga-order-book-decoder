// sseg12.v -- multiplex driver for three 4-digit common-anode 7-segment
// displays (CL5641BH) sharing one 8-bit segment bus.
//
//   patt : 12 bytes, one per digit (digits 0-3 = left display, 4-7 = middle,
//          8-11 = right).  Each byte is the active-high segment pattern
//          a=0x01 b=0x02 c=0x04 d=0x08 e=0x10 f=0x20 g=0x40 dp=0x80.
//   seg  : segment cathodes, ACTIVE LOW (common anode: 0 = lit).
//   dig  : digit-select, ACTIVE LOW one-cold, drives a PNP high-side switch
//          per digit (FPGA pin low -> base current -> PNP on -> anode = 3V3).
//
// One digit lit at a time, each refreshed ~1 kHz.  Synthesizable only.

`timescale 1ns/1ps

module sseg12 #(
    parameter CLK_HZ = 27_000_000,
    parameter NDIG   = 12               // 12 = three displays, 8 = two
) (
    input  wire            clk,
    input  wire            rst,
    input  wire [95:0]     patt,
    output reg  [7:0]      seg,
    output reg  [NDIG-1:0] dig
);
    localparam integer DIV = CLK_HZ / (1000 * NDIG);    // ~1 kHz per digit
    localparam integer DW  = (DIV <= 2) ? 1 : $clog2(DIV);
    localparam [DW-1:0] DIVM = DIV[DW-1:0] - 1'b1;

    reg [DW-1:0] dv;
    reg [3:0]    idx;

    always @(posedge clk) begin
        if (rst) begin
            dv  <= {DW{1'b0}};
            idx <= 4'd0;
        end else if (dv == DIVM) begin
            dv  <= {DW{1'b0}};
            idx <= (idx == NDIG - 1) ? 4'd0 : idx + 4'd1;
        end else begin
            dv <= dv + 1'b1;
        end
    end

    reg [7:0] p;
    always @* begin
        case (idx)
            4'd0:  p = patt[7:0];      4'd1:  p = patt[15:8];
            4'd2:  p = patt[23:16];    4'd3:  p = patt[31:24];
            4'd4:  p = patt[39:32];    4'd5:  p = patt[47:40];
            4'd6:  p = patt[55:48];    4'd7:  p = patt[63:56];
            4'd8:  p = patt[71:64];    4'd9:  p = patt[79:72];
            4'd10: p = patt[87:80];    default: p = patt[95:88];
        endcase
        seg = ~p;                                       // common anode
        dig = ~({{(NDIG-1){1'b0}}, 1'b1} << idx);        // active-low one-cold
    end
endmodule
