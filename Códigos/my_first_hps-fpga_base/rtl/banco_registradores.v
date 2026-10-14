module banco_registradores (
    input  wire clk_sys, reset,
    input  wire wr_en,
    input  wire [15:0] endereco,
    input  wire [8:0]  dado_in, // 9 bits: cobre coordenadas ate 319 (eixo X)

    output reg  [7:0] bg_scroll_x, bg_scroll_y,
    output reg  [4:0] sprite_sel, // indice do sprite

    // Arrays achatados: elemento i = bits [i*W +: W]
    output wire [32*9-1:0] sprite_x_flat,      // posicao X dos 32 sprites
    output wire [32*9-1:0] sprite_y_flat,      // posicao Y dos 32 sprites
    output wire [32*5-1:0] sprite_padrao_flat, // indice do bloco 16x16 (0-31 padroes)
    output wire [31:0]     sprite_en_flat,
    output wire [32*3-1:0] sprite_pri_flat,
    output wire [31:0]     sprite_fliph_flat,
    output wire [31:0]     sprite_flipv_flat,

    output reg  enable_bg, enable_sprite, enable_poly,

    output reg  [8:0] ovr_spr1_x,
    output reg  ovr_prioridade, //sprite1 tem prioridade maior que sprite0

    output reg  swap_bg_request, // pulso de 1 ciclo de clk_sys (tilemap A<->B)
    output reg  swap_fb_request, // pulso de 1 ciclo de clk_sys (frame buffer)

    // Prioridade entre camadas sprite e poligono (cenário 101)
    // 1 = sprite > poligono > BG (padrão); 0 = polígono > sprite > BG
    output reg  sprite_over_poly,

    // 4 slots de poligono
    // Arrays achatados slot i = bits [i*W +: W]
    output wire [4*10-1:0] poly_x_flat,        // signed 10b por slot
    output wire [4*10-1:0] poly_y_flat,        // signed 10b por slot
    output wire [4*9-1:0]  poly_size_flat,
    output wire [4*3-1:0]  poly_tipo_flat,
    output wire [4*3-1:0]  poly_nverts_flat,
    output wire [4*8-1:0]  poly_cor_flat,
    output wire [3:0]      poly_habilitado_flat,

    output wire [7:0] status,
    input  wire estimulo_invalido,
    input  wire buffer_pronto,
    output reg  endereco_invalido
);

    integer i;

    // Arrays internos
    reg  [8:0] sprite_x        [0:31];
    reg  [8:0] sprite_y        [0:31];
    reg  [4:0] sprite_padrao   [0:31];
    reg        sprite_en       [0:31];
    reg  [2:0] sprite_pri      [0:31];
    reg        sprite_fliph    [0:31];
    reg        sprite_flipv    [0:31];
    reg signed [9:0] poly_x    [0:3];
    reg signed [9:0] poly_y    [0:3];
    reg        [8:0] poly_size [0:3];
    reg        [2:0] poly_tipo [0:3];
    reg        [2:0] poly_nverts[0:3];
    reg        [7:0] poly_cor  [0:3];
    reg              poly_habilitado [0:3];

    genvar gi;
    generate
        for (gi = 0; gi < 32; gi = gi + 1) begin : g_spr_flat
            assign sprite_x_flat     [gi*9 +: 9] = sprite_x[gi];
            assign sprite_y_flat     [gi*9 +: 9] = sprite_y[gi];
            assign sprite_padrao_flat[gi*5 +: 5] = sprite_padrao[gi];
            assign sprite_en_flat    [gi]        = sprite_en[gi];
            assign sprite_pri_flat   [gi*3 +: 3] = sprite_pri[gi];
            assign sprite_fliph_flat [gi]        = sprite_fliph[gi];
            assign sprite_flipv_flat [gi]        = sprite_flipv[gi];
        end
        for (gi = 0; gi < 4; gi = gi + 1) begin : g_poly_flat
            assign poly_x_flat          [gi*10 +: 10] = poly_x[gi];
            assign poly_y_flat          [gi*10 +: 10] = poly_y[gi];
            assign poly_size_flat       [gi*9 +: 9]   = poly_size[gi];
            assign poly_tipo_flat       [gi*3 +: 3]   = poly_tipo[gi];
            assign poly_nverts_flat     [gi*3 +: 3]   = poly_nverts[gi];
            assign poly_cor_flat        [gi*8 +: 8]   = poly_cor[gi];
            assign poly_habilitado_flat [gi]          = poly_habilitado[gi];
        end
    endgenerate

    assign status = {6'b0, buffer_pronto, estimulo_invalido}; //(somente leitura via 'status')

    //decodificacao de slot de poligono
    wire eh_poly    = (endereco[7:0] >= 8'h30) && (endereco[7:0] <= 8'h4F);
    wire [1:0] poly_slot  = (endereco[7:0] - 8'h30) >> 3;
    wire [2:0] poly_campo = endereco[2:0];

    //deltas de poligono (movimento relativo): 0x50..0x57
    wire eh_poly_delta     = (endereco[7:0] >= 8'h50) && (endereco[7:0] <= 8'h57);
    wire [1:0] pdelta_slot = endereco[2:1];
    wire signed [9:0] delta10 = $signed({dado_in[8], dado_in[8:0]});

    always @(posedge clk_sys) begin
        if (reset) begin
            bg_scroll_x <= 0; bg_scroll_y <= 0;
            sprite_sel  <= 0;
            enable_bg <= 0; enable_sprite <= 0; enable_poly <= 0;
            ovr_spr1_x <= 0; ovr_prioridade <= 0;
            swap_bg_request <= 0;
            swap_fb_request <= 0;
            sprite_over_poly <= 1'b1; // padrao: sprite > poligono > BG
            endereco_invalido <= 0;
            for (i = 0; i < 32; i = i + 1) begin
                sprite_x[i] <= 0; sprite_y[i] <= 0; sprite_padrao[i] <= 0;
                sprite_en[i] <= 0; sprite_pri[i] <= 0;
                sprite_fliph[i] <= 0; sprite_flipv[i] <= 0;
            end
            for (i = 0; i < 4; i = i + 1) begin
                poly_x[i]         <= 0;
                poly_y[i]         <= 0;
                poly_size[i]      <= 9'd64;
                poly_tipo[i]      <= 3'd0;
                poly_nverts[i]    <= 3'd4;
                poly_cor[i]       <= 0;
                poly_habilitado[i]<= 0;
            end
        end else begin
            swap_bg_request   <= 0;
            swap_fb_request   <= 0;
            endereco_invalido <= 0;

            if (wr_en) begin
                if (eh_poly) begin
                    case (poly_campo)
                        // Sign-extend 9->10 bits: permite coordenadas negativas(nao deixa o poligono distorcer)
                        3'd0: poly_x[poly_slot]         <= $signed({dado_in[8], dado_in[8:0]});
                        3'd1: poly_y[poly_slot]         <= $signed({dado_in[8], dado_in[8:0]});
                        3'd2: poly_size[poly_slot]      <= dado_in[8:0];
                        3'd3: poly_tipo[poly_slot]      <= dado_in[2:0];
                        3'd4: poly_nverts[poly_slot]    <= dado_in[2:0];
                        3'd5: ; // reservado
                        3'd6: poly_cor[poly_slot]       <= dado_in[7:0];
                        3'd7: poly_habilitado[poly_slot]<= dado_in[0];
                    endcase
                end else if (eh_poly_delta) begin
                    if (endereco[0] == 1'b0)
                        poly_x[pdelta_slot] <= poly_x[pdelta_slot] + delta10;
                    else
                        poly_y[pdelta_slot] <= poly_y[pdelta_slot] + delta10;
                end else begin
                    case (endereco[7:0])
                        8'h01: bg_scroll_x <= dado_in;
                        8'h02: bg_scroll_y <= dado_in;
                        8'h03: sprite_sel  <= dado_in[4:0];
                        8'h04: sprite_x[sprite_sel]      <= dado_in;
                        8'h05: sprite_y[sprite_sel]      <= dado_in;
                        8'h06: begin
                            sprite_pri[sprite_sel]   <= dado_in[5:3];
                            sprite_en[sprite_sel]    <= dado_in[2];
                            sprite_fliph[sprite_sel] <= dado_in[1];
                            sprite_flipv[sprite_sel] <= dado_in[0];
                        end
                        8'h07: sprite_padrao[sprite_sel] <= dado_in[4:0];
                        8'h08: begin
                            enable_bg     <= dado_in[0]; //Flags
                            enable_sprite <= dado_in[1];
                            enable_poly   <= dado_in[2];
                        end
                        8'h09: ovr_spr1_x     <= dado_in;
                        8'h0A: ovr_prioridade <= dado_in[0];
                        8'h0B: swap_bg_request  <= 1'b1;
                        8'h0C: sprite_over_poly <= dado_in[0];
                        8'h0D: swap_fb_request  <= 1'b1;
                        8'h0E: bg_scroll_x <= bg_scroll_x + dado_in[7:0];
                        8'h0F: bg_scroll_y <= bg_scroll_y + dado_in[7:0];
                        8'h20: begin
                            sprite_fliph[sprite_sel] <= dado_in[0];
                            sprite_flipv[sprite_sel] <= dado_in[1];
                        end
                        8'h21: sprite_x[sprite_sel] <= sprite_x[sprite_sel] + dado_in;
                        8'h22: sprite_y[sprite_sel] <= sprite_y[sprite_sel] + dado_in;
                        default: endereco_invalido <= 1'b1;
                    endcase
                end
            end
        end
    end

endmodule
