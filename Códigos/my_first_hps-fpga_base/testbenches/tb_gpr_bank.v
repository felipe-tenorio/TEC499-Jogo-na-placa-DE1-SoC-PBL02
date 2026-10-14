`timescale 1ns/1ps
//==============================================================================
// Testbench: gpr_bank
// - R0 always zero
// - Write/read of R1..R15
// - Reset clears all
//==============================================================================
module tb_gpr_bank;

    reg         clk, reset, we;
    reg  [3:0]  wa, ra1, ra2;
    reg  [15:0] wd;
    wire [15:0] rd1, rd2;

    gpr_bank uut (
        .clk(clk), .reset(reset),
        .we(we), .wa(wa), .wd(wd),
        .ra1(ra1), .ra2(ra2),
        .rd1(rd1), .rd2(rd2)
    );

    always #5 clk = ~clk;

    integer errors;

    task tick; begin @(posedge clk); #1; end endtask

    task check;
        input [15:0] got, expected;
        input [255:0] label;
        begin
            if (got !== expected) begin
                $display("FAIL [%0s] got=%h expected=%h", label, got, expected);
                errors = errors + 1;
            end else
                $display("PASS [%0s] = %h", label, got);
        end
    endtask

    initial begin
        clk = 0; reset = 1; we = 0; wa = 0; wd = 0; ra1 = 0; ra2 = 0;
        errors = 0;
        $display("=== tb_gpr_bank ===");

        tick; tick;
        reset = 0;
        tick;

        // R0 always 0 even if written
        we = 1; wa = 4'd0; wd = 16'hDEAD;
        tick;
        we = 0; ra1 = 4'd0;
        tick;
        check(rd1, 16'h0000, "R0 stays 0 after write");

        // Write R1 and R2
        we = 1; wa = 4'd1; wd = 16'h1111; tick;
        wa = 4'd2; wd = 16'h2222; tick;
        we = 0;

        ra1 = 4'd1; ra2 = 4'd2; tick;
        check(rd1, 16'h1111, "R1 read");
        check(rd2, 16'h2222, "R2 read");

        // Write R15
        we = 1; wa = 4'd15; wd = 16'hABCD; tick;
        we = 0; ra1 = 4'd15; tick;
        check(rd1, 16'hABCD, "R15 read");

        // Reset
        reset = 1; tick; tick;
        reset = 0; tick;
        ra1 = 4'd1; ra2 = 4'd15; tick;
        check(rd1, 16'h0000, "R1 after reset");
        check(rd2, 16'h0000, "R15 after reset");

        if (errors == 0)
            $display("=== tb_gpr_bank: ALL PASSED ===");
        else
            $display("=== tb_gpr_bank: %0d ERROR(S) ===", errors);
        $finish;
    end

endmodule
