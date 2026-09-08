// parser.v -- ITCH 5.0 byte stream -> decoded A/D/E events
//
// Byte counter + latched type register, `case` on the counter (NOT one state
// per byte). Multi-byte fields accumulate by shifting a byte in at a time.
//
// Decodes only Add ('A' 0x41), Delete ('D' 0x44), Order Executed ('E' 0x45).
// Every other ITCH 5.0 type is counted past by its length (msg_len LUT) and
// discarded -- no stall, no reset. A type not in the LUT is treated as length
// 1, i.e. that single byte is skipped and the parser resyncs on the next.
//
// Bid side only: an Add with buy/sell byte 'S' (0x53) is counted past but
// produces no event.
//
// Synthesizable constructs only: no initial, no #, no variable division.

`timescale 1ns/1ps

module parser (
    input  wire        clk,
    input  wire        rst,
    input  wire [7:0]  byte_in,
    input  wire        byte_valid,
    output reg         event_valid,   // one cycle per complete A/D/E message
    output reg  [7:0]  msg_type,
    output reg  [15:0] order_id,
    output reg  [31:0] price,          // valid for 'A' only
    output reg  [31:0] shares,         // valid for 'A' and 'E'
    output reg         is_buy          // valid for 'A' only
);

    // ITCH 5.0 message lengths, offsets from start of message, no length prefix.
    // Anything not listed -> 1 (skip one byte, resync).
    function [6:0] msg_len(input [7:0] t);
        case (t)
            8'h53: msg_len = 7'd12;  // 'S' System Event
            8'h52: msg_len = 7'd39;  // 'R' Stock Directory
            8'h48: msg_len = 7'd25;  // 'H' Stock Trading Action
            8'h59: msg_len = 7'd20;  // 'Y' Reg SHO Restriction
            8'h4C: msg_len = 7'd26;  // 'L' Market Participant Position
            8'h56: msg_len = 7'd35;  // 'V' MWCB Decline Level
            8'h57: msg_len = 7'd12;  // 'W' MWCB Status
            8'h4B: msg_len = 7'd28;  // 'K' IPO Quoting Period Update
            8'h4A: msg_len = 7'd35;  // 'J' LULD Auction Collar
            8'h68: msg_len = 7'd21;  // 'h' Operational Halt
            8'h41: msg_len = 7'd36;  // 'A' Add Order
            8'h46: msg_len = 7'd40;  // 'F' Add Order with MPID
            8'h45: msg_len = 7'd31;  // 'E' Order Executed
            8'h43: msg_len = 7'd36;  // 'C' Order Executed with Price
            8'h58: msg_len = 7'd23;  // 'X' Order Cancel
            8'h44: msg_len = 7'd19;  // 'D' Order Delete
            8'h55: msg_len = 7'd35;  // 'U' Order Replace
            8'h50: msg_len = 7'd44;  // 'P' Trade
            8'h51: msg_len = 7'd40;  // 'Q' Cross Trade
            8'h42: msg_len = 7'd19;  // 'B' Broken Trade
            8'h49: msg_len = 7'd50;  // 'I' NOII
            8'h4E: msg_len = 7'd20;  // 'N' RPII
            8'h4F: msg_len = 7'd48;  // 'O' DLCR
            default: msg_len = 7'd1;
        endcase
    endfunction

    localparam [7:0] T_ADD = 8'h41;
    localparam [7:0] T_DEL = 8'h44;
    localparam [7:0] T_EXE = 8'h45;
    localparam [7:0] SIDE_SELL = 8'h53;
    localparam [7:0] SIDE_BUY  = 8'h42;

    reg [6:0] offs;      // offset of the next incoming byte within the message
    reg [6:0] cur_len;   // expected length of the message in flight
    reg [7:0] cur_type;
    reg       drop;      // this message is a sell-side Add -> suppress event

    // On the type byte (offs==0) the newly-seen type/length take effect this
    // same cycle; otherwise use the latched registers.
    wire [7:0] eff_type = (offs == 7'd0) ? byte_in          : cur_type;
    wire [6:0] eff_len  = (offs == 7'd0) ? msg_len(byte_in) : cur_len;
    wire       last_byte = (offs == eff_len - 7'd1);

    always @(posedge clk) begin
        if (rst) begin
            event_valid <= 1'b0;
            msg_type    <= 8'd0;
            order_id    <= 16'd0;
            price       <= 32'd0;
            shares      <= 32'd0;
            is_buy      <= 1'b0;
            offs        <= 7'd0;
            cur_len     <= 7'd1;
            cur_type    <= 8'd0;
            drop        <= 1'b0;
        end else begin
            event_valid <= 1'b0;

            if (byte_valid) begin
                if (offs == 7'd0) begin
                    // message type byte
                    cur_type <= byte_in;
                    cur_len  <= msg_len(byte_in);
                    drop     <= 1'b0;
                end else begin
                    case (cur_type)
                        // ---- Add Order ------------------------------------
                        T_ADD: begin
                            if (offs >= 7'd11 && offs <= 7'd18)
                                order_id <= {order_id[7:0], byte_in};
                            if (offs == 7'd19) begin
                                is_buy <= (byte_in == SIDE_BUY);
                                if (byte_in == SIDE_SELL) drop <= 1'b1;
                            end
                            if (offs >= 7'd20 && offs <= 7'd23)
                                shares <= {shares[23:0], byte_in};
                            if (offs >= 7'd32 && offs <= 7'd35)
                                price <= {price[23:0], byte_in};
                        end
                        // ---- Delete Order -------------------------------
                        T_DEL: begin
                            if (offs >= 7'd11 && offs <= 7'd18)
                                order_id <= {order_id[7:0], byte_in};
                        end
                        // ---- Order Executed ----------------------------
                        T_EXE: begin
                            if (offs >= 7'd11 && offs <= 7'd18)
                                order_id <= {order_id[7:0], byte_in};
                            if (offs >= 7'd19 && offs <= 7'd22)
                                shares <= {shares[23:0], byte_in};
                            // offs 23..30 match number: discarded
                        end
                        default: ; // known-but-ignored or unknown: count past
                    endcase
                end

                if (last_byte) begin
                    offs <= 7'd0;
                    if ((eff_type == T_ADD && !drop) ||
                        eff_type == T_DEL || eff_type == T_EXE) begin
                        event_valid <= 1'b1;
                        msg_type    <= eff_type;
                    end
                end else begin
                    offs <= offs + 7'd1;
                end
            end
        end
    end

endmodule
