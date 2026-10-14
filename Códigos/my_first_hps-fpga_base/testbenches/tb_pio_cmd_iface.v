`timescale 1ns/1ps
//==============================================================================
// Testbench: pio_cmd_iface
// - Detecção de borda de push
// - Comandos de controle (FILA_ON/OFF, PASSO, RESET)
// - Encaminhamento de instruções normais para a FIFO
//==============================================================================
module tb_pio_cmd_iface;

    reg         clk, reset;
    reg  [31:0] pio_cmd_data;
    reg         pio_cmd_push_lvl;
    wire [7:0]  pio_status;

    reg         busy, fifo_full, fifo_empty, halt, vsync_flag;
    reg  [5:0]  fifo_count;
    reg         bg_frente, fb_frente;

    wire        cmd_push;
    wire [31:0] cmd_data;
    wire        modo_fila, passo, rst_isa, rst_gfx;

    pio_cmd_iface uut (
        .clk(clk), .reset(reset),
        .pio_cmd_data(pio_cmd_data),
        .pio_cmd_push_lvl(pio_cmd_push_lvl),
        .pio_status(pio_status),
        .busy(busy), .fifo_full(fifo_full), .fifo_empty(fifo_empty),
        .fifo_count(fifo_count), .halt(halt), .vsync_flag(vsync_flag),
        .bg_frente(bg_frente), .fb_frente(fb_frente),
        .cmd_push(cmd_push), .cmd_data(cmd_data),
        .modo_fila(modo_fila), .passo(passo),
        .rst_isa(rst_isa), .rst_gfx(rst_gfx)
    );

    always #5 clk = ~clk;

    integer errors;

    // Helper: monta palavra de controle OP_CTRL=62
    function [31:0] mk_ctrl;
        input [3:0] c;
        begin
            mk_ctrl = {22'd0, c, 6'd62};
        end
    endfunction

    task tick; begin @(posedge clk); #1; end endtask

    task push_word;
        input [31:0] word;
        begin
            pio_cmd_data     = word;
            pio_cmd_push_lvl = 0;
            tick;
            pio_cmd_push_lvl = 1;   // borda de subida
            tick;
            pio_cmd_push_lvl = 0;
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
        clk = 0; reset = 1;
        pio_cmd_data = 0; pio_cmd_push_lvl = 0;
        busy = 0; fifo_full = 0; fifo_empty = 1; halt = 0;
        vsync_flag = 0; fifo_count = 0;
        bg_frente = 0; fb_frente = 0;
        errors = 0;
        $display("=== tb_pio_cmd_iface ===");

        tick; tick;
        reset = 0;
        tick;
        check(modo_fila === 0 && cmd_push === 0, "idle after reset");

        // Instrução normal (NOP = opcode 0)
        push_word(32'h0000_0000);
        check(cmd_push === 1 && cmd_data === 32'h0000_0000, "normal instr pushed");

        // FILA_ON
        push_word(mk_ctrl(4'd1));
        check(modo_fila === 1, "FILA_ON");

        // PASSO
        push_word(mk_ctrl(4'd3));
        check(passo === 1, "PASSO pulse");
        tick;
        check(passo === 0, "PASSO deasserted");

        // FILA_OFF
        push_word(mk_ctrl(4'd2));
        check(modo_fila === 0, "FILA_OFF");

        // RESET_ISA
        push_word(mk_ctrl(4'd4));
        check(rst_isa === 1 && rst_gfx === 0, "RESET_ISA");
        // dura ~4 ciclos
        tick; tick; tick; tick; tick;
        check(rst_isa === 0, "RESET_ISA ended");

        // RESET_TOTAL
        push_word(mk_ctrl(4'd5));
        check(rst_isa === 1 && rst_gfx === 1, "RESET_TOTAL");

        // FIFO cheia: não deve empurrar instrução normal
        fifo_full = 1;
        push_word(32'h0000_0013); // ADD
        check(cmd_push === 0, "push blocked when fifo_full");

        if (errors == 0)
            $display("=== tb_pio_cmd_iface: ALL PASSED ===");
        else
            $display("=== tb_pio_cmd_iface: %0d ERROR(S) ===", errors);
        $finish;
    end

endmodule
