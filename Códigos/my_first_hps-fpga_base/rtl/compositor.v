module compositor (
    input  wire enable_bg, enable_sprite, enable_poly,
    input  wire [7:0] cor_bg,
    input  wire bg_valido,
    input  wire [7:0] cor_poly,   input wire poly_ativo,
    input  wire [7:0] cor_sprite, input wire sprite_ativo,
    // 1 = sprite > poligono > background (padrao inicial) ,0 = poligono > sprite > background
    input  wire sprite_over_poly,
    output reg  [7:0] cor_final
);

    // Prioridade configuravel entre sprite e poligono; background sempre por ultimo.
    wire sprite_hit = enable_sprite && sprite_ativo && (cor_sprite != 8'd0);
    wire poly_hit = enable_poly && poly_ativo   && (cor_poly   != 8'd0);
    wire bg_hit = enable_bg  && bg_valido;

    always @(*) begin
        if (sprite_over_poly) begin
            // sprite > poligono > background
            if (sprite_hit)
                cor_final = cor_sprite;
            else if (poly_hit)
                cor_final = cor_poly;
            else if (bg_hit)
                cor_final = cor_bg;
            else
                cor_final = 8'd0;
        end else begin
            // poligono > sprite > background
            if (poly_hit)
                cor_final = cor_poly;
            else if (sprite_hit)
                cor_final = cor_sprite;
            else if (bg_hit)
                cor_final = cor_bg;
            else
                cor_final = 8'd0;
        end
    end

endmodule
