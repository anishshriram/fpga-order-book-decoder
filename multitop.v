// multitop.v -- four order books in parallel, one interleaved ITCH feed.
//
// tools/itch_to_hex.py --tickers AMD,MSFT,AAPL,NVDA emits one feed with all
// four stocks' A/D/E messages in timestamp order, each message's stock-locate
// field rewritten to its book index 0..3. The parser exposes that locate; a
// 2-bit select routes every decoded event to one of four book_scan instances.
//
// Per processed message the UART sends one telemetry line for tools/viz.py:
//
//     I DDDDDDDD CCC T\n
//
//   I         book index 0..3
//   DDDDDDDD  that book's best bid in 1/10000 dollar
//   CCC       that book's resting order count
//   T         'A' / 'D' / 'E'
//
// The feed is paced (~12 msg/s) and loops. Build with -DSIMPACE for a fast
// pace in simulation.

`timescale 1ns/1ps
`include "data/feed.vh"

module multitop (
    input  wire       clk,       // 27 MHz
    input  wire       rst_n,     // unused
    output wire [5:0] led,       // [3:0] per-book trade blink, [5:4] feed done
    output wire       uart_tx,   // pin 69 -> onboard FT2232 ch B
    output wire [7:0] dbg        // J6 header taps
);
    wire _u = rst_n;

    // power-on reset + feed-restart pulse (loop the feed forever)
    reg [3:0] por = 4'd0;
    always @(posedge clk) if (~por[3]) por <= por + 4'd1;
    wire rst = ~por[3];

    reg        done;
    reg [1:0]  rstate;
    reg [23:0] pcnt;
    localparam R_RUN = 2'd0, R_WAIT = 2'd1, R_RST = 2'd2;
    always @(posedge clk) begin
        if (rst) begin rstate <= R_RUN; pcnt <= 24'd0; end
        else case (rstate)
            R_RUN:  if (done) begin pcnt <= 24'd0; rstate <= R_WAIT; end
            R_WAIT: if (pcnt == 24'd13_500_000) begin pcnt <= 24'd0; rstate <= R_RST; end
                    else pcnt <= pcnt + 24'd1;                 // ~0.5 s gap
            R_RST:  if (pcnt == 24'd7) begin pcnt <= 24'd0; rstate <= R_RUN; end
                    else pcnt <= pcnt + 24'd1;
            default: rstate <= R_RUN;
        endcase
    end
    wire frst = rst | (rstate == R_RST);

    // ---- ROM + paced feeder -----------------------------------------
    localparam AW = 15;
    reg  [AW-1:0] addr;
    wire [7:0]    rom_data;
    rom #(.FILE("data/feed.hex"), .DEPTH(32768), .AW(AW)) u_rom (
        .clk(clk), .addr(addr), .data(rom_data)
    );

`ifdef SIMPACE
    localparam [23:0] MPACE = 24'd0;              // no wait -- fast sim
`else
    localparam [23:0] MPACE = 24'd2_250_000;      // ~12 messages / second
`endif
    reg [23:0] mp;
    reg        pacing;
    wire       any_busy;
    wire       msg_done;

    always @(posedge clk) begin
        if (frst) begin pacing <= 1'b0; mp <= 24'd0; end
        else if (msg_done) begin pacing <= 1'b1; mp <= 24'd0; end
        else if (pacing) begin
            if (mp >= MPACE) pacing <= 1'b0;
            else             mp <= mp + 24'd1;
        end
    end

    localparam F_FETCH = 1'b0, F_PRESENT = 1'b1;
    reg        fstate;
    reg  [7:0] byte_in;
    reg        byte_valid;

    always @(posedge clk) begin
        if (frst) begin
            addr <= {AW{1'b0}}; fstate <= F_FETCH;
            done <= 1'b0; byte_in <= 8'd0; byte_valid <= 1'b0;
        end else begin
            byte_valid <= 1'b0;
            case (fstate)
                F_FETCH: if (!done) fstate <= F_PRESENT;
                F_PRESENT: if (!any_busy && !pacing) begin
                    byte_in    <= rom_data;
                    byte_valid <= 1'b1;
                    if (addr == `FEED_BYTES - 1) done <= 1'b1;
                    addr       <= addr + 1'b1;
                    fstate     <= F_FETCH;
                end
            endcase
        end
    end

    // ---- parser ---------------------------------------------------
    wire        p_ev;
    wire [7:0]  p_type;
    wire [15:0] p_id, p_locate;
    wire [31:0] p_price, p_shares;

    parser u_parser (
        .clk(clk), .rst(frst),
        .byte_in(byte_in), .byte_valid(byte_valid),
        .event_valid(p_ev), .msg_type(p_type), .order_id(p_id),
        .price(p_price), .shares(p_shares), .is_buy(),
        .stock_locate(p_locate)
    );
    wire [1:0] p_sel = p_locate[1:0];

    // ---- four books ---------------------------------------------
    wire [3:0]  bk_busy;
    wire [31:0] bk_best0, bk_best1, bk_best2, bk_best3;
    wire [15:0] bk_cnt0,  bk_cnt1,  bk_cnt2,  bk_cnt3;

    book_scan b0 (.clk(clk), .rst(frst), .ev_valid(p_ev && p_sel == 2'd0),
        .ev_type(p_type), .ev_id(p_id), .ev_price(p_price), .ev_shares(p_shares),
        .best_bid(bk_best0), .order_count(bk_cnt0), .busy(bk_busy[0]));
    book_scan b1 (.clk(clk), .rst(frst), .ev_valid(p_ev && p_sel == 2'd1),
        .ev_type(p_type), .ev_id(p_id), .ev_price(p_price), .ev_shares(p_shares),
        .best_bid(bk_best1), .order_count(bk_cnt1), .busy(bk_busy[1]));
    book_scan b2 (.clk(clk), .rst(frst), .ev_valid(p_ev && p_sel == 2'd2),
        .ev_type(p_type), .ev_id(p_id), .ev_price(p_price), .ev_shares(p_shares),
        .best_bid(bk_best2), .order_count(bk_cnt2), .busy(bk_busy[2]));
    book_scan b3 (.clk(clk), .rst(frst), .ev_valid(p_ev && p_sel == 2'd3),
        .ev_type(p_type), .ev_id(p_id), .ev_price(p_price), .ev_shares(p_shares),
        .best_bid(bk_best3), .order_count(bk_cnt3), .busy(bk_busy[3]));

    assign any_busy = |bk_busy;

    // one pulse when the active book finishes; select its outputs
    reg  [3:0] bk_busy_d;
    always @(posedge clk) bk_busy_d <= bk_busy;
    assign msg_done = |(bk_busy_d & ~bk_busy);

    reg [1:0] tel_sel;
    reg [7:0] tel_type;
    always @(posedge clk) if (p_ev) begin tel_sel <= p_sel; tel_type <= p_type; end

    reg  [31:0] tel_best;
    reg  [15:0] tel_cnt;
    always @* begin
        case (tel_sel)
            2'd0: begin tel_best = bk_best0; tel_cnt = bk_cnt0; end
            2'd1: begin tel_best = bk_best1; tel_cnt = bk_cnt1; end
            2'd2: begin tel_best = bk_best2; tel_cnt = bk_cnt2; end
            2'd3: begin tel_best = bk_best3; tel_cnt = bk_cnt3; end
        endcase
    end

    // ---- UART telemetry ----------------------------------------
    wire [7:0] uart_data;
    wire       uart_send, uart_busy;

    readout #(.CLK_HZ(27_000_000)) u_readout (
        .clk(clk), .rst(rst), .value(tel_best),
        .ev_stb(msg_done), .ev_type(tel_type), .ev_sel({2'd0, tel_sel}),
        .order_count(tel_cnt),
        .uart_data(uart_data), .uart_send(uart_send), .uart_busy(uart_busy)
    );
    uart_tx #(.CLK_HZ(27_000_000), .BAUD(115200)) u_uart (
        .clk(clk), .rst(rst),
        .data(uart_data), .send(uart_send), .tx(uart_tx), .busy(uart_busy)
    );

    // ---- LEDs: each lower LED blinks as its ticker's bid moves -----
    reg [31:0] bd0, bd1, bd2, bd3;
    reg [3:0]  tgl;
    always @(posedge clk) begin
        bd0 <= bk_best0; bd1 <= bk_best1; bd2 <= bk_best2; bd3 <= bk_best3;
        if (bk_best0 != bd0) tgl[0] <= ~tgl[0];
        if (bk_best1 != bd1) tgl[1] <= ~tgl[1];
        if (bk_best2 != bd2) tgl[2] <= ~tgl[2];
        if (bk_best3 != bd3) tgl[3] <= ~tgl[3];
    end
    assign led = ~{done, done, tgl};

    // ---- logic-analyzer taps ----------------------------------
    reg [4:0] s_bv, s_ev;
    always @(posedge clk) begin
        s_bv <= byte_valid ? 5'h1F : (s_bv != 0 ? s_bv - 5'd1 : 5'd0);
        s_ev <= p_ev       ? 5'h1F : (s_ev != 0 ? s_ev - 5'd1 : 5'd0);
    end
    assign dbg = {tel_sel[1], tel_sel[0], msg_done, uart_tx,
                  done, any_busy, (s_ev != 0), (s_bv != 0)};
endmodule
