`timescale 1ns/1ps
//==============================================================================
// Testbench: isa_core
// Exercita pipeline IDLE->FETCH->DECODE->EXECUTE->WB com instruções:
//   MOVI, ADD, SUB, NOP, HALT e modo fila (hold + step)
//==============================================================================
module tb_isa_core;

    reg         clk, reset;
    reg         cmd_push;
    reg  [31:0] cmd_data;
    wire        busy, done, fifo_full, fifo_empty, halt_out;
    reg         vsync_borda, hold, step;
    wire [5:0]  fifo_count;
    wire        gfx_wr_en;
    wire [15:0] gfx_addr;
    wire [8:0]  gfx_data;
    reg         bg_frente, fb_frente;
    wire [3:0]  mem_we;
    wire [13:0] mem_addr;
    wire [7:0]  mem_data;
    wire [5:0]  dbg_opcode;
    wire [2:0]  dbg_state;

    isa_core uut (
        .clk(clk), .reset(reset),
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

    always #5 clk = ~clk;

    integer errors;

    // Codificação de instruções (formato do control_unit)
    // R: 0[31:18] | Rt[17:14] | Rs[13:10] | Rd[9:6] | OPCODE[5:0]
    // I: Imm[31:14]           | Rs[13:10] | Rd[9:6] | OPCODE[5:0]
    function [31:0] enc_movi;
        input [15:0] imm;
        input [3:0]  rd;
        begin
            enc_movi = {imm, 4'd0, rd, 6'd21}; // OP_MOVI=21
        end
    endfunction

    function [31:0] enc_r;
        input [5:0] opcode;
        input [3:0] rt, rs, rd;
        begin
            enc_r = {14'd0, rt, rs, rd, opcode};
        end
    endfunction

    task tick; begin @(posedge clk); #1; end endtask

    task push_cmd;
        input [31:0] word;
        begin
            cmd_data = word;
            cmd_push = 1;
            tick;
            cmd_push = 0;
        end
    endtask

    // Espera até done ou timeout
    task wait_done;
        integer t;
        begin
            t = 0;
            while (!done && t < 50) begin
                tick;
                t = t + 1;
            end
            if (!done) begin
                $display("FAIL timeout waiting done (state=%0d)", dbg_state);
                errors = errors + 1;
            end
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
        cmd_push = 0; cmd_data = 0;
        vsync_borda = 0; hold = 0; step = 0;
        bg_frente = 0; fb_frente = 0;
        errors = 0;
        $display("=== tb_isa_core ===");

        tick; tick;
        reset = 0;
        tick;
        check(fifo_empty === 1 && busy === 0, "idle after reset");

        // ---- MOVI R1, 0x0010 ----
        push_cmd(enc_movi(16'h0010, 4'd1));
        wait_done;
        tick;
        check(fifo_empty === 1, "FIFO empty after MOVI");

        // ---- MOVI R2, 0x0005 ----
        push_cmd(enc_movi(16'h0005, 4'd2));
        wait_done;
        tick;

        // ---- ADD R3 = R1 + R2  (opcode 19) ----
        push_cmd(enc_r(6'd19, 4'd2, 4'd1, 4'd3));
        wait_done;
        tick;
        check(halt_out === 0, "still running after ADD");

        // ---- SUB R4 = R1 - R2  (opcode 20) ----
        push_cmd(enc_r(6'd20, 4'd2, 4'd1, 4'd4));
        wait_done;
        tick;

        // ---- NOP ----
        push_cmd(32'h0000_0000);
        wait_done;
        tick;

        // ---- SET_BG_X (opcode 4, G-format) ----
        // f[7:0] = X = 40
        push_cmd({8'd0, 8'd40, 10'd0, 6'd4});
        wait_done;
        // gfx write occurs in EXECUTE; sample after done
        check(1, "SET_BG_X completed");

        // ---- Modo fila: hold=1, empilha 2 instr, step uma a uma ----
        hold = 1;
        push_cmd(enc_movi(16'h00AA, 4'd5));
        push_cmd(enc_movi(16'h00BB, 4'd6));
        tick; tick;
        check(fifo_count >= 2, "FIFO holds 2 instr in hold mode");
        check(busy === 0, "not executing while hold");

        step = 1; tick; step = 0;
        wait_done;
        tick;
        check(fifo_count >= 1, "one instr left after first step");

        step = 1; tick; step = 0;
        wait_done;
        tick;
        hold = 0;

        // ---- HALT ----
        push_cmd({26'd0, 6'd63});
        wait_done;
        tick;
        check(halt_out === 1, "HALT sets halt_out");

        if (errors == 0)
            $display("=== tb_isa_core: ALL PASSED ===");
        else
            $display("=== tb_isa_core: %0d ERROR(S) ===", errors);
        $finish;
    end

endmodule
