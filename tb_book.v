// tb_book.v -- self-checking testbench for book.v
//
// Reads data/events.txt (produced by tools/itch_to_hex.py, which gets the
// expected best_bid from tools/reference_book.py) and replays it straight into
// the book, bypassing the parser. After every event the book's best_bid must
// match the reference model's value for that step.
//
//   events.txt line:  <hex type> <id> <price> <shares> <expected_best_bid>
//
// Run from the repo root so the relative path resolves (the Makefile does).

`timescale 1ns/1ps

module tb_book;

    reg         clk = 1'b0;
    reg         rst = 1'b1;
    reg         ev_valid = 1'b0;
    reg  [7:0]  ev_type  = 8'd0;
    reg  [15:0] ev_id    = 16'd0;
    reg  [31:0] ev_price = 32'd0;
    reg  [31:0] ev_shares= 32'd0;
    wire [31:0] best_bid;
    wire        busy;

    integer errors = 0;
    integer checks = 0;

    book dut (
        .clk(clk), .rst(rst),
        .ev_valid(ev_valid), .ev_type(ev_type), .ev_id(ev_id),
        .ev_price(ev_price), .ev_shares(ev_shares),
        .best_bid(best_bid), .busy(busy)
    );

    always #5 clk = ~clk;

    // drive one event and wait for the book to finish processing it
    task do_event(input [7:0] t, input [15:0] id,
                  input [31:0] pr, input [31:0] sh);
        begin
            @(negedge clk);
            ev_type = t; ev_id = id; ev_price = pr; ev_shares = sh;
            ev_valid = 1'b1;
            @(negedge clk);
            ev_valid = 1'b0;
            // busy asserts the cycle after ev_valid; wait for it to clear
            wait (busy === 1'b1);
            wait (busy === 1'b0);
            @(negedge clk);
        end
    endtask

    integer fd, r, k;
    integer t_i, id_i, pr_i, sh_i, exp_i;

    initial begin
`ifdef DUMP
        $dumpfile("tb_book.vcd");
        $dumpvars(0, tb_book);
`endif
        repeat (4) @(negedge clk);
        rst = 1'b0;
        repeat (2) @(negedge clk);

        fd = $fopen("data/events.txt", "r");
        if (fd == 0) begin
            $display("FAIL  cannot open data/events.txt (run `make feed`)");
            $display("TESTS FAILED");
            $finish;
        end

        k = 0;
        while (!$feof(fd)) begin
            r = $fscanf(fd, "%h %d %d %d %d\n", t_i, id_i, pr_i, sh_i, exp_i);
            if (r == 5) begin
                do_event(t_i[7:0], id_i[15:0], pr_i, sh_i);
                checks = checks + 1;
                if (best_bid === exp_i) begin
                    $display("PASS  event %0d  type=%0h id=%0d -> best_bid=%0d",
                             k, t_i, id_i, best_bid);
                end else begin
                    errors = errors + 1;
                    $display("FAIL  event %0d  type=%0h id=%0d -> best_bid=%0d exp=%0d",
                             k, t_i, id_i, best_bid, exp_i);
                end
                k = k + 1;
            end
        end
        $fclose(fd);

        $display("----");
        $display("checks=%0d errors=%0d", checks, errors);
        if (errors == 0 && checks > 0) $display("ALL TESTS PASSED");
        else                           $display("TESTS FAILED");
        $finish;
    end

    initial begin
        #5000000;
        $display("FAIL  timeout");
        $display("TESTS FAILED");
        $finish;
    end

endmodule
