module coprocessor_core (
    input  wire        CLOCK_50,
    input  wire        reset_n,// ativo em 0 (hps_fpga_reset_n)
    //PIOs internos
    input  wire [31:0] pio_cmd_data,
    input  wire        pio_cmd_push_lvl,
    output wire [7:0]  pio_status,
    //Debug para probe do ISSP
    output wire [16:0] dbg_probe,//{fifo_count[5:0], estado[2:0], pio_status[7:0]}
    //VGA
    output wire [7:0]  VGA_R, VGA_G, VGA_B,
    output wire        VGA_HS, VGA_VS, VGA_CLK, VGA_BLANK_N, VGA_SYNC_N,
    //LEDs da placa (usados para debug)
    output wire [9:0]  LEDR
);

    wire reset = ~reset_n;
    wire clk_pix, pll_locked;
    wire clk_sys, pll_locked_100;

    meu_pll u_pll (
        .refclk(CLOCK_50),
        .outclk_0(clk_pix),
        .locked(pll_locked)
    );
    pllpara100 u_pll100 (
        .refclk(CLOCK_50),
        .rst(reset),
        .outclk_0(clk_sys),
        .locked(pll_locked_100)
    );
    wire rst = reset | ~pll_locked | ~pll_locked_100;

    //ISA
    wire cmd_push;
    wire [31:0] cmd_data;
    wire busy, done, fifo_full, fifo_empty, halt_out;
    wire gfx_wr_en;
    wire [15:0] gfx_addr;
    wire [8:0]  gfx_data;
    wire [5:0]  dbg_opcode;
    wire [2:0]  dbg_state;
    
	 //Escrita direta nas memorias de video(SET_TILE / WR_RAM)
    wire [3:0]  mem_we;// [0]=tilemap A [1]=tilemap B [2]=padroes tiles [3]=padroes sprites
    wire [13:0] mem_addr;
    wire [7:0]  mem_data;
    //Estado dos buffers sincronizado em clk_sys
    wire bg_frente_sys, fb_frente_sys;

    //VSYNC ->clk_sys
    wire vga_vs_int;
    reg  vs1, vs2, vs3;
    always @(posedge clk_sys) begin
        vs1 <= vga_vs_int;
        vs2 <= vs1;
        vs3 <= vs2;
    end
    wire vsync_borda_sys = vs2 & ~vs3;

    //Modo fila/ passo / reset: comandosDe controle do software (pio_cmd_iface)
    wire hold_sys; // 1 = FIFO so acumula
    wire step_pulso; // executa 1 instruçao
    wire rst_isa_sw; // reset do nucleo ISA por software
    wire rst_gfx_sw; // reset dos registradores graficos por software
    wire [5:0] fifo_count; // 0..32

    pio_cmd_iface u_pio ( //reponsavel por entregar os comandos a ISA
        .clk(clk_sys), .reset(rst),
        .pio_cmd_data(pio_cmd_data),
        .pio_cmd_push_lvl(pio_cmd_push_lvl),
        .pio_status(pio_status),
        .busy(busy),
        .fifo_full(fifo_full), .fifo_empty(fifo_empty), .fifo_count(fifo_count),
        .halt(halt_out), .vsync_flag(vsync_borda_sys),
        .bg_frente(bg_frente_sys), .fb_frente(fb_frente_sys),
        .cmd_push(cmd_push), .cmd_data(cmd_data),
        .modo_fila(hold_sys), .passo(step_pulso),
        .rst_isa(rst_isa_sw), .rst_gfx(rst_gfx_sw)
    );

    isa_core u_isa (
        .clk(clk_sys), .reset(rst | rst_isa_sw),
        .cmd_push(cmd_push), .cmd_data(cmd_data),
        .busy(busy), .done(done),
        .fifo_full(fifo_full), .fifo_empty(fifo_empty),
        .halt_out(halt_out),
        .vsync_borda(vsync_borda_sys),
        .hold(hold_sys), .step(step_pulso), .fifo_count(fifo_count),
        .gfx_wr_en(gfx_wr_en), .gfx_addr(gfx_addr), .gfx_data(gfx_data),
        .bg_frente(bg_frente_sys), .fb_frente(fb_frente_sys),
        .mem_we(mem_we), .mem_addr(mem_addr), .mem_data(mem_data),
        .dbg_opcode(dbg_opcode), .dbg_state(dbg_state)
    );
	
	//LEDS, quando acesos:
    assign LEDR[0] = busy;
    assign LEDR[1] = hold_sys; // modo fila ativo (comando CTRL FILA_ON)
    assign LEDR[2] = fifo_full; //indica fila cheia
    assign LEDR[3] = fifo_empty; //indica a fila vazia
    assign LEDR[4] = halt_out;
	 
    // No modo fila: mostra quantas instruçoes estao na FIFO; normal: ultimo opcode
    // (5 LEDs vao ate 31: com a fila cheia (32) satura em 11111 e LEDR[2] acende(fila cheia))
    wire [4:0] fifo_count_led = fifo_count[5] ? 5'b11111 : fifo_count[4:0];
    assign LEDR[9:5] = hold_sys ? fifo_count_led : dbg_opcode[4:0];

    assign dbg_probe = {fifo_count, dbg_state, pio_status}; //usado para debugar o estado da fifo, estado atual e status do coproc

    //Banco grafico
    wire [7:0] bg_scroll_x, bg_scroll_y;
    wire [4:0] sprite_sel;
    //Atributos achatados item i = bits [i*W +: W]
    wire [32*9-1:0] sprite_x_flat, sprite_y_flat;
    wire [32*5-1:0] sprite_padrao_flat;
    wire [31:0]     sprite_en_flat;
    wire [32*3-1:0] sprite_pri_flat;
    wire [31:0]     sprite_fliph_flat, sprite_flipv_flat;
    wire enable_bg, enable_sprite, enable_poly;
    wire [8:0] ovr_spr1_x;
    wire ovr_prioridade;
    wire sprite_over_poly;
    wire swap_bg_request, swap_fb_request;
    wire [4*10-1:0] poly_x_flat, poly_y_flat;
    wire [4*9-1:0]  poly_size_flat;
    wire [4*3-1:0]  poly_tipo_flat, poly_nverts_flat;
    wire [4*8-1:0]  poly_cor_flat;
    wire [3:0]      poly_habilitado_flat;
    wire [7:0] status_reg;
    wire endereco_invalido;

    banco_registradores u_regs (
        .clk_sys(clk_sys), .reset(rst | rst_gfx_sw),
        .wr_en(gfx_wr_en), .endereco(gfx_addr), .dado_in(gfx_data),
        .bg_scroll_x(bg_scroll_x), .bg_scroll_y(bg_scroll_y),
        .sprite_sel(sprite_sel),
        .sprite_x_flat(sprite_x_flat), .sprite_y_flat(sprite_y_flat),
        .sprite_padrao_flat(sprite_padrao_flat), .sprite_en_flat(sprite_en_flat),
        .sprite_pri_flat(sprite_pri_flat), .sprite_fliph_flat(sprite_fliph_flat),
        .sprite_flipv_flat(sprite_flipv_flat),
        .enable_bg(enable_bg), .enable_sprite(enable_sprite), .enable_poly(enable_poly),
        .ovr_spr1_x(ovr_spr1_x), .ovr_prioridade(ovr_prioridade),
        .swap_bg_request(swap_bg_request), .swap_fb_request(swap_fb_request),
        .sprite_over_poly(sprite_over_poly),
        .poly_x_flat(poly_x_flat), .poly_y_flat(poly_y_flat),
        .poly_size_flat(poly_size_flat),
        .poly_tipo_flat(poly_tipo_flat), .poly_nverts_flat(poly_nverts_flat),
        .poly_cor_flat(poly_cor_flat), .poly_habilitado_flat(poly_habilitado_flat),
        .status(status_reg),
        .estimulo_invalido(1'b0),
        .buffer_pronto(pll_locked_100),
        .endereco_invalido(endereco_invalido)
    );

    //Base grafica: mesma estrutura do PBL1
	// Sinais minimos para VGA.
    wire [10:0] tilemap_addr;
    wire [7:0]  tilemap_data_a, tilemap_data_b, tilemap_data;
    wire [12:0] padrao_addr_sprite;
    wire [7:0]  padrao_data_sprite;
    wire [13:0] padrao_addr;
    wire [7:0]  padrao_data;

    // Portas de escrita ligadas a ISA (SET_TILE / WR_RAM), mesmo clock (clk_sys)
    ram_tilemap ramA (
        .clock(clk_sys), .data(mem_data), .rdaddress(tilemap_addr),
        .wraddress(mem_addr[10:0]), .wren(mem_we[0]), .q(tilemap_data_a)
    );
    ram_tilemapB ramB (
        .clock(clk_sys), .data(mem_data), .rdaddress(tilemap_addr),
        .wraddress(mem_addr[10:0]), .wren(mem_we[1]), .q(tilemap_data_b)
    );
    ram_sprites rspt (
        .clock(clk_sys), .data(mem_data), .rdaddress({1'b0, padrao_addr_sprite}),
        .wraddress(mem_addr), .wren(mem_we[3]), .q(padrao_data_sprite)
    );
    ram_padrao_tiles ramtp (
        .clock(clk_sys), .data(mem_data), .rdaddress(padrao_addr),
        .wraddress(mem_addr), .wren(mem_we[2]), .q(padrao_data)
    );

    reg vsync_pix_ff1, vsync_pix_ff2;
    wire vsync_borda_pix = vsync_pix_ff2 & ~vsync_pix_ff1;
    always @(posedge clk_pix) begin
        vsync_pix_ff1 <= vga_vs_int;
        vsync_pix_ff2 <= vsync_pix_ff1;
    end

    reg swap_bg_tgl, swap_fb_tgl; //sincronizacao do swap_bg
    always @(posedge clk_sys) begin
        if (rst) begin
            swap_bg_tgl <= 1'b0;
            swap_fb_tgl <= 1'b0;
        end else begin
            if (swap_bg_request) swap_bg_tgl <= ~swap_bg_tgl;
            if (swap_fb_request) swap_fb_tgl <= ~swap_fb_tgl;
        end
    end

    reg [2:0] swap_bg_sync, swap_fb_sync;
    always @(posedge clk_pix) begin
        swap_bg_sync <= {swap_bg_sync[1:0], swap_bg_tgl};
        swap_fb_sync <= {swap_fb_sync[1:0], swap_fb_tgl};
    end
    wire swap_bg_pulso_pix = swap_bg_sync[1] ^ swap_bg_sync[2];
    wire swap_fb_pulso_pix = swap_fb_sync[1] ^ swap_fb_sync[2];

    //Troca do background (tilemap A <-> B), efetivada na VSYNC 
	 reg bg_buffer_ativo, swap_bg_pendente;   // 0 = tilemap A visível, 1 = B
    always @(posedge clk_pix) begin
        if (rst) begin
            bg_buffer_ativo  <= 1'b0;
            swap_bg_pendente <= 1'b0;
        end else begin
            if (vsync_borda_pix && swap_bg_pendente) begin
                bg_buffer_ativo  <= ~bg_buffer_ativo;
                swap_bg_pendente <= 1'b0;
            end
            if (swap_bg_pulso_pix) swap_bg_pendente <= 1'b1;
        end
    end
    assign tilemap_data = bg_buffer_ativo ? tilemap_data_b : tilemap_data_a;

    /*Os atributos so sao copiados para o dominio de pixel na VSYNC, e o
    quadro de fundo precisa ser composto inteiro com eles antes de ir
    para a frente*/
    reg swap_fb_pendente, swap_fb_armado;
    always @(posedge clk_pix) begin
        if (rst) begin
            swap_fb_pendente <= 1'b0;
            swap_fb_armado   <= 1'b0;
        end else begin
            if (vsync_borda_pix) begin
                swap_fb_armado   <= swap_fb_pendente;
                swap_fb_pendente <= 1'b0;
            end
            if (swap_fb_pulso_pix) swap_fb_pendente <= 1'b1;
        end
    end

    //Registrador de sincronismo
    localparam ATTR_W = 32*9 + 32*9 + 32*5 + 32 + 32*3 + 32 + 32   // sprites
                      + 4*10 + 4*10 + 4*9 + 4*3 + 4*3 + 4*8 + 4    // polígonos
                      + 4 + 8 + 8;                                 // layers/pri + scroll
    wire [ATTR_W-1:0] attr_sys = {
        sprite_x_flat, sprite_y_flat, sprite_padrao_flat, sprite_en_flat,
        sprite_pri_flat, sprite_fliph_flat, sprite_flipv_flat,
        poly_x_flat, poly_y_flat, poly_size_flat, poly_tipo_flat,
        poly_nverts_flat, poly_cor_flat, poly_habilitado_flat,
        enable_bg, enable_sprite, enable_poly, sprite_over_poly,
        bg_scroll_x, bg_scroll_y
    };
    reg [ATTR_W-1:0] attr_meta, attr_pix;
    always @(posedge clk_pix) begin
        attr_meta <= attr_sys;
        if (vsync_borda_pix) attr_pix <= attr_meta;
    end

    wire [32*9-1:0] p_sprite_x_flat, p_sprite_y_flat;
    wire [32*5-1:0] p_sprite_padrao_flat;
    wire [31:0]     p_sprite_en_flat;
    wire [32*3-1:0] p_sprite_pri_flat;
    wire [31:0]     p_sprite_fliph_flat, p_sprite_flipv_flat;
    wire [4*10-1:0] p_poly_x_flat, p_poly_y_flat;
    wire [4*9-1:0]  p_poly_size_flat;
    wire [4*3-1:0]  p_poly_tipo_flat, p_poly_nverts_flat;
    wire [4*8-1:0]  p_poly_cor_flat;
    wire [3:0]      p_poly_habilitado_flat;
    wire            p_enable_bg, p_enable_sprite, p_enable_poly, p_sprite_over_poly;
    wire [7:0]      bg_sx_q, bg_sy_q;
    assign {
        p_sprite_x_flat, p_sprite_y_flat, p_sprite_padrao_flat, p_sprite_en_flat,
        p_sprite_pri_flat, p_sprite_fliph_flat, p_sprite_flipv_flat,
        p_poly_x_flat, p_poly_y_flat, p_poly_size_flat, p_poly_tipo_flat,
        p_poly_nverts_flat, p_poly_cor_flat, p_poly_habilitado_flat,
        p_enable_bg, p_enable_sprite, p_enable_poly, p_sprite_over_poly,
        bg_sx_q, bg_sy_q
    } = attr_pix;

    //Escrita no frame buffer de fundo
    wire [9:0] next_x, next_y;
    wire       next_active;
    wire [8:0] lx0 = next_x[9:1];   // 640x480 -> 320x240 (pixel 2x2)
    wire [8:0] ly0 = next_y[9:1];
    // addr = y*320 + x = y*256 + y*64 + x
    wire [16:0] addr_lin = {ly0, 8'd0} + {2'b00, ly0, 6'd0} + {8'd0, lx0};

    reg [16:0] wa_s1, wa_s2, wa_s3, wa_s4;
    reg        wv_s1, wv_s2, wv_s3, wv_s4;
    always @(posedge clk_pix) begin
        wa_s1 <= addr_lin;  wv_s1 <= next_active & ~rst;
        wa_s2 <= wa_s1;     wv_s2 <= wv_s1;
        wa_s3 <= wa_s2;     wv_s3 <= wv_s2;
        wa_s4 <= wa_s3;     wv_s4 <= wv_s3;
    end

	 //Motores graficos
    wire [7:0] cor_bg_s3;  wire bg_valido_s3;
    motor_background u_bg (
        .clk_pix(clk_pix), .reset(rst),
        .logico_x(lx0), .logico_y(ly0), .req_valid(next_active),
        .scroll_x(bg_sx_q), .scroll_y(bg_sy_q),
        .tilemap_addr(tilemap_addr), .tilemap_data(tilemap_data),
        .padrao_addr(padrao_addr), .padrao_data(padrao_data),
        .cor_indice(cor_bg_s3), .cor_valida(bg_valido_s3)
    );

    wire [7:0] cor_sprite; wire sprite_ativo; // já em S4
    motor_sprites u_spr (
        .clk_pix(clk_pix), .reset(rst),
        .logico_x(lx0), .logico_y(ly0), .req_valid(next_active),
        .attr_x_flat(p_sprite_x_flat), .attr_y_flat(p_sprite_y_flat),
        .attr_padrao_flat(p_sprite_padrao_flat),
        .attr_en_flat(p_sprite_en_flat), .attr_pri_flat(p_sprite_pri_flat),
        .attr_fliph_flat(p_sprite_fliph_flat), .attr_flipv_flat(p_sprite_flipv_flat),
        .padrao_addr_sprite(padrao_addr_sprite),
        .padrao_data_sprite(padrao_data_sprite),
        .cor_indice(cor_sprite), .pixel_ativo(sprite_ativo)
    );

    wire [7:0] cor_poly_s3; wire poly_ativo_s3;
    rasterizador_multi u_poly (
        .clk_pix(clk_pix), .reset(rst),
        .logico_x($signed({1'b0, lx0})),
        .logico_y($signed({1'b0, ly0})),
        .poly_x_flat(p_poly_x_flat), .poly_y_flat(p_poly_y_flat),
        .poly_size_flat(p_poly_size_flat), .poly_tipo_flat(p_poly_tipo_flat),
        .poly_nverts_flat(p_poly_nverts_flat), .poly_cor_flat(p_poly_cor_flat),
        .poly_habilitado_flat(p_poly_habilitado_flat),
        .cor_indice(cor_poly_s3), .pixel_ativo(poly_ativo_s3)
    );

    //Alinha background e poligonos ao estágio S4 dos sprites
    reg [7:0] cor_bg, cor_poly;
    reg       bg_valido, poly_ativo;
    always @(posedge clk_pix) begin
        cor_bg   <= cor_bg_s3;    bg_valido  <= bg_valido_s3;
        cor_poly <= cor_poly_s3;  poly_ativo <= poly_ativo_s3;
    end

    wire [7:0] cor_final;
    compositor u_comp (
        .enable_bg(p_enable_bg), .enable_sprite(p_enable_sprite), .enable_poly(p_enable_poly),
        .bg_valido(bg_valido), .cor_bg(cor_bg),
        .sprite_ativo(sprite_ativo), .cor_sprite(cor_sprite),
        .poly_ativo(poly_ativo), .cor_poly(cor_poly),
        .sprite_over_poly(p_sprite_over_poly),
        .cor_final(cor_final)
    );

	//Frame buffer duplo
    wire        fb_swap_now = vsync_borda_pix && swap_fb_armado;
    wire        fb_buffer_ativo;
    wire [7:0]  fb_rd_data;

    frame_buffer_duplo u_fb (
        .clk          ( clk_pix ),
        .reset        ( rst ),
        .swap_now     ( fb_swap_now ),
        .buffer_ativo ( fb_buffer_ativo ),
        .wr_en        ( wv_s4 ),
        .wr_addr      ( wa_s4 ),
        .wr_data      ( cor_final ),
        .rd_addr      ( addr_lin ),
        .rd_data      ( fb_rd_data )
    );

    // Estado dos buffers visiveis -> clk_sys (ISA: SET_TILE alvo oculto/visivel; STATUS)
    reg [1:0] bg_frente_s, fb_frente_s;
    always @(posedge clk_sys) begin
        bg_frente_s <= {bg_frente_s[0], bg_buffer_ativo};
        fb_frente_s <= {fb_frente_s[0], fb_buffer_ativo};
    end
    assign bg_frente_sys = bg_frente_s[1];
    assign fb_frente_sys = fb_frente_s[1];

    // vga_driver: usado so como gerador de timing (sync + coordenada).
    wire vga_hs, vga_vs;
    vga_driver u_vga (
        .clock(clk_pix),
        .reset(rst),
        .color_in(8'd0),
        .next_x(next_x),
        .next_y(next_y),
        .next_active(next_active),
        .hsync(vga_hs),
        .vsync(vga_vs),
        .red(), .green(), .blue(),
        .sync(), .clk(), .blank()
    );
    assign vga_vs_int = vga_vs;

    //Aqui cor, HSYNC, VSYNC e BLANK sao registrados juntos, todos com o mesmo atraso
    reg       act_d1;
    reg [7:0] r_o, g_o, b_o;
    reg       hs_o, vs_o, blank_o;
    always @(posedge clk_pix) begin
        act_d1  <= next_active; //alinhado com fb_rd_data
        hs_o    <= vga_hs; //vga_hs ja tem 1 ciclo de registro
        vs_o    <= vga_vs;
        blank_o <= act_d1;
        r_o     <= act_d1 ? {fb_rd_data[7:5], 5'd0} : 8'd0;
        g_o     <= act_d1 ? {fb_rd_data[4:2], 5'd0} : 8'd0;
        b_o     <= act_d1 ? {fb_rd_data[1:0], 6'd0} : 8'd0;
    end

    assign VGA_R       = r_o;
    assign VGA_G       = g_o;
    assign VGA_B       = b_o;
    assign VGA_HS      = hs_o;
    assign VGA_VS      = vs_o;
    assign VGA_BLANK_N = blank_o; // 0 fora da area visivel
    assign VGA_SYNC_N  = 1'b0;
   // clock invertido coloca essa borda no meio do pixel, longe da troca dos dados.
    assign VGA_CLK     = ~clk_pix;

endmodule
