// display.v -- 4-digit 7-segment multiplex driver for the uxcell 5641BH
// (common anode, no driver IC).
//
// Divide the 27 MHz clock to ~1 kHz per-digit refresh, walk the 4 digits, map
// each nibble through a hex lookup. First version shows 4 hex nibbles of
// `value`; wire bin2bcd ahead of it for decimal later.
//
// Common anode: an[d] HIGH enables digit d; seg[k] LOW lights segment k.
// seg bit order = {dp, g, f, e, d, c, b, a}.
//
// NOTE (hardware): with common-anode multiplexing the active anode sources the
// sum of all lit segment currents (up to ~48 mA), which exceeds a single GW2A
// pin. Drive the anodes through PNP/P-MOSFET high-side switches on real
// hardware -- see SPEC.md Phase 4 notes.

`timescale 1ns/1ps

module display #(
    parameter CLK_HZ    = 27_000_000,
    parameter REFRESH_HZ = 1000            // full 4-digit sweep rate
) (
    input  wire        clk,
    input  wire        rst,
    input  wire [15:0] value,
    output reg  [7:0]  seg,
    output reg  [3:0]  an
);
    localparam integer DIV = (CLK_HZ) / (REFRESH_HZ * 4);
    localparam integer DW  = (DIV <= 2) ? 1 : $clog2(DIV);
    localparam [DW-1:0] DIVM = DIV[DW-1:0] - 1'b1;

    reg [DW-1:0] divcnt;
    reg [1:0]    idx;

    always @(posedge clk) begin
        if (rst) begin
            divcnt <= {DW{1'b0}};
            idx    <= 2'd0;
        end else if (divcnt == DIVM) begin
            divcnt <= {DW{1'b0}};
            idx    <= idx + 2'd1;
        end else begin
            divcnt <= divcnt + 1'b1;
        end
    end

    reg [3:0] nib;
    always @* begin
        case (idx)
            2'd0: nib = value[3:0];
            2'd1: nib = value[7:4];
            2'd2: nib = value[11:8];
            2'd3: nib = value[15:12];
        endcase
    end

    // hex digit -> {dp,g,f,e,d,c,b,a}, active low (0 = lit)
    function [7:0] seg7(input [3:0] n);
        case (n)
            4'h0: seg7 = 8'b1100_0000;
            4'h1: seg7 = 8'b1111_1001;
            4'h2: seg7 = 8'b1010_0100;
            4'h3: seg7 = 8'b1011_0000;
            4'h4: seg7 = 8'b1001_1001;
            4'h5: seg7 = 8'b1001_0010;
            4'h6: seg7 = 8'b1000_0010;
            4'h7: seg7 = 8'b1111_1000;
            4'h8: seg7 = 8'b1000_0000;
            4'h9: seg7 = 8'b1001_0000;
            4'hA: seg7 = 8'b1000_1000;
            4'hB: seg7 = 8'b1000_0011;
            4'hC: seg7 = 8'b1100_0110;
            4'hD: seg7 = 8'b1010_0001;
            4'hE: seg7 = 8'b1000_0110;
            4'hF: seg7 = 8'b1000_1110;
        endcase
    endfunction

    always @* begin
        seg = seg7(nib);
        an  = 4'b0001 << idx;
    end
endmodule
