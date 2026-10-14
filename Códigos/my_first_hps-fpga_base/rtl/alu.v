module alu (
    input wire [15:0] a,
    input wire [15:0] b,
    input wire [2:0]  op,   // 000=ADD 001=SUB 010=AND 011=OR 100=pass b
    output reg [15:0] result
);
    always @(*) begin // Ula basica de 16 bits
        case (op)
            3'b000: result = a + b;
            3'b001: result = a - b;
            3'b010: result = a & b;
            3'b011: result = a | b;
            3'b100: result = b;
            default: result = 16'd0;
        endcase
    end
endmodule
