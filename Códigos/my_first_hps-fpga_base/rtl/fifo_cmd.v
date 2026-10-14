module fifo_cmd #( //busca passiva
    parameter DEPTH = 32,
    parameter ADDRW = 5
)(
    input  wire clk,
    input  wire reset,
    input  wire wr_en, //endereco de dados
    input  wire [31:0] wr_data,//escrita de dados
    output wire full, //flag de fila cheia
    input  wire rd_en, //leitura de endereco
    output reg [31:0] rd_data, //leitura de dados
    output wire empty, //flag de fila vazia
    output wire [ADDRW:0] count //contador [0->31] tamanho da fila
);
    reg [31:0] mem [0:DEPTH-1];
    reg [ADDRW-1:0] wr_ptr, rd_ptr;
    reg [ADDRW:0] cnt;

    assign full = (cnt == DEPTH);
    assign empty = (cnt == 0);
    assign count = cnt;
/*Responsavel por escrever ou ler dados da fila a depender do seu estado atual(cheia ou vazia)*/
    always @(posedge clk) begin 
        if (reset) begin
            wr_ptr  <= 0;
            rd_ptr  <= 0;
            cnt     <= 0;
            rd_data <= 32'd0;
        end else begin
            if (wr_en && !full) begin
                mem[wr_ptr] <= wr_data;
                wr_ptr      <= wr_ptr + 1'b1;
            end
            if (rd_en && !empty) begin
                rd_data <= mem[rd_ptr];
                rd_ptr  <= rd_ptr + 1'b1;
            end
            case ({wr_en && !full, rd_en && !empty})
                2'b10: cnt <= cnt + 1'b1;
                2'b01: cnt <= cnt - 1'b1;
                default: ;
            endcase
        end
    end
endmodule
