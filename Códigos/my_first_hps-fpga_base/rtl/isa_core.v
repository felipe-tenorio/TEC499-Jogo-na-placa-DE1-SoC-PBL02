module isa_core ( //Busca passiva
    input  wire        clk,
    input  wire        reset,
    //MMIO host (ISSP ou HPS Avalon)
    input  wire cmd_push, //endereço de leitura da FIFO
    input  wire [31:0] cmd_data, //dados
    output wire busy,
    output wire done, //pulse 1 ciclo
    output wire fifo_full,
    output wire fifo_empty,
    output wire halt_out,
    input  wire vsync_borda,
    //Modo fila
    input  wire hold, // 1 = so acumula na FIFO
    input  wire step, // pulso que executa 1 instruçao (com hold=1)
    output wire [5:0] fifo_count,    // ocupação da FIFO (0..32)
    //Escrita no banco gráfico PBL1
    output wire gfx_wr_en,
    output wire [15:0] gfx_addr,
    output wire [8:0] gfx_data,
    //Escrita nas memorias de video (SET_TILE / WR_RAM)
    input  wire bg_frente, // tilemap visivel (sincronizado em clk)
    input  wire fb_frente, // frame buffer visivel (sincronizado em clk)
    output wire [3:0] mem_we, // [0]=tilemap A [1]=tilemap B [2]=pad. tiles [3]=pad. sprites
    output wire [13:0] mem_addr,
    output wire [7:0] mem_data,
    // Debug
    output wire [5:0] dbg_opcode,
    output wire [2:0] dbg_state
);
	//FIFO
	wire        fifo_pop;
    wire [31:0] fifo_rd;
    wire [5:0]  fifo_cnt;

    fifo_cmd #(.DEPTH(32), .ADDRW(5)) u_fifo (
        .clk(clk), .reset(reset),
        .wr_en(cmd_push), .wr_data(cmd_data), .full(fifo_full),
        .rd_en(fifo_pop), .rd_data(fifo_rd), .empty(fifo_empty),
        .count(fifo_cnt)
    );

    //A fifo tem saida registrada: o dado so fica valido no ciclo apos o pop.
    reg pop_d;
    reg [31:0] ir;
    always @(posedge clk) begin
        if (reset) begin
            pop_d <= 1'b0;
            ir    <= 32'd0;
        end else begin
            pop_d <= fifo_pop;
            if (pop_d) ir <= fifo_rd;
        end
    end

    wire gpr_we;
    wire [3:0] gpr_wa;
    wire [2:0] alu_op;
    wire use_imm;
    wire [15:0] rd1, rd2, alu_y;
	 // MOVI: Imm16  e  MOV = pass Rs
    wire [15:0] gpr_wd = use_imm ? ir[29:14] :(ir[5:0] == 6'd22) ? rd1 : alu_y;
	 
	//Banco de resgistrador
    gpr_bank u_gpr (
        .clk(clk), .reset(reset),
        .we(gpr_we), .wa(gpr_wa), .wd(gpr_wd),
        .ra1(ir[13:10]),   // Rs
        .ra2(ir[17:14]),   // Rt
        .rd1(rd1), .rd2(rd2)
    );
	
	//Ula simples
    alu u_alu (
        .a(rd1),
        .b(use_imm ? 16'd0 : rd2),
        .op(alu_op),
        .result(alu_y)
    );
	
	//Unidade de controle
    wire cu_busy, done_pulse, halt_flag;
    wire [2:0] cu_state;
    wire cu_gfx_we;
    wire [15:0] cu_gfx_addr;
    wire [8:0]  cu_gfx_data;

    control_unit u_cu (
        .clk(clk), .reset(reset),
        .fifo_empty(fifo_empty), .fifo_pop(fifo_pop),
        .ir(ir), .vsync_borda(vsync_borda),
        .hold(hold), .step(step),
        .busy(cu_busy), .done_pulse(done_pulse), .halt_flag(halt_flag),
        .gpr_we(gpr_we), .gpr_wa(gpr_wa), .alu_op(alu_op), .use_imm(use_imm),
        .rs_val(rd1), .rt_val(rd2),
        .gfx_wr_en(cu_gfx_we), .gfx_addr(cu_gfx_addr), .gfx_data(cu_gfx_data),
        .bg_frente(bg_frente), .fb_frente(fb_frente),
        .mem_we(mem_we), .mem_addr(mem_addr), .mem_data(mem_data),
        .state(cu_state)
    );
	
	//Atribuiçao dos sinais
    assign busy      = cu_busy | halt_flag;
    assign done      = done_pulse;
    assign halt_out  = halt_flag;
    assign gfx_wr_en = cu_gfx_we;
    assign gfx_addr  = cu_gfx_addr;
    assign gfx_data  = cu_gfx_data;
    assign dbg_opcode= ir[5:0];
    assign dbg_state = cu_state;
    assign fifo_count= fifo_cnt;
endmodule
