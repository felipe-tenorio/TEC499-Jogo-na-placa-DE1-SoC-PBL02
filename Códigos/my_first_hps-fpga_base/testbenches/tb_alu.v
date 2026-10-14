`timescale 1ns/1ps
//==============================================================================
// Testbench: alu
// Cobre: ADD, SUB, AND, OR, PASS-B e default
//==============================================================================
module tb_alu;

    reg  [15:0] a, b;
    reg  [2:0]  op;
    wire [15:0] result;

    alu uut (
        .a(a),
        .b(b),
        .op(op),
        .result(result)
    );

    integer errors;

    task check;
        input [15:0] expected;
        input [255:0] label;
        begin
            #1;
            if (result !== expected) begin
                $display("FAIL [%0s] a=%h b=%h op=%b => got %h expected %h",
                         label, a, b, op, result, expected);
                errors = errors + 1;
            end else
                $display("PASS [%0s] result=%h", label, result);
        end
    endtask

    initial begin
        errors = 0;
        $display("=== tb_alu ===");

        // ADD
        a = 16'h000A; b = 16'h0005; op = 3'b000;
        check(16'h000F, "ADD 10+5");

        a = 16'hFFFF; b = 16'h0001; op = 3'b000;
        check(16'h0000, "ADD overflow wrap");

        // SUB
        a = 16'h0010; b = 16'h0003; op = 3'b001;
        check(16'h000D, "SUB 16-3");

        a = 16'h0000; b = 16'h0001; op = 3'b001;
        check(16'hFFFF, "SUB underflow");

        // AND
        a = 16'hF0F0; b = 16'h0FF0; op = 3'b010;
        check(16'h00F0, "AND");

        // OR
        a = 16'hF0F0; b = 16'h0FF0; op = 3'b011;
        check(16'hFFF0, "OR");

        // PASS B
        a = 16'hAAAA; b = 16'h1234; op = 3'b100;
        check(16'h1234, "PASS B");

        // default
        a = 16'h1111; b = 16'h2222; op = 3'b111;
        check(16'h0000, "DEFAULT");

        if (errors == 0)
            $display("=== tb_alu: ALL PASSED ===");
        else
            $display("=== tb_alu: %0d ERROR(S) ===", errors);

        $finish;
    end

endmodule
