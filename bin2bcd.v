// bin2bcd.v -- binary to packed BCD by double-dabble (shift + add-3).
//
// Sequential: assert `start` with `bin` held, wait `done`, read `bcd`
// (DIGITS nibbles, most-significant nibble in the high bits). Synthesizable --
// only shifts and adds, no division. Follow-on for a decimal dollars display;
// display.v still works standalone in hex.

`timescale 1ns/1ps

module bin2bcd #(
    parameter IN_W   = 32,
    parameter DIGITS = 10          // enough for a 32-bit value (4294967295)
) (
    input  wire                   clk,
    input  wire                   rst,
    input  wire                   start,
    input  wire [IN_W-1:0]        bin,
    output reg  [4*DIGITS-1:0]    bcd,
    output reg                    done
);
    localparam ST_IDLE  = 2'd0,
               ST_SHIFT = 2'd1,
               ST_DONE  = 2'd2;

    reg [1:0]              state;
    reg [IN_W-1:0]         sh;
    reg [4*DIGITS-1:0]     work;
    integer                cnt;
    integer                d;

    // combinational add-3 pass over every nibble of `work`
    reg [4*DIGITS-1:0] adj;
    always @* begin
        adj = work;
        for (d = 0; d < DIGITS; d = d + 1)
            if (adj[4*d +: 4] >= 4'd5)
                adj[4*d +: 4] = adj[4*d +: 4] + 4'd3;
    end

    always @(posedge clk) begin
        if (rst) begin
            state <= ST_IDLE;
            done  <= 1'b0;
            bcd   <= {4*DIGITS{1'b0}};
        end else begin
            case (state)
                ST_IDLE: begin
                    done <= 1'b0;
                    if (start) begin
                        work  <= {4*DIGITS{1'b0}};
                        sh    <= bin;
                        cnt   <= 0;
                        state <= ST_SHIFT;
                    end
                end
                ST_SHIFT: begin
                    // shift the top bit of sh into the low bit of the adjusted BCD
                    work <= {adj[4*DIGITS-2:0], sh[IN_W-1]};
                    sh   <= {sh[IN_W-2:0], 1'b0};
                    cnt  <= cnt + 1;
                    if (cnt == IN_W-1) state <= ST_DONE;
                end
                ST_DONE: begin
                    bcd   <= work;
                    done  <= 1'b1;
                    state <= ST_IDLE;
                end
                default: state <= ST_IDLE;
            endcase
        end
    end
endmodule
