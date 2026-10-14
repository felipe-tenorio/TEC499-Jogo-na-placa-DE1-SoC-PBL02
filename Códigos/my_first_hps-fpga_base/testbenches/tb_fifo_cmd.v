`timescale 1ns/1ps
//==============================================================================
// Testbench: fifo_cmd (DEPTH=8 for faster tests)
//==============================================================================
module tb_fifo_cmd;

    localparam DEPTH = 8;
    localparam ADDRW = 3;

    reg         clk, reset;
    reg         wr_en, rd_en;
    reg  [31:0] wr_data;
    wire [31:0] rd_data;
    wire        full, empty;
    wire [ADDRW:0] count;

    fifo_cmd #(.DEPTH(DEPTH), .ADDRW(ADDRW)) uut (
        .clk(clk), .reset(reset),
        .wr_en(wr_en), .wr_data(wr_data), .full(full),
        .rd_en(rd_en), .rd_data(rd_data), .empty(empty),
        .count(count)
    );

    always #5 clk = ~clk;

    integer errors, i;

    task tick; begin @(posedge clk); #1; end endtask

    task check;
        input integer cond;
        input [255:0] label;
        begin
            if (!cond) begin
                $display("FAIL [%0s]", label);
                errors = errors + 1;
            end else
                $display("PASS [%0s]", label);
        end
    endtask

    initial begin
        clk = 0; reset = 1; wr_en = 0; rd_en = 0; wr_data = 0;
        errors = 0;
        $display("=== tb_fifo_cmd ===");

        tick; tick;
        reset = 0;
        tick;
        check(empty === 1 && full === 0 && count === 0, "empty after reset");

        // Fill
        for (i = 0; i < DEPTH; i = i + 1) begin
            wr_en = 1; wr_data = 32'hA000_0000 + i;
            tick;
        end
        wr_en = 0;
        tick;
        check(full === 1 && count === DEPTH, "full after DEPTH writes");

        // Overflow ignored
        wr_en = 1; wr_data = 32'hDEADBEEF;
        tick;
        wr_en = 0;
        check(count === DEPTH, "write ignored when full");

        // Read all
        for (i = 0; i < DEPTH; i = i + 1) begin
            rd_en = 1;
            tick;
            check(rd_data === (32'hA000_0000 + i), "read data order");
        end
        rd_en = 0;
        tick;
        check(empty === 1 && count === 0, "empty after all reads");

        // Simultaneous write+read
        wr_en = 1; wr_data = 32'h1111_1111; tick; wr_en = 0;
        wr_en = 1; rd_en = 1; wr_data = 32'h2222_2222;
        tick;
        wr_en = 0; rd_en = 0;
        tick;
        check(count === 1, "simultaneous wr+rd keeps count=1");
        rd_en = 1; tick; rd_en = 0; tick;
        check(rd_data === 32'h2222_2222, "remaining data after sim wr+rd");

        if (errors == 0)
            $display("=== tb_fifo_cmd: ALL PASSED ===");
        else
            $display("=== tb_fifo_cmd: %0d ERROR(S) ===", errors);
        $finish;
    end

endmodule
