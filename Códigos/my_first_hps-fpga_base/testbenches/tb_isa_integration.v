`timescale 1ns/1ps
//==============================================================================
// Testbench de integração LEVE: pio_cmd_iface + isa_core + banco_registradores
// Não depende de PLLs, VGA nem RAMs de vídeo.
// Ideal para validar o caminho de comandos sem o resto do pipeline gráfico.
//==============================================================================
module tb_isa_integration;

    reg         clk, reset;
    // PIO
    reg  [31:0] pio_cmd_data;
    reg         pio_cmd_push_lvl;
    wire [7:0]  pio_status;
    // ISA status
    wire        busy, done, fifo_full, fifo_empty, halt_out;
    wire [5:0]  fifo_count;
    wire [5:0]  dbg_opcode;
    wire [2:0]  dbg_state;
    // Controle
    wire        cmd_push;
    wire [31:0] cmd_data;
    wire        hold, step, rst_isa, rst_gfx;
    // Gráfico
    wire        gfx_wr_en;
    wire [15:0] gfx_addr;
    wire [8:0]  gfx_data;
    wire [3:0]  mem_we;
    wire [13:0] mem_addr;
    wire [7:0]  mem_data;
    reg         vsync_borda, bg_frente, fb_frente;

    // ---- pio ----
    pio_cmd_iface u_pio (
        .clk(clk), .reset(reset),
        .pio_cmd_data(pio_cmd_data),
        .pio_cmd_push_lvl(pio_cmd_push_lvl),
        .pio_status(pio_status),
        .busy(busy), .fifo_full(fifo_full), .fifo_empty(fifo_empty),
        .fifo_count(fifo_count), .halt(halt_out),
        .vsync_flag(vsync_borda),
        .bg_frente(bg_frente), .fb_frente(fb_frente),
        .cmd_push(cmd_push), .cmd_data(cmd_data),
        .modo_fila(hold), .passo(step),
        .rst_isa(rst_isa), .rst_gfx(rst_gfx)
    );

    // ---- ISA ----
    isa_core u_isa (
        .clk(clk), .reset(reset | rst_isa),
        .cmd_push(cmd_push), .cmd_data(cmd_data),
        .busy(busy), .done(done),
        .fifo_full(fifo_full), .fifo_empty(fifo_empty),
        .halt_out(halt_out),
        .vsync_borda(vsync_borda),
        .hold(hold), .step(step), .fifo_count(fifo_count),
        .gfx_wr_en(gfx_wr_en), .gfx_addr(gfx_addr), .gfx_data(gfx_data),
        .bg_frente(bg_frente), .fb_frente(fb_frente),
        .mem_we(mem_we), .mem_addr(mem_addr), .mem_data(mem_data),
        .dbg_opcode(dbg_opcode), .dbg_state(dbg_state)
    );

    // ---- Banco gráfico ----
    wire [7:0] bg_scroll_x, bg_scroll_y;
    wire [4:0] sprite_sel;
    wire [32*9-1:0] sprite_x_flat, sprite_y_flat;
    wire [32*5-1:0] sprite_padrao_flat;
    wire [31:0] sprite_en_flat, sprite_fliph_flat, sprite_flipv_flat;
    wire [32*3-1:0] sprite_pri_flat;
    wire enable_bg, enable_sprite, enable_poly;
    wire [8:0] ovr_spr1_x;
    wire ovr_prioridade, swap_bg_request, swap_fb_request, sprite_over_poly;
    wire [4*10-1:0] poly_x_flat, poly_y_flat;
    wire [4*9-1:0]  poly_size_flat;
    wire [4*3-1:0]  poly_tipo_flat, poly_nverts_flat;
    wire [4*8-1:0]  poly_cor_flat;
    wire [3:0] poly_habilitado_flat;
    wire [7:0] status_reg;
    wire endereco_invalido;

    banco_registradores u_regs (
        .clk_sys(clk), .reset(reset | rst_gfx),
        .wr_en(gfx_wr_en), .endereco(gfx_addr), .dado_in(gfx_data),
        .bg_scroll_x(bg_scroll_x), .bg_scroll_y(bg_scroll_y),
        .sprite_sel(sprite_sel),
        .sprite_x_flat(sprite_x_flat), .sprite_y_flat(sprite_y_flat),
        .sprite_padrao_flat(sprite_padrao_flat), .sprite_en_flat(sprite_en_flat),
        .sprite_pri_flat(sprite_pri_flat),
        .sprite_fliph_flat(sprite_fliph_flat), .sprite_flipv_flat(sprite_flipv_flat),
        .enable_bg(enable_bg), .enable_sprite(enable_sprite), .enable_poly(enable_poly),
        .ovr_spr1_x(ovr_spr1_x), .ovr_prioridade(ovr_prioridade),
        .swap_bg_request(swap_bg_request), .swap_fb_request(swap_fb_request),
        .sprite_over_poly(sprite_over_poly),
        .poly_x_flat(poly_x_flat), .poly_y_flat(poly_y_flat),
        .poly_size_flat(poly_size_flat),
        .poly_tipo_flat(poly_tipo_flat), .poly_nverts_flat(poly_nverts_flat),
        .poly_cor_flat(poly_cor_flat), .poly_habilitado_flat(poly_habilitado_flat),
        .status(status_reg),
        .estimulo_invalido(1'b0), .buffer_pronto(1'b1),
        .endereco_invalido(endereco_invalido)
    );

    always #5 clk = ~clk;

    integer errors;

    function [31:0] enc_movi;
        input [15:0] imm; input [3:0] rd;
        begin enc_movi = {imm, 4'd0, rd, 6'd21}; end
    endfunction

    function [31:0] enc_r;
        input [5:0] op; input [3:0] rt, rs, rd;
        begin enc_r = {14'd0, rt, rs, rd, op}; end
    endfunction

    function [31:0] mk_ctrl;
        input [3:0] c;
        begin mk_ctrl = {22'd0, c, 6'd62}; end
    endfunction

    task tick; begin @(posedge clk); #1; end endtask

    task pio_push;
        input [31:0] word;
        begin
            pio_cmd_data = word;
            pio_cmd_push_lvl = 0; tick;
            pio_cmd_push_lvl = 1; tick;
            pio_cmd_push_lvl = 0; tick;
        end
    endtask

    task wait_idle;
        integer t;
        begin
            t = 0;
            while (busy && t < 80) begin tick; t = t + 1; end
            repeat (3) tick;
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
        clk = 0; reset = 1;
        pio_cmd_data = 0; pio_cmd_push_lvl = 0;
        vsync_borda = 0; bg_frente = 0; fb_frente = 0;
        errors = 0;
        $display("=== tb_isa_integration ===");

        tick; tick; reset = 0; tick;
        check(!busy && fifo_empty, "idle after reset");

        // MOVI R1=16, R2=7, ADD R3=R1+R2
        pio_push(enc_movi(16'h0010, 4'd1)); wait_idle;
        pio_push(enc_movi(16'h0007, 4'd2)); wait_idle;
        pio_push(enc_r(6'd19, 4'd2, 4'd1, 4'd3)); wait_idle;
        check(!halt_out, "ADD done, not halted");

        // SET_BG_X=40, SET_BG_Y=25
        pio_push({8'd0, 8'd40, 10'd0, 6'd4}); wait_idle;
        check(bg_scroll_x === 8'd40, "bg_scroll_x=40 via ISA");
        pio_push({8'd0, 8'd25, 10'd0, 6'd5}); wait_idle;
        check(bg_scroll_y === 8'd25, "bg_scroll_y=25 via ISA");

        // Modo fila
        pio_push(mk_ctrl(4'd1)); // FILA_ON
        tick;
        check(hold === 1, "hold active");
        pio_push(enc_movi(16'h00AA, 4'd5));
        pio_push(enc_movi(16'h00BB, 4'd6));
        tick; tick;
        check(fifo_count >= 2, "2 instr queued");
        pio_push(mk_ctrl(4'd3)); wait_idle; // PASSO
        pio_push(mk_ctrl(4'd3)); wait_idle;
        pio_push(mk_ctrl(4'd2)); // FILA_OFF
        tick;
        check(hold === 0, "hold off");

        // HALT + RESET_ISA
        pio_push({26'd0, 6'd63}); wait_idle;
        check(halt_out === 1, "halted");
        pio_push(mk_ctrl(4'd4)); // RESET_ISA
        repeat (10) tick;
        check(halt_out === 0, "halt cleared by RESET_ISA");

        if (errors == 0)
            $display("=== tb_isa_integration: ALL PASSED ===");
        else
            $display("=== tb_isa_integration: %0d ERROR(S) ===", errors);
        $finish;
    end

endmodule
