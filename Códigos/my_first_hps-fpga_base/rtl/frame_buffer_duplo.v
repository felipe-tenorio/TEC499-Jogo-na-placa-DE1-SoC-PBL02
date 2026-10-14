module frame_buffer_duplo (
    input wire clk,
    input wire reset,

    //controle de troca (1 ciclo em clk_pix, alinhado a VSYNC)
    input wire swap_now,
    output reg buffer_ativo, // 0 = A na frente, 1 = B na frente

    //porta de escrita (composiçao do quadro no back)
    input wire wr_en,
    input wire [16:0] wr_addr,// 0 .. 76799
    input wire [7:0] wr_data,

    //porta de leitura (exibiçao do front)
    input  wire [16:0] rd_addr,
    output reg  [7:0]  rd_data
);

    localparam integer FB_DEPTH = 76800; // 320*240

    // Dois bancos de memoria (dual port)
    reg [7:0] fb_a [0:FB_DEPTH-1];
    reg [7:0] fb_b [0:FB_DEPTH-1];

    // Qual banco esta na frente: 0->A front/B back, 1->B front/A back
    always @(posedge clk) begin
        if (reset)
            buffer_ativo <= 1'b0;
        else if (swap_now)
            buffer_ativo <= ~buffer_ativo;
    end

    //escrita no background
    always @(posedge clk) begin
        if (wr_en) begin
            if (buffer_ativo == 1'b0)
                fb_b[wr_addr] <= wr_data; // A na frente → escreve em B
            else
                fb_a[wr_addr] <= wr_data; // B na frente → escreve em A
        end
    end

    //leitura do FRONT (1 ciclo de latencia)
    reg [7:0] rd_a, rd_b;
    always @(posedge clk) begin
        rd_a <= fb_a[rd_addr];
        rd_b <= fb_b[rd_addr];
    end

    always @(*) begin
        rd_data = (buffer_ativo == 1'b0) ? rd_a : rd_b;
    end

endmodule
