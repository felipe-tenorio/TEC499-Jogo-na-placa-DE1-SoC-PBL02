module motor_background (
    input  wire clk_pix, reset,
    input  wire [8:0] logico_x, logico_y,
    input  wire       req_valid,       // 0 = fora da area, invalida pipeline
    input  wire [7:0] scroll_x, scroll_y,
    output reg  [10:0] tilemap_addr,
    input  wire [7:0]  tilemap_data,
    output reg  [13:0] padrao_addr,
    input  wire [7:0]  padrao_data,
    output reg  [7:0]  cor_indice,
    output reg         cor_valida
);

    // Scroll com na resolucao logica
    wire [9:0] x_soma = {1'b0, logico_x} + {2'b0, scroll_x};
    wire [9:0] y_soma = {1'b0, logico_y} + {2'b0, scroll_y};

    // x_soma max = 319+255 = 574 , no maximo umas 2 subtracoes de 320.
    wire [9:0] x1 = (x_soma >= 10'd320) ? (x_soma - 10'd320) : x_soma;
    wire [9:0] x2 = (x1     >= 10'd320) ? (x1     - 10'd320) : x1;
    wire [9:0] y1 = (y_soma >= 10'd240) ? (y_soma - 10'd240) : y_soma;
    wire [9:0] y2 = (y1     >= 10'd240) ? (y1     - 10'd240) : y1;
    wire [8:0] x_w = x2[8:0];
    wire [8:0] y_w = y2[8:0];

    wire [5:0] tile_col = x_w[8:3]; // 0..39
    wire [4:0] tile_row = y_w[8:3]; // 0..29
    wire [2:0] px       = x_w[2:0];
    wire [2:0] py       = y_w[2:0];

    reg [2:0] px_d1, py_d1;
    reg       req_d1, req_d2;

    //endereco tilemap
    always @(posedge clk_pix or posedge reset) begin
        if (reset) begin
            tilemap_addr <= 11'd0;
            px_d1        <= 3'd0;
            py_d1        <= 3'd0;
            req_d1       <= 1'b0;
        end else begin
            tilemap_addr <= tile_row * 40 + tile_col;
            px_d1        <= px;
            py_d1        <= py;
            req_d1       <= req_valid; //chave, invalida no fim da linha
        end
    end

    //dado da tilemap -endereco no padrao
    always @(posedge clk_pix or posedge reset) begin
        if (reset) begin
            padrao_addr <= 14'd0;
            req_d2      <= 1'b0;
        end else begin
            padrao_addr <= {tilemap_data, 6'b0} + {py_d1, 3'b0} + px_d1;
            req_d2      <= req_d1;
        end
    end

    //dado do padrao, cor (RRRGGGBB) + flag alinhada
    always @(posedge clk_pix or posedge reset) begin
        if (reset) begin
            cor_indice <= 8'd0;
            cor_valida <= 1'b0;
        end else begin
            cor_indice <= padrao_data;
            cor_valida <= req_d2; // 0 no inicio da linha a depender do pipeline
        end
    end

endmodule
