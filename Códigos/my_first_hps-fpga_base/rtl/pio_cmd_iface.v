module pio_cmd_iface (
    input  wire clk,
    input  wire reset,
    //PIOs exportados
    input  wire [31:0] pio_cmd_data, // PIO output 32b (HPS -> FPGA)
    input  wire pio_cmd_push_lvl, // PIO output 1b  (HPS -> FPGA)
    output wire [7:0] pio_status, // PIO input  8b  (FPGA -> HPS)
    //Status do núcleo ISA
    input  wire busy,
    input  wire fifo_full,
    input  wire fifo_empty,
    input  wire [5:0] fifo_count,
    input  wire halt,
    input  wire vsync_flag,
    input  wire bg_frente, // tilemap visivel: 0=A 1=B
    input  wire fb_frente, // frame buffer visivel: 0=A 1=B
    //Saida para a FIFO da ISA
    output reg cmd_push,
    output reg [31:0] cmd_data,
    //Controle vindo do software
    output reg modo_fila, // 1 = FIFO so acumula
    output reg passo, // pulso de 1 ciclo: executa 1 instruçao
    output reg rst_isa, // pulso: reset do nucleo ISA
    output reg rst_gfx // pulso: reset dos registradores graficos
);

    localparam [5:0] OP_CTRL = 6'd62;
    localparam [3:0] 
	 C_FILA_ON = 4'd1,// Ativa o modo fila
	 C_FILA_OFF = 4'd2, // Desativa o modo fila
	 C_PASSO = 4'd3, //Executa uma intruçaao
	 C_RESET_ISA = 4'd4,//reseta apenas a isa
	 C_RESET_TOTAL = 4'd5,//reseta todo sistema (isa e os graficos)
	 C_VER_QTD = 4'd6, //seleciona status da FIFO
	 C_VER_STATUS = 4'd7; //seleciona status normal

    // Detecçao de borda de subida no push vindo do PIO
    reg push_d1, push_d2;
	 //Identifica uma transição de 0 para 1
    // push_d1 guarda o sinal sincronizado no estagio atual e push_d2 guarda uma versao atrasada
	 
    wire push_edge = push_d1 & ~push_d2;
	 // Os 6 bits menos significativos contem o opcode
    // Se ele for 62, a palavra e um comando de controle
    wire eh_ctrl = (pio_cmd_data[5:0] == OP_CTRL);
	 // Os bits [9:6] identificam qual comando de controle deve ser executado
    wire [3:0] ctrl_cmd = pio_cmd_data[9:6];

    reg ver_qtd;// pagina do pio_status
    reg [1:0] rst_cnt; // reset por software dura 4 ciclos
    reg rst_total_reg;

    always @(posedge clk) begin
        if (reset) begin
            push_d1   <= 1'b0;
            push_d2   <= 1'b0;
            cmd_push  <= 1'b0;
            cmd_data  <= 32'd0;
            modo_fila <= 1'b0;
            passo     <= 1'b0;
            ver_qtd   <= 1'b0;
            rst_cnt   <= 2'd0;
            rst_total_reg <= 1'b0;
            rst_isa   <= 1'b0;
            rst_gfx   <= 1'b0;
        end else begin
            push_d1  <= pio_cmd_push_lvl;
            push_d2  <= push_d1;
            cmd_push <= 1'b0;
            passo    <= 1'b0;

            //reset por software: mantem rst_isa/rst_gfx por 4 ciclos
            if (rst_cnt != 2'd0) begin
                rst_cnt <= rst_cnt - 2'd1;
                rst_isa <= 1'b1;
                rst_gfx <= rst_total_reg;
            end else begin
                rst_isa <= 1'b0;
                rst_gfx <= 1'b0;
                rst_total_reg <= 1'b0;
            end

            if (push_edge) begin
                if (eh_ctrl) begin
                    case (ctrl_cmd)
                        C_FILA_ON:     modo_fila <= 1'b1;
                        C_FILA_OFF:    modo_fila <= 1'b0;
                        C_PASSO:       passo     <= 1'b1;
                        C_RESET_ISA:   begin rst_cnt <= 2'd3; rst_isa <= 1'b1; end
                        C_RESET_TOTAL: begin
                            rst_cnt <= 2'd3; rst_isa <= 1'b1; rst_gfx <= 1'b1;
                            rst_total_reg <= 1'b1; modo_fila <= 1'b0;
                        end
                        C_VER_QTD:     ver_qtd <= 1'b1;
                        C_VER_STATUS:  ver_qtd <= 1'b0;
                        default: ;
                    endcase
                end else if (!fifo_full) begin
                    cmd_data <= pio_cmd_data;
                    cmd_push <= 1'b1;
						  
                end
					 // Se a FIFO estiver cheia, a instruçao e descartada por esta interface
            end
        end
    end
	//cada bit representa uma informacao
    wire [7:0] status_normal = {fb_frente, bg_frente, halt, vsync_flag,
                                fifo_empty, fifo_full, modo_fila, busy};
	//informa a quantidade da FIFO
    wire [7:0] status_qtd    = {1'b1, modo_fila, fifo_count};

    assign pio_status = ver_qtd ? status_qtd : status_normal; //define o status para o ARM

endmodule
