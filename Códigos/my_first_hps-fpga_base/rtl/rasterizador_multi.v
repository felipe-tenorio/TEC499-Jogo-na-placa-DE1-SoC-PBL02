module rasterizador_multi (
    input wire clk_pix, reset,
    input wire signed [9:0] logico_x, logico_y,

    // Parametros dos 4 poligonos
    // (arrays achatados: slot i = bits [i*W +: W])
    input wire [4*10-1:0] poly_x_flat,
    input wire [4*10-1:0] poly_y_flat,
    input wire [4*9-1:0] poly_size_flat,
    input wire [4*3-1:0] poly_tipo_flat,
    input wire [4*3-1:0] poly_nverts_flat,
    input wire [4*8-1:0] poly_cor_flat,
    input wire [3:0] poly_habilitado_flat,

    output reg pixel_ativo,
    output reg  [7:0] cor_indice
);

    integer i;

	 //geometria por slot (registrada, independe do pixel)
    reg signed [11:0] vx0 [0:3], vy0 [0:3];
    reg signed [11:0] vx1 [0:3], vy1 [0:3];
    reg signed [11:0] vx2 [0:3], vy2 [0:3];
    reg signed [11:0] dx01 [0:3], dy01 [0:3];
    reg signed [11:0] dx12 [0:3], dy12 [0:3];
    reg signed [11:0] dx20 [0:3], dy20 [0:3];
    reg eh_ret [0:3]; // 1 = retangulo/quadrado (AABB)
    reg vazio [0:3]; // size = 0(triangulo degenerado)
    reg hab [0:3];
    reg [7:0] cor [0:3];

    reg signed [11:0] ox, oy, sz, half, three_q, one_third, three_oct, one_oct;
    reg signed [11:0] ax0, ay0, ax1, ay1, ax2, ay2;
    reg               ret;

    always @(posedge clk_pix or posedge reset) begin
        if (reset) begin
            for (i = 0; i < 4; i = i + 1) begin
                vx0[i] <= 0; vy0[i] <= 0; vx1[i] <= 0; vy1[i] <= 0;
                vx2[i] <= 0; vy2[i] <= 0;
                dx01[i] <= 0; dy01[i] <= 0; dx12[i] <= 0; dy12[i] <= 0;
                dx20[i] <= 0; dy20[i] <= 0;
                eh_ret[i] <= 1'b1; vazio[i] <= 1'b1;
                hab[i] <= 1'b0; cor[i] <= 8'd0;
            end
        end else begin
            for (i = 0; i < 4; i = i + 1) begin
                ox        = {{2{poly_x_flat[i*10+9]}}, poly_x_flat[i*10 +: 10]};
                oy        = {{2{poly_y_flat[i*10+9]}}, poly_y_flat[i*10 +: 10]};
                sz        = {3'b000, poly_size_flat[i*9 +: 9]};
                half      = sz >>> 1;
                three_q   = (sz * 3) >>> 2;
                one_third = sz / 3;
                three_oct = (sz * 3) >>> 3;
                one_oct   = sz >>> 3;

                ret = 1'b0;
                ax2 = ox; ay2 = oy;
                case (poly_tipo_flat[i*3 +: 3])
                    3'd0: begin // retangulo: largura=sz, altura=3/4*sz
                        ret = 1'b1;
                        ax0 = ox; ay0 = oy;
                        ax1 = ox + sz; ay1 = oy + three_q;
                    end
                    3'd1: begin // triangulo retangulo (angulo em baixo-esquerda)
                        ax0 = ox; ay0 = oy;
                        ax1 = ox; ay1 = oy + sz;
                        ax2 = ox + sz; ay2 = oy + sz;
                    end
                    3'd2: begin // isosceles (apice em cima)
                        ax0 = ox + half; ay0 = oy;
                        ax1 = ox; ay1 = oy + sz;
                        ax2 = ox + sz; ay2 = oy + sz;
                    end
                    3'd3: begin // isosceles (apice em baixo)
                        ax0 = ox; ay0 = oy;
                        ax1 = ox + sz; ay1 = oy;
                        ax2 = ox + half; ay2 = oy + sz;
                    end
                    3'd4: begin // escaleno
                        ax0 = ox; ay0 = oy + one_oct;
                        ax1 = ox + sz; ay1 = oy + three_oct;
                        ax2 = ox + one_third; ay2 = oy + sz;
                    end
                    default: begin // 5 = quadrado
                        ret = 1'b1;
                        ax0 = ox; ay0 = oy;
                        ax1 = ox + sz; ay1 = oy + sz;
                    end
                endcase

                vx0[i] <= ax0; vy0[i] <= ay0;
                vx1[i] <= ax1; vy1[i] <= ay1;
                vx2[i] <= ax2; vy2[i] <= ay2;
                dx01[i] <= ax1 - ax0; dy01[i] <= ay1 - ay0;
                dx12[i] <= ax2 - ax1; dy12[i] <= ay2 - ay1;
                dx20[i] <= ax0 - ax2; dy20[i] <= ay0 - ay2;
                eh_ret[i] <= ret;
                vazio[i]  <= (sz == 0);
                hab[i]    <= poly_habilitado_flat[i];
                cor[i]    <= poly_cor_flat[i*8 +: 8];
            end
        end
    end

//Diferencas dos pixels (teste dde retangulo)
    wire signed [11:0] px = {{2{logico_x[9]}}, logico_x};
    wire signed [11:0] py = {{2{logico_y[9]}}, logico_y};

    reg signed [11:0] dpx0 [0:3], dpy0 [0:3];
    reg signed [11:0] dpx1 [0:3], dpy1 [0:3];
    reg signed [11:0] dpx2 [0:3], dpy2 [0:3];
    reg               in_ret_s1 [0:3];

    always @(posedge clk_pix) begin
        for (i = 0; i < 4; i = i + 1) begin
            dpx0[i] <= px - vx0[i]; dpy0[i] <= py - vy0[i];
            dpx1[i] <= px - vx1[i]; dpy1[i] <= py - vy1[i];
            dpx2[i] <= px - vx2[i]; dpy2[i] <= py - vy2[i];
            in_ret_s1[i] <= (px >= vx0[i]) && (px < vx1[i]) &&
                            (py >= vy0[i]) && (py < vy1[i]);
        end
    end


    //funçoes de aresta (12x12 -> 24 bits, soma em 26 bits)
    reg signed [25:0] e0 [0:3], e1 [0:3], e2 [0:3];
    reg               in_ret_s2 [0:3];

    always @(posedge clk_pix) begin
        for (i = 0; i < 4; i = i + 1) begin
            e0[i] <= dpx0[i] * dy01[i] - dpy0[i] * dx01[i];
            e1[i] <= dpx1[i] * dy12[i] - dpy1[i] * dx12[i];
            e2[i] <= dpx2[i] * dy20[i] - dpy2[i] * dx20[i];
            in_ret_s2[i] <= in_ret_s1[i];
        end
    end

//Prioridade e cor (verifica se o pixel esta dentro ou fora do poligono)
    reg       dentro [0:3];
    reg       achou;
    reg [1:0] vencedor;

    always @(*) begin
        for (i = 0; i < 4; i = i + 1) begin
            if (!hab[i] || vazio[i])
                dentro[i] = 1'b0;
            else if (eh_ret[i])
                dentro[i] = in_ret_s2[i];
            else
                dentro[i] = (e0[i] >= 0 && e1[i] >= 0 && e2[i] >= 0) ||
                            (e0[i] <= 0 && e1[i] <= 0 && e2[i] <= 0);
        end

        achou    = 1'b0;
        vencedor = 2'd0;
        for (i = 3; i >= 0; i = i - 1) begin
            if (dentro[i]) begin
                achou    = 1'b1;
                vencedor = i[1:0];
            end
        end
    end
		//Define os pixels e a cor deles
    always @(posedge clk_pix or posedge reset) begin
        if (reset) begin
            pixel_ativo <= 1'b0;
            cor_indice  <= 8'd0;
        end else begin
            pixel_ativo <= achou;
            cor_indice  <= cor[vencedor];
        end
    end

endmodule
