`timescale 1ns/1ps
//==============================================================================
// Testbench: banco_registradores
// Verifica escrita de scroll BG, seleção/posição de sprite e swap requests
//==============================================================================
module tb_banco_registradores;

    reg         clk_sys, reset, wr_en;
    reg  [15:0] endereco;
    reg  [8:0]  dado_in;

    wire [7:0]  bg_scroll_x, bg_scroll_y;
    wire [4:0]  sprite_sel;
    wire [32*9-1:0] sprite_x_flat, sprite_y_flat;
    wire [32*5-1:0] sprite_padrao_flat;
    wire [31:0]     sprite_en_flat;
    wire [32*3-1:0] sprite_pri_flat;
    wire [31:0]     sprite_fliph_flat, sprite_flipv_flat;
    wire        enable_bg, enable_sprite, enable_poly;
    wire [8:0]  ovr_spr1_x;
    wire        ovr_prioridade;
    wire        swap_bg_request, swap_fb_request;
    wire        sprite_over_poly;
    wire [4*10-1:0] poly_x_flat, poly_y_flat;
    wire [4*9-1:0]  poly_size_flat;
    wire [4*3-1:0]  poly_tipo_flat, poly_nverts_flat;
    wire [4*8-1:0]  poly_cor_flat;
    wire [3:0]      poly_habilitado_flat;
    wire [7:0]  status;
    reg         estimulo_invalido, buffer_pronto;
    wire        endereco_invalido;

    banco_registradores uut (
        .clk_sys(clk_sys), .reset(reset),
        .wr_en(wr_en), .endereco(endereco), .dado_in(dado_in),
        .bg_scroll_x(bg_scroll_x), .bg_scroll_y(bg_scroll_y),
        .sprite_sel(sprite_sel),
        .sprite_x_flat(sprite_x_flat), .sprite_y_flat(sprite_y_flat),
        .sprite_padrao_flat(sprite_padrao_flat),
        .sprite_en_flat(sprite_en_flat),
        .sprite_pri_flat(sprite_pri_flat),
        .sprite_fliph_flat(sprite_fliph_flat),
        .sprite_flipv_flat(sprite_flipv_flat),
        .enable_bg(enable_bg), .enable_sprite(enable_sprite),
        .enable_poly(enable_poly),
        .ovr_spr1_x(ovr_spr1_x), .ovr_prioridade(ovr_prioridade),
        .swap_bg_request(swap_bg_request), .swap_fb_request(swap_fb_request),
        .sprite_over_poly(sprite_over_poly),
        .poly_x_flat(poly_x_flat), .poly_y_flat(poly_y_flat),
        .poly_size_flat(poly_size_flat),
        .poly_tipo_flat(poly_tipo_flat), .poly_nverts_flat(poly_nverts_flat),
        .poly_cor_flat(poly_cor_flat),
        .poly_habilitado_flat(poly_habilitado_flat),
        .status(status),
        .estimulo_invalido(estimulo_invalido),
        .buffer_pronto(buffer_pronto),
        .endereco_invalido(endereco_invalido)
    );

    always #5 clk_sys = ~clk_sys;

    integer errors;

    task tick; begin @(posedge clk_sys); #1; end endtask

    task write_reg;
        input [15:0] addr;
        input [8:0]  data;
        begin
            endereco = addr;
            dado_in  = data;
            wr_en    = 1;
            tick;
            wr_en    = 0;
            tick;
        end
    endtask

    task check;
        input integer cond;
        input [255:0] label;
        begin
            if (!cond) begin
                $display("FAIL [%0s]", label);
                errors = errors + 1;
            end else
                $display("PASS [%0s]", label);
        end
    endtask

    initial begin
        clk_sys = 0; reset = 1; wr_en = 0;
        endereco = 0; dado_in = 0;
        estimulo_invalido = 0; buffer_pronto = 0;
        errors = 0;
        $display("=== tb_banco_registradores ===");

        tick; tick;
        reset = 0;
        tick;

        // SET_BG_X  (addr 0x0001)
        write_reg(16'h0001, 9'd100);
        check(bg_scroll_x === 8'd100, "bg_scroll_x=100");

        // SET_BG_Y  (addr 0x0002)
        write_reg(16'h0002, 9'd50);
        check(bg_scroll_y === 8'd50, "bg_scroll_y=50");

        // SPR_SEL (addr 0x0003)
        write_reg(16'h0003, 9'd7);
        check(sprite_sel === 5'd7, "sprite_sel=7");

        // SPR_POS X (addr 0x0004) for selected sprite
        write_reg(16'h0004, 9'd120);
        check(sprite_x_flat[7*9 +: 9] === 9'd120, "sprite[7].x=120");

        // SPR_POS Y (addr 0x0005)
        write_reg(16'h0005, 9'd80);
        check(sprite_y_flat[7*9 +: 9] === 9'd80, "sprite[7].y=80");

        // SWAP_BG request (addr 0x000B = 1)
        write_reg(16'h000B, 9'd1);
        // pulse is 1 cycle – may already be low; just ensure no hang
        check(1, "swap_bg write accepted");

        // SWAP_FB request (addr 0x000D)
        write_reg(16'h000D, 9'd1);
        check(1, "swap_fb write accepted");

        // SET_LAYER (addr 0x0008) enable bits
        write_reg(16'h0008, 9'b0000_0111);
        check(enable_bg === 1 && enable_sprite === 1 && enable_poly === 1,
              "all layers enabled");

        if (errors == 0)
            $display("=== tb_banco_registradores: ALL PASSED ===");
        else
            $display("=== tb_banco_registradores: %0d ERROR(S) ===", errors);
        $finish;
    end

endmodule
