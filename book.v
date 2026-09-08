// book.v -- live order book, exposes the current best bid.
//
// Storage: 256-entry table. valid bits live in flip-flops; the payload
// {order_id[15:0], price[31:0], shares[31:0]} lives in inferred BSRAM read
// with one cycle of latency. Every lookup is a linear scan driven by a small
// sub-FSM (set address -> absorb read latency -> compare -> step). Slow but
// correct, exactly as SPEC.md asks.
//
// Operations (parser has already dropped sell-side Adds):
//   A  write to the first free slot; if price > best, raise best
//   D  first slot with a matching id -> clear valid; if it held the best
//      price, rescan for the new maximum
//   E  first slot with a matching id -> shares -= executed; when shares reach
//      zero, remove it and handle exactly like D
//
// Synthesizable constructs only.

`timescale 1ns/1ps

module book (
    input  wire        clk,
    input  wire        rst,

    input  wire        ev_valid,     // sampled only while !busy
    input  wire [7:0]  ev_type,      // 0x41 'A' / 0x44 'D' / 0x45 'E'
    input  wire [15:0] ev_id,
    input  wire [31:0] ev_price,     // 'A'
    input  wire [31:0] ev_shares,    // 'A' add size / 'E' executed size

    output reg  [31:0] best_bid,
    output reg  [15:0] order_count,   // live count of resting orders
    output wire        busy
);

    localparam [7:0] T_ADD = 8'h41;
    localparam [7:0] T_DEL = 8'h44;
    localparam [7:0] T_EXE = 8'h45;

    // FSM
    localparam [3:0] S_IDLE       = 4'd0,
                     S_SCAN_ADDR  = 4'd1,
                     S_SCAN_RD    = 4'd2,
                     S_SCAN_CMP   = 4'd3,
                     S_RESC_ADDR  = 4'd4,
                     S_RESC_RD    = 4'd5,
                     S_RESC_CMP   = 4'd6,
                     S_DONE       = 4'd7;

    reg [3:0]  state;
    assign busy = (state != S_IDLE);

    // held request
    reg [7:0]  h_type;
    reg [15:0] h_id;
    reg [31:0] h_price;
    reg [31:0] h_shares;

    // table
    reg [255:0] slot_valid;
    reg [79:0]  mem [0:255];
    reg [79:0]  mem_rdata;
    reg [7:0]   rd_addr;

    wire [15:0] rd_id    = mem_rdata[79:64];
    wire [31:0] rd_price = mem_rdata[63:32];
    wire [31:0] rd_shr   = mem_rdata[31:0];

    reg [8:0]  scan_addr;   // 0..256 (256 == walked the whole table)
    reg [8:0]  resc_addr;
    reg [31:0] resc_max;

    // one shared BSRAM read/write port
    reg        we;
    reg [7:0]  wr_addr;
    reg [79:0] wr_data;

    integer j;

    always @(posedge clk) begin
        mem_rdata <= mem[rd_addr];
        if (we) mem[wr_addr] <= wr_data;
    end

    always @(posedge clk) begin
        if (rst) begin
            state      <= S_IDLE;
            best_bid   <= 32'd0;
            slot_valid <= 256'd0;
            we          <= 1'b0;
            rd_addr     <= 8'd0;
            scan_addr   <= 9'd0;
            resc_addr   <= 9'd0;
            resc_max    <= 32'd0;
            order_count <= 16'd0;
        end else begin
            we <= 1'b0;

            case (state)
            // ------------------------------------------------------------
            S_IDLE: begin
                if (ev_valid) begin
                    h_type    <= ev_type;
                    h_id      <= ev_id;
                    h_price   <= ev_price;
                    h_shares  <= ev_shares;
                    scan_addr <= 9'd0;
                    rd_addr   <= 8'd0;
                    state     <= S_SCAN_ADDR;
                end
            end

            // ---- linear scan: free slot (A) or id match (D/E) ----------
            S_SCAN_ADDR: begin
                rd_addr <= scan_addr[7:0];
                state   <= S_SCAN_RD;
            end
            S_SCAN_RD: begin
                state <= S_SCAN_CMP;      // mem_rdata <= mem[scan_addr] lands now
            end
            S_SCAN_CMP: begin
                if (scan_addr == 9'd256) begin
                    // walked the whole table without a hit: drop the event
                    state <= S_DONE;
                end else if (h_type == T_ADD) begin
                    if (!slot_valid[scan_addr[7:0]]) begin
                        slot_valid[scan_addr[7:0]] <= 1'b1;
                        we      <= 1'b1;
                        wr_addr <= scan_addr[7:0];
                        wr_data <= {h_id, h_price, h_shares};
                        if (h_price > best_bid) best_bid <= h_price;
                        order_count <= order_count + 16'd1;
                        state <= S_DONE;
                    end else begin
                        scan_addr <= scan_addr + 9'd1;
                        state     <= S_SCAN_ADDR;
                    end
                end else begin
                    // D / E : look for a valid slot with a matching id
                    if (slot_valid[scan_addr[7:0]] && rd_id == h_id) begin
                        if (h_type == T_DEL) begin
                            slot_valid[scan_addr[7:0]] <= 1'b0;
                            order_count <= order_count - 16'd1;
                            if (rd_price == best_bid) begin
                                resc_addr <= 9'd0;
                                resc_max  <= 32'd0;
                                rd_addr   <= 8'd0;
                                state     <= S_RESC_ADDR;
                            end else begin
                                state <= S_DONE;
                            end
                        end else begin
                            // T_EXE
                            if (rd_shr <= h_shares) begin
                                slot_valid[scan_addr[7:0]] <= 1'b0;
                                order_count <= order_count - 16'd1;
                                if (rd_price == best_bid) begin
                                    resc_addr <= 9'd0;
                                    resc_max  <= 32'd0;
                                    rd_addr   <= 8'd0;
                                    state     <= S_RESC_ADDR;
                                end else begin
                                    state <= S_DONE;
                                end
                            end else begin
                                we      <= 1'b1;
                                wr_addr <= scan_addr[7:0];
                                wr_data <= {rd_id, rd_price, rd_shr - h_shares};
                                state   <= S_DONE;
                            end
                        end
                    end else begin
                        scan_addr <= scan_addr + 9'd1;
                        state     <= S_SCAN_ADDR;
                    end
                end
            end

            // ---- full rescan for the new maximum price -----------------
            S_RESC_ADDR: begin
                rd_addr <= resc_addr[7:0];
                state   <= S_RESC_RD;
            end
            S_RESC_RD: begin
                state <= S_RESC_CMP;
            end
            S_RESC_CMP: begin
                if (slot_valid[resc_addr[7:0]] && rd_price > resc_max)
                    resc_max <= rd_price;

                if (resc_addr == 9'd255) begin
                    best_bid <= (slot_valid[resc_addr[7:0]] && rd_price > resc_max)
                                ? rd_price : resc_max;
                    state <= S_DONE;
                end else begin
                    resc_addr <= resc_addr + 9'd1;
                    state     <= S_RESC_ADDR;
                end
            end

            S_DONE: begin
                state <= S_IDLE;
            end

            default: state <= S_IDLE;
            endcase
        end
    end

endmodule
