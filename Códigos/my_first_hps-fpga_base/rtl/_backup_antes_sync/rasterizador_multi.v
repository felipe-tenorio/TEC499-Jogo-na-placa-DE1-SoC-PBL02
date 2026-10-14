// rasterizador_multi.v
// Rasterizador de polígonos paramétrico com 4 slots em paralelo.
//
// Correção de deformação de triângulos:
//   - Funções de aresta com acumuladores de 32 bits (evita overflow
//     quando a origem está próxima de 0 e o tamanho é grande).
//   - Vértices gerados em aritmética signed de 11 bits, depois
//     truncados de forma segura para 10 bits.
//   - A geometria é sempre relativa a (ox, oy); não depende de
//     ox >= size/2 para manter a forma.
//
// Interface por polígono:
//   poly_x, poly_y   : posição inicial (canto / referência) — signed
//   poly_size        : tamanho base (largura/altura aproximada)
//   poly_tipo        : formato (0=retângulo, 1..4=triângulos, 5=quadrado)
//   poly_nverts      : quantidade de vértices (3 ou 4)
//   poly_cor         : cor RRRGGGBB
//   poly_habilitado  : habilita o slot
//
// Saída combinacional (latência 0). Regra de desempate: menor índice vence.

module rasterizador_multi (
    input  wire clk_pix, reset,
    input  wire signed [9:0] logico_x, logico_y,

    // Parâmetros dos 4 polígonos
    // (arrays achatados: slot i = bits [i*W +: W])
    input  wire [4*10-1:0] poly_x_flat,
    input  wire [4*10-1:0] poly_y_flat,
    input  wire [4*9-1:0]  poly_size_flat,
    input  wire [4*3-1:0]  poly_tipo_flat,
    input  wire [4*3-1:0]  poly_nverts_flat,
    input  wire [4*8-1:0]  poly_cor_flat,
    input  wire [3:0]      poly_habilitado_flat,

    output wire pixel_ativo,
    output wire [7:0] cor_indice
);

    // Desempacota os vetores achatados em arrays internos
    wire signed [9:0] poly_x   [0:3];
    wire signed [9:0] poly_y   [0:3];
    wire        [8:0] poly_size[0:3];
    wire        [2:0] poly_tipo[0:3];
    wire        [2:0] poly_nverts[0:3];
    wire        [7:0] poly_cor [0:3];
    wire              poly_habilitado [0:3];
    genvar gi;
    generate
        for (gi = 0; gi < 4; gi = gi + 1) begin : g_unpack
            assign poly_x[gi]          = poly_x_flat         [gi*10 +: 10];
            assign poly_y[gi]          = poly_y_flat         [gi*10 +: 10];
            assign poly_size[gi]       = poly_size_flat      [gi*9 +: 9];
            assign poly_tipo[gi]       = poly_tipo_flat      [gi*3 +: 3];
            assign poly_nverts[gi]     = poly_nverts_flat    [gi*3 +: 3];
            assign poly_cor[gi]        = poly_cor_flat       [gi*8 +: 8];
            assign poly_habilitado[gi] = poly_habilitado_flat[gi];
        end
    endgenerate

    integer i;

    reg dentro [0:3];
    reg achou;
    reg [1:0] vencedor;

    // ----------------------------------------------------------------
    // Teste ponto-em-triângulo com edge functions em 32 bits.
    // Aceita orientação CW ou CCW (produto com mesmo sinal).
    // ----------------------------------------------------------------
    function automatic dentro_triangulo;
        input signed [9:0] px, py;
        input signed [9:0] x0, y0, x1, y1, x2, y2;
        reg signed [31:0] e0, e1, e2;
        reg signed [10:0] dx01, dy01, dx12, dy12, dx20, dy20;
        reg signed [10:0] dpx0, dpy0, dpx1, dpy1, dpx2, dpy2;
        begin
            // Diferenças de aresta (11 bits signed cobre ±1023)
            dx01 = $signed({x1[9], x1}) - $signed({x0[9], x0});
            dy01 = $signed({y1[9], y1}) - $signed({y0[9], y0});
            dx12 = $signed({x2[9], x2}) - $signed({x1[9], x1});
            dy12 = $signed({y2[9], y2}) - $signed({y1[9], y1});
            dx20 = $signed({x0[9], x0}) - $signed({x2[9], x2});
            dy20 = $signed({y0[9], y0}) - $signed({y2[9], y2});

            dpx0 = $signed({px[9], px}) - $signed({x0[9], x0});
            dpy0 = $signed({py[9], py}) - $signed({y0[9], y0});
            dpx1 = $signed({px[9], px}) - $signed({x1[9], x1});
            dpy1 = $signed({py[9], py}) - $signed({y1[9], y1});
            dpx2 = $signed({px[9], px}) - $signed({x2[9], x2});
            dpy2 = $signed({py[9], py}) - $signed({y2[9], y2});

            // Cross products em 32 bits: 11x11 → 22 bits, cabe folgado
            e0 = dpx0 * dy01 - dpy0 * dx01;
            e1 = dpx1 * dy12 - dpy1 * dx12;
            e2 = dpx2 * dy20 - dpy2 * dx20;

            dentro_triangulo = (e0 >= 0 && e1 >= 0 && e2 >= 0) ||
                               (e0 <= 0 && e1 <= 0 && e2 <= 0);
        end
    endfunction

    // ----------------------------------------------------------------
    // Gera vértices a partir de (ox,oy,sz,tipo) e testa inclusão.
    // Todas as somas usam 11 bits signed para não saturar quando
    // ox está perto de 0 e sz é grande (ex.: ox=10, sz=80).
    // ----------------------------------------------------------------
    function automatic ponto_dentro;
        input signed [9:0] px, py;
        input signed [9:0] ox, oy;   // origem
        input        [8:0] sz;
        input        [2:0] tipo;
        reg signed [10:0] ox11, oy11, sz11, half, three_q, one_third, three_oct, one_oct;
        reg signed [10:0] vx0, vy0, vx1, vy1, vx2, vy2;
        reg signed [9:0]  x0, y0, x1, y1, x2, y2;
        begin
            ox11      = $signed({ox[9], ox});
            oy11      = $signed({oy[9], oy});
            sz11      = $signed({2'b0, sz});          // 0..511
            half      = sz11 >>> 1;                    // sz/2 aritmético
            three_q   = (sz11 * 3) >>> 2;             // 3/4 * sz
            one_third = sz11 / 3;
            three_oct = (sz11 * 3) >>> 3;             // 3/8 * sz
            one_oct   = sz11 >>> 3;                   // 1/8 * sz

            case (tipo)
                3'd0: begin // retângulo: largura=sz, altura=3/4*sz
                    vx0 = ox11;           vy0 = oy11;
                    vx1 = ox11 + sz11;    vy1 = oy11 + three_q;
                    // AABB
                    ponto_dentro = (px >= vx0[9:0]) && (px < vx1[9:0]) &&
                                   (py >= vy0[9:0]) && (py < vy1[9:0]);
                end
                3'd1: begin // triângulo retângulo (ângulo em baixo-esquerda)
                    vx0 = ox11;           vy0 = oy11;
                    vx1 = ox11;           vy1 = oy11 + sz11;
                    vx2 = ox11 + sz11;    vy2 = oy11 + sz11;
                    x0 = vx0[9:0]; y0 = vy0[9:0];
                    x1 = vx1[9:0]; y1 = vy1[9:0];
                    x2 = vx2[9:0]; y2 = vy2[9:0];
                    ponto_dentro = dentro_triangulo(px, py, x0, y0, x1, y1, x2, y2);
                end
                3'd2: begin // isósceles / equilátero aproximado (ápice em cima)
                    // Vértices SEMPRE relativos a ox: ápice em ox+sz/2,
                    // base de ox até ox+sz. Forma preservada mesmo com ox < sz/2.
                    vx0 = ox11 + half;    vy0 = oy11;
                    vx1 = ox11;           vy1 = oy11 + sz11;
                    vx2 = ox11 + sz11;    vy2 = oy11 + sz11;
                    x0 = vx0[9:0]; y0 = vy0[9:0];
                    x1 = vx1[9:0]; y1 = vy1[9:0];
                    x2 = vx2[9:0]; y2 = vy2[9:0];
                    ponto_dentro = dentro_triangulo(px, py, x0, y0, x1, y1, x2, y2);
                end
                3'd3: begin // isósceles (ápice em baixo)
                    vx0 = ox11;           vy0 = oy11;
                    vx1 = ox11 + sz11;    vy1 = oy11;
                    vx2 = ox11 + half;    vy2 = oy11 + sz11;
                    x0 = vx0[9:0]; y0 = vy0[9:0];
                    x1 = vx1[9:0]; y1 = vy1[9:0];
                    x2 = vx2[9:0]; y2 = vy2[9:0];
                    ponto_dentro = dentro_triangulo(px, py, x0, y0, x1, y1, x2, y2);
                end
                3'd4: begin // escaleno
                    vx0 = ox11;                vy0 = oy11 + one_oct;
                    vx1 = ox11 + sz11;         vy1 = oy11 + three_oct;
                    vx2 = ox11 + one_third;    vy2 = oy11 + sz11;
                    x0 = vx0[9:0]; y0 = vy0[9:0];
                    x1 = vx1[9:0]; y1 = vy1[9:0];
                    x2 = vx2[9:0]; y2 = vy2[9:0];
                    ponto_dentro = dentro_triangulo(px, py, x0, y0, x1, y1, x2, y2);
                end
                3'd5: begin // quadrado
                    vx0 = ox11;           vy0 = oy11;
                    vx1 = ox11 + sz11;    vy1 = oy11 + sz11;
                    ponto_dentro = (px >= vx0[9:0]) && (px < vx1[9:0]) &&
                                   (py >= vy0[9:0]) && (py < vy1[9:0]);
                end
                default: begin
                    vx0 = ox11;           vy0 = oy11;
                    vx1 = ox11 + sz11;    vy1 = oy11 + sz11;
                    ponto_dentro = (px >= vx0[9:0]) && (px < vx1[9:0]) &&
                                   (py >= vy0[9:0]) && (py < vy1[9:0]);
                end
            endcase
        end
    endfunction

    always @(*) begin
        for (i = 0; i < 4; i = i + 1) begin
            if (!poly_habilitado[i])
                dentro[i] = 1'b0;
            else
                dentro[i] = ponto_dentro(
                    logico_x, logico_y,
                    poly_x[i], poly_y[i],
                    poly_size[i],
                    poly_tipo[i]
                );
        end

        achou    = 1'b0;
        vencedor = 2'd0;
        for (i = 0; i < 4; i = i + 1) begin
            if (dentro[i] && !achou) begin
                achou    = 1'b1;
                vencedor = i[1:0];
            end
        end
    end

    assign pixel_ativo = achou;
    assign cor_indice  = poly_cor[vencedor];

endmodule
