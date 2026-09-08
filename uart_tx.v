// uart_tx.v -- 8N1 UART transmitter.
//
// Pulse `send` (one cycle) with `data` held to queue a byte; ignored while
// `busy`. Idle line is high. Synthesizable only.

`timescale 1ns/1ps

module uart_tx #(
    parameter CLK_HZ = 27_000_000,
    parameter BAUD   = 115200
) (
    input  wire       clk,
    input  wire       rst,
    input  wire [7:0] data,
    input  wire       send,
    output reg        tx,
    output wire       busy
);
    localparam integer DIV = CLK_HZ / BAUD;
    localparam integer DW  = (DIV <= 2) ? 1 : $clog2(DIV);

    reg [DW-1:0] divcnt;
    reg [3:0]    bitidx;
    reg [9:0]    shreg;      // {stop, data[7:0], start}
    reg          active;

    assign busy = active;

    always @(posedge clk) begin
        if (rst) begin
            active <= 1'b0;
            divcnt <= {DW{1'b0}};
            bitidx <= 4'd0;
            shreg  <= 10'h3FF;
            tx     <= 1'b1;
        end else if (!active) begin
            tx <= 1'b1;
            if (send) begin
                shreg  <= {1'b1, data, 1'b0};
                active <= 1'b1;
                bitidx <= 4'd0;
                divcnt <= {DW{1'b0}};
            end
        end else begin
            tx <= shreg[0];
            if (divcnt == DIV[DW-1:0] - 1'b1) begin
                divcnt <= {DW{1'b0}};
                shreg  <= {1'b1, shreg[9:1]};
                if (bitidx == 4'd9) active <= 1'b0;
                else               bitidx <= bitidx + 4'd1;
            end else begin
                divcnt <= divcnt + 1'b1;
            end
        end
    end
endmodule
