module gpr_bank (

// Banco de 16 registradores de proposito geral (GPR), cada um com 16 bits
//POssui os endereços determinados durante a criacao dos pios
    input  wire        clk,
    input  wire        reset,
    input  wire        we, //habilita a escrita
    input  wire [3:0]  wa, // endereço do registrador que recebe o dado
    input  wire [15:0] wd, //dado de 16 bits que sera escrito
    input  wire [3:0]  ra1, // endereço do primeiro registrador que sera lido
    input  wire [3:0]  ra2, // endereço do segundo registrador
    output wire [15:0] rd1,// dado lido do primeiro registrador
    output wire [15:0] rd2 //dado lido do segundoregistrador
);
    reg [15:0] regs [0:15];
    integer i;
	 //leitura dos registradores
    assign rd1 = (ra1 == 4'd0) ? 16'd0 : regs[ra1];
    assign rd2 = (ra2 == 4'd0) ? 16'd0 : regs[ra2];
	 //escrita dos registradores
    always @(posedge clk) begin //Permite uma escrita por ciclo de clock.
        if (reset) begin //Todos os registradores sao zerados quando reset = 1
            for (i = 0; i < 16; i = i + 1) regs[i] <= 16'd0;
        end else if (we && (wa != 4'd0)) begin
            regs[wa] <= wd;
        end
    end
endmodule