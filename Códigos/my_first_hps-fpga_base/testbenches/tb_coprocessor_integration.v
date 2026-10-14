`timescale 1ns/1ps
//==============================================================================
// Testbench de INTEGRAÇÃO do coprocessor_core
//
// Cobre o caminho software -> PIO -> FIFO -> ISA -> banco gráfico
// (PLLs e RAMs substituídos pelos stubs em stubs_for_sim.v)
//
// Sequência de teste:
//   1. Reset
//   2. MOVI / ADD via PIO
//   3. SET_BG_X / SET_BG_Y
//   4. Modo fila (FILA_ON + PASSO)
//   5. HALT
//   6. Verificação de pio_status e LEDR
//==============================================================================
module tb_coprocessor_integration;

    reg         CLOCK_50;
    reg         reset_n;
    reg  [31:0] pio_cmd_data;
    reg         pio_cmd_push_lvl;
    wire [7:0]  pio_status;
    wire [16:0] dbg_probe;
    wire [7:0]  VGA_R, VGA_G, VGA_B;
    wire        VGA_HS, VGA_VS, VGA_CLK, VGA_BLANK_N, VGA_SYNC_N;
    wire [9:0]  LEDR;

    // DUT
    // NOTA: para simular, compile stubs_for_sim.v ANTES dos RTL originais
    // (os stubs sobrescrevem meu_pll, pllpara100 e as RAMs).
    coprocessor_core uut (
        .CLOCK_50(CLOCK_50),
        .reset_n(reset_n),
        .pio_cmd_data(pio_cmd_data),
        .pio_cmd_push_lvl(pio_cmd_push_lvl),
        .pio_status(pio_status),
        .dbg_probe(dbg_probe),
        .VGA_R(VGA_R), .VGA_G(VGA_G), .VGA_B(VGA_B),
        .VGA_HS(VGA_HS), .VGA_VS(VGA_VS), .VGA_CLK(VGA_CLK),
        .VGA_BLANK_N(VGA_BLANK_N), .VGA_SYNC_N(VGA_SYNC_N),
        .LEDR(LEDR)
    );

    // Clock 50 MHz
    always #10 CLOCK_50 = ~CLOCK_50;

    integer errors;

    // ---- Helpers de codificação ----
    function [31:0] enc_movi;
        input [15:0] imm;
        input [3:0]  rd;
        begin
            enc_movi = {imm, 4'd0, rd, 6'd21};
        end
    endfunction

    function [31:0] enc_r;
        input [5:0] opcode;
        input [3:0] rt, rs, rd;
        begin
            enc_r = {14'd0, rt, rs, rd, opcode};
        end
    endfunction

    function [31:0] mk_ctrl;
        input [3:0] c;
        begin
            mk_ctrl = {22'd0, c, 6'd62};
        end
    endfunction

    task tick; begin @(posedge CLOCK_50); #1; end endtask

    // Empurra uma palavra via PIO (borda de subida em push)
    task pio_push;
        input [31:0] word;
        begin
            pio_cmd_data     = word;
            pio_cmd_push_lvl = 0;
            tick; tick;
            pio_cmd_push_lvl = 1;
            tick; tick;
            pio_cmd_push_lvl = 0;
            tick; tick;
        end
    endtask

    // Espera busy baixar (instrução concluída) ou timeout
    task wait_idle;
        integer t;
        begin
            t = 0;
            while (LEDR[0] === 1'b1 && t < 200) begin
                tick;
                t = t + 1;
            end
            // margem extra
            repeat (5) tick;
        end
    endtask

    task check;
        input integer cond;
        input [255:0] label;
        begin
            if (!cond) begin
                $display("FAIL [%0s]  pio_status=%b LEDR=%b dbg=%h",
                         label, pio_status, LEDR, dbg_probe);
                errors = errors + 1;
            end else
                $display("PASS [%0s]", label);
        end
    endtask

    initial begin
        CLOCK_50 = 0;
        reset_n  = 0;
        pio_cmd_data = 0;
        pio_cmd_push_lvl = 0;
        errors = 0;
        $display("=== tb_coprocessor_integration ===");

        // Reset longo para PLL stubs
        repeat (20) tick;
        reset_n = 1;
        repeat (30) tick;

        check(LEDR[0] === 0, "not busy after reset");
        check(LEDR[3] === 1, "FIFO empty (LEDR[3]) after reset");

        // ------------------------------------------------------------------
        // 1) MOVI R1, 0x0010
        // ------------------------------------------------------------------
        pio_push(enc_movi(16'h0010, 4'd1));
        wait_idle;
        check(1, "MOVI R1 completed");

        // ------------------------------------------------------------------
        // 2) MOVI R2, 0x0007
        // ------------------------------------------------------------------
        pio_push(enc_movi(16'h0007, 4'd2));
        wait_idle;

        // ------------------------------------------------------------------
        // 3) ADD R3 = R1 + R2
        // ------------------------------------------------------------------
        pio_push(enc_r(6'd19, 4'd2, 4'd1, 4'd3));
        wait_idle;
        check(LEDR[4] === 0, "not halted after ADD");

        // ------------------------------------------------------------------
        // 4) SET_BG_X = 40  (opcode 4)
        // ------------------------------------------------------------------
        pio_push({8'd0, 8'd40, 10'd0, 6'd4});
        wait_idle;
        check(1, "SET_BG_X completed");

        // ------------------------------------------------------------------
        // 5) SET_BG_Y = 20  (opcode 5)
        // ------------------------------------------------------------------
        pio_push({8'd0, 8'd20, 10'd0, 6'd5});
        wait_idle;

        // ------------------------------------------------------------------
        // 6) Modo fila: FILA_ON, empilha 2 NOPs, PASSO x2, FILA_OFF
        // ------------------------------------------------------------------
        pio_push(mk_ctrl(4'd1)); // FILA_ON
        tick; tick;
        check(LEDR[1] === 1, "modo fila ativo (LEDR[1])");

        pio_push(32'h0000_0000); // NOP
        pio_push(32'h0000_0000); // NOP
        tick; tick;
        check(LEDR[3] === 0, "FIFO not empty while hold");

        // Executa 1ª
        pio_push(mk_ctrl(4'd3)); // PASSO
        wait_idle;

        // Executa 2ª
        pio_push(mk_ctrl(4'd3));
        wait_idle;

        pio_push(mk_ctrl(4'd2)); // FILA_OFF
        tick; tick;
        check(LEDR[1] === 0, "modo fila desligado");

        // ------------------------------------------------------------------
        // 7) HALT
        // ------------------------------------------------------------------
        pio_push({26'd0, 6'd63});
        wait_idle;
        check(LEDR[4] === 1, "HALT (LEDR[4])");

        // ------------------------------------------------------------------
        // 8) RESET_TOTAL via controle
        // ------------------------------------------------------------------
        pio_push(mk_ctrl(4'd5));
        repeat (20) tick;
        check(LEDR[4] === 0, "halt cleared after RESET_TOTAL");

        if (errors == 0)
            $display("=== tb_coprocessor_integration: ALL PASSED ===");
        else
            $display("=== tb_coprocessor_integration: %0d ERROR(S) ===", errors);

        $finish;
    end

    // Timeout de segurança
    initial begin
        #2_000_000;
        $display("TIMEOUT - simulation aborted");
        $finish;
    end

endmodule
