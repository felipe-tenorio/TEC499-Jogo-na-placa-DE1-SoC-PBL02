module motor_sprites (
    input  wire clk_pix, reset,
    input  wire [8:0] logico_x, logico_y, // Coordenada atual do pixel na tela
    input  wire req_valid,// 0 = fora da area = invalida
    // Atributos dos 32 sprites
    // (arrays achatados: sprite i = bits [i*W +: W])
    input  wire [32*9-1:0] attr_x_flat,
    input  wire [32*9-1:0] attr_y_flat,
    input  wire [32*5-1:0] attr_padrao_flat,
    input  wire [31:0]     attr_en_flat,
    input  wire [32*3-1:0] attr_pri_flat,
    input  wire [31:0]     attr_fliph_flat,
    input  wire [31:0]     attr_flipv_flat,

    output reg  [12:0] padrao_addr_sprite,
    input  wire [7:0]  padrao_data_sprite,

    output reg  [7:0]  cor_indice,
    output reg         pixel_ativo
);

    // Desempacota os vetores achatados em arrays internos
    wire [8:0] attr_x       [0:31]; //atributo X
    wire [8:0] attr_y       [0:31]; //atributo Y
    wire [4:0] attr_padrao  [0:31]; 
    wire       attr_en      [0:31]; 
    wire [2:0] attr_pri     [0:31]; //sinal de prioridade
    wire       attr_fliph   [0:31];// sinal de flip horizontal
    wire       attr_flipv   [0:31]; //sinal de flip vertical
    genvar gi;
    generate
        for (gi = 0; gi < 32; gi = gi + 1) begin : g_unpack
            assign attr_x[gi]      = attr_x_flat     [gi*9 +: 9];
            assign attr_y[gi]      = attr_y_flat     [gi*9 +: 9];
            assign attr_padrao[gi] = attr_padrao_flat[gi*5 +: 5];
            assign attr_en[gi]     = attr_en_flat    [gi];
            assign attr_pri[gi]    = attr_pri_flat   [gi*3 +: 3];
            assign attr_fliph[gi]  = attr_fliph_flat [gi];
            assign attr_flipv[gi]  = attr_flipv_flat [gi];
        end
    endgenerate

    reg [31:0] hit_s1;
    reg [3:0]  px_s1 [0:31];
    reg [3:0]  py_s1 [0:31];
    reg        req_s1;

    wire [9:0] dx [0:31];
    wire [9:0] dy [0:31];
    generate
        for (gi = 0; gi < 32; gi = gi + 1) begin : g_hit
            assign dx[gi] = {1'b0, logico_x} - {1'b0, attr_x[gi]};
            assign dy[gi] = {1'b0, logico_y} - {1'b0, attr_y[gi]};
        end
    endgenerate

    integer j;
    always @(posedge clk_pix or posedge reset) begin
        if (reset) begin
            hit_s1 <= 32'd0;
            req_s1 <= 1'b0;
            for (j = 0; j < 32; j = j + 1) begin
                px_s1[j] <= 4'd0;
                py_s1[j] <= 4'd0;
            end
        end else begin
            req_s1 <= req_valid;
            for (j = 0; j < 32; j = j + 1) begin
                hit_s1[j] <= attr_en[j] && (dx[j][9:4] == 6'd0) && (dy[j][9:4] == 6'd0);
                px_s1[j]  <= dx[j][3:0];
                py_s1[j]  <= dy[j][3:0];
            end
        end
    end

//Prioridade dos sprites (vence o de maior indice)
    reg       t_hit [0:62];
    reg [2:0] t_pri [0:62];
    reg [4:0] t_idx [0:62];
    integer k;
    always @(*) begin
        for (k = 0; k < 32; k = k + 1) begin
            t_hit[31+k] = hit_s1[k];
            t_pri[31+k] = attr_pri[k];
            t_idx[31+k] = k[4:0];
        end
        for (k = 30; k >= 0; k = k - 1) begin
            if (t_hit[2*k+2] && (!t_hit[2*k+1] || (t_pri[2*k+2] > t_pri[2*k+1]))) begin
                t_hit[k] = 1'b1;
                t_pri[k] = t_pri[2*k+2];
                t_idx[k] = t_idx[2*k+2];
            end else begin
                t_hit[k] = t_hit[2*k+1];
                t_pri[k] = t_pri[2*k+1];
                t_idx[k] = t_idx[2*k+1];
            end
        end
    end

    reg       achou_s2, req_s2;
    reg [4:0] venc_s2;
    reg [3:0] px_s2, py_s2;
    always @(posedge clk_pix or posedge reset) begin
        if (reset) begin
            achou_s2 <= 1'b0; req_s2 <= 1'b0;
            venc_s2  <= 5'd0; px_s2  <= 4'd0; py_s2 <= 4'd0;
        end else begin
            achou_s2 <= t_hit[0];
            req_s2   <= req_s1;
            venc_s2  <= t_idx[0];
            px_s2    <= px_s1[t_idx[0]];
            py_s2    <= py_s1[t_idx[0]];
        end
    end

//Endereço do padrao de sprites
    wire [3:0] px_ef = attr_fliph[venc_s2] ? (4'd15 - px_s2) : px_s2;
    wire [3:0] py_ef = attr_flipv[venc_s2] ? (4'd15 - py_s2) : py_s2;

    reg ativo_s3;
    always @(posedge clk_pix or posedge reset) begin
        if (reset) begin
            padrao_addr_sprite <= 13'd0;
            ativo_s3           <= 1'b0;
        end else begin
            padrao_addr_sprite <= {attr_padrao[venc_s2], py_ef, px_ef};
            ativo_s3           <= achou_s2 & req_s2;
        end
    end

	 //Registra o dado da RAM em um ciclo de clk para a cor e a flag de pixel_ativo chegem juntas
    always @(posedge clk_pix or posedge reset) begin
        if (reset) begin
            cor_indice  <= 8'd0;
            pixel_ativo <= 1'b0;
        end else begin
            cor_indice  <= padrao_data_sprite; // RRRGGGBB
            pixel_ativo <= ativo_s3;
        end
    end

endmodule
