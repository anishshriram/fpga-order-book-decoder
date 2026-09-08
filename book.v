// book.v -- live order book with constant-time lookup for the common case.
//
// Same 256-slot table as book_scan.v, but two changes remove the linear scans
// that dominate its latency:
//
//   1. A flip-flop CAM: every slot's order id lives in a register, so Delete
//      and Execute find their slot with a combinational match + priority
//      encode -- 1 clock, versus book_scan.v's ~770-clock walk. Add's free
//      slot comes from the same style of priority encode over ~valid.
//
//   2. order-count at the best price (`best_qty`): a removal only forces the
//      O(n) rescan when the entire top price level clears; every other
//      Delete/Execute is a fixed ~4 clocks.
//
// The {price, shares} payload stays in BSRAM. Semantics are identical to
// book_scan.v (lowest-index free slot / id match, remove at zero shares,
// best = max price over live slots); tb_book_equiv checks the two bit-for-bit
// and both against tools/reference_book.py.
//
// Synthesizable constructs only.

`timescale 1ns/1ps

module book #(
    parameter N  = 256,
    parameter AW = 8
) (
    input  wire        clk,
    input  wire        rst,

    input  wire        ev_valid,
    input  wire [7:0]  ev_type,      // 0x41 'A' / 0x44 'D' / 0x45 'E'
    input  wire [15:0] ev_id,
    input  wire [31:0] ev_price,
    input  wire [31:0] ev_shares,

    output reg  [31:0] best_bid,
    output reg  [15:0] order_count,
    output wire        busy
);
    localparam [7:0] T_ADD = 8'h41, T_DEL = 8'h44, T_EXE = 8'h45;

    localparam [2:0] S_IDLE = 3'd0, S_DISP = 3'd1, S_RD = 3'd2, S_CMP = 3'd3,
                     S_RESC_ADDR = 3'd4, S_RESC_RD = 3'd5, S_RESC_CMP = 3'd6,
                     S_DONE = 3'd7;
    reg [2:0] state;
    assign busy = (state != S_IDLE);

    reg [7:0]  h_type;
    reg [15:0] h_id;
    reg [31:0] h_price;
    reg [31:0] h_shares;

    // ---- flip-flop CAM: order id + valid for every slot ------------
    reg [N-1:0] vld;
    (* mem2reg *) reg [15:0] oid [0:N-1];   // all read in parallel -> real FFs

    // ---- BSRAM payload: {price[31:0], shares[31:0]} ---------------
    reg [63:0]  mem [0:N-1];
    reg [63:0]  mem_rdata;
    reg [AW-1:0] rd_addr;
    reg          we;
    reg [AW-1:0] wr_addr;
    reg [63:0]   wr_data;
    wire [31:0] rd_price = mem_rdata[63:32];
    wire [31:0] rd_shr   = mem_rdata[31:0];

    always @(posedge clk) begin
        mem_rdata <= mem[rd_addr];
        if (we) mem[wr_addr] <= wr_data;
    end

    // ---- combinational free slot / id match ----------------------
    integer k;
    reg [AW-1:0] free_idx, hit_idx;
    reg          free_ok,  hit_ok;
    always @* begin
        free_idx = {AW{1'b0}}; free_ok = 1'b0;
        hit_idx  = {AW{1'b0}}; hit_ok  = 1'b0;
        for (k = N-1; k >= 0; k = k - 1) begin
            if (!vld[k])                  begin free_idx = k[AW-1:0]; free_ok = 1'b1; end
            if (vld[k] && oid[k] == h_id) begin hit_idx  = k[AW-1:0]; hit_ok  = 1'b1; end
        end
    end

    // ---- rescan bookkeeping (only used when the top level clears) --
    reg [AW:0]  resc_addr;
    reg [31:0]  resc_max;
    reg [16:0]  resc_qty;
    reg [16:0]  best_qty;      // live orders priced exactly at best_bid
    reg [AW-1:0] rm_idx;       // slot being removed (held across S_CMP)

    always @(posedge clk) begin
        if (rst) begin
            state       <= S_IDLE;
            vld         <= {N{1'b0}};
            best_bid    <= 32'd0;
            best_qty    <= 17'd0;
            order_count <= 16'd0;
            we          <= 1'b0;
        end else begin
            we <= 1'b0;

            case (state)
            S_IDLE: if (ev_valid) begin
                h_type   <= ev_type;
                h_id     <= ev_id;
                h_price  <= ev_price;
                h_shares <= ev_shares;
                state    <= S_DISP;
            end

            // -------- 1-clock dispatch --------------------------------
            S_DISP: begin
                if (h_type == T_ADD) begin
                    if (free_ok) begin
                        vld[free_idx] <= 1'b1;
                        oid[free_idx] <= h_id;
                        we      <= 1'b1;
                        wr_addr <= free_idx;
                        wr_data <= {h_price, h_shares};
                        order_count <= order_count + 16'd1;
                        if (h_price > best_bid) begin
                            best_bid <= h_price;
                            best_qty <= 17'd1;
                        end else if (h_price == best_bid) begin
                            best_qty <= best_qty + 17'd1;
                        end
                    end
                    state <= S_DONE;
                end else if (hit_ok) begin
                    rd_addr <= hit_idx;
                    rm_idx  <= hit_idx;
                    state   <= S_RD;
                end else begin
                    state <= S_DONE;          // id not present: no-op
                end
            end

            S_RD: state <= S_CMP;             // mem_rdata lands next clock

            // -------- act on the matched slot ------------------------
            S_CMP: begin
                if (h_type == T_EXE && rd_shr > h_shares) begin
                    // partial fill: order stays, best unchanged
                    we      <= 1'b1;
                    wr_addr <= rm_idx;
                    wr_data <= {rd_price, rd_shr - h_shares};
                    state   <= S_DONE;
                end else begin
                    // remove the order (Delete, or Execute to zero)
                    vld[rm_idx] <= 1'b0;
                    order_count <= order_count - 16'd1;
                    if (rd_price == best_bid) begin
                        if (best_qty > 17'd1) begin
                            best_qty <= best_qty - 17'd1;   // top level still has orders
                            state    <= S_DONE;
                        end else begin
                            resc_addr <= {(AW+1){1'b0}};    // top level emptied: rescan
                            resc_max  <= 32'd0;
                            resc_qty  <= 17'd0;
                            rd_addr   <= {AW{1'b0}};
                            state     <= S_RESC_ADDR;
                        end
                    end else begin
                        state <= S_DONE;
                    end
                end
            end

            // -------- O(n) rescan for the new best + its count -------
            S_RESC_ADDR: begin
                rd_addr <= resc_addr[AW-1:0];
                state   <= S_RESC_RD;
            end
            S_RESC_RD: state <= S_RESC_CMP;
            S_RESC_CMP: begin
                if (vld[resc_addr[AW-1:0]]) begin
                    if (rd_price > resc_max) begin
                        resc_max <= rd_price;
                        resc_qty <= 17'd1;
                    end else if (rd_price == resc_max) begin
                        resc_qty <= resc_qty + 17'd1;
                    end
                end
                if (resc_addr == N-1) begin
                    // fold in this last slot, then publish
                    if (vld[resc_addr[AW-1:0]] && rd_price > resc_max) begin
                        best_bid <= rd_price;
                        best_qty <= 17'd1;
                    end else if (vld[resc_addr[AW-1:0]] && rd_price == resc_max) begin
                        best_bid <= resc_max;
                        best_qty <= resc_qty + 17'd1;
                    end else begin
                        best_bid <= resc_max;
                        best_qty <= resc_qty;
                    end
                    state <= S_DONE;
                end else begin
                    resc_addr <= resc_addr + 1'b1;
                    state     <= S_RESC_ADDR;
                end
            end

            S_DONE:  state <= S_IDLE;
            default: state <= S_IDLE;
            endcase
        end
    end
endmodule
