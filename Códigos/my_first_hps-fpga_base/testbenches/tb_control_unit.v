`timescale 1ns/1ps
//==============================================================================
// Testbench: control_unit (isolado)
// Fornece IR e sinais de FIFO/GPR e verifica transições + saídas gfx/alu
//==============================================================================
module tb_control_unit;

    reg         clk, reset;
    reg         fifo_empty;
    wire        fifo_pop;
    reg  [31:0] ir;
    reg         vsync_borda, hold, step;
    wire        busy, done_pulse, halt_flag;
    wire        gpr_we;
    wire [3:0]  gpr_wa;
    wire [2:0]  alu_op;
    wire        use_imm;
    reg  [15:0] rs_val, rt_val;
    wire        gfx_wr_en;
    wire [15:0] gfx_addr;
    wire [8:0]  gfx_data;
    reg         bg_frente, fb_frente;
    wire [3:0]  mem_we;
    wire [13:0] mem_addr;
    wire [7:0]  mem_data;
    wire [2:0]  state;

    control_unit uut (
        .clk(clk), .reset(reset),
        .fifo_empty(fifo_empty), .fifo_pop(fifo_pop),
        .ir(ir), .vsync_borda(vsync_borda),
        .hold(hold), .step(step),
        .busy(busy), .done_pulse(done_pulse), .halt_flag(halt_flag),
        .gpr_we(gpr_we), .gpr_wa(gpr_wa), .alu_op(alu_op), .use_imm(use_imm),
        .rs_val(rs_val), .rt_val(rt_val),
        .gfx_wr_en(gfx_wr_en), .gfx_addr(gfx_addr), .gfx_data(gfx_data),
        .bg_frente(bg_frente), .fb_frente(fb_frente),
        .mem_we(mem_we), .mem_addr(mem_addr), .mem_data(mem_data),
        .state(state)
    );

    always #5 clk = ~clk;

    integer errors;

    // Estados
    localparam S_IDLE=0, S_FETCH=1, S_DECODE=2, S_EXECUTE=3, S_WB=4, S_HALT=5;

    task tick; begin @(posedge clk); #1; end endtask

    task check;
        input integer cond;
        input [255:0] label;
        begin
            if (!cond) begin
                $display("FAIL [%0s] (state=%0d)", label, state);
                errors = errors + 1;
            end else
                $display("PASS [%0s]", label);
        end
    endtask

    // Avança até um estado alvo ou timeout
    task wait_state;
        input [2:0] target;
        integer t;
        begin
            t = 0;
            while (state !== target && t < 40) begin
                tick;
                t = t + 1;
            end
        end
    endtask

    initial begin
        clk = 0; reset = 1;
        fifo_empty = 1; ir = 0;
        vsync_borda = 0; hold = 0; step = 0;
        rs_val = 16'h0010; rt_val = 16'h0005;
        bg_frente = 0; fb_frente = 0;
        errors = 0;
        $display("=== tb_control_unit ===");

        tick; tick;
        reset = 0;
        tick;
        check(state === S_IDLE && busy === 0, "IDLE after reset");

        // ---- NOP ----
        fifo_empty = 0;
        ir = 32'h0000_0000; // NOP
        // IDLE -> FETCH (pop)
        tick;
        check(state === S_FETCH && fifo_pop === 1, "FETCH + pop");
        tick; // DECODE
        check(state === S_DECODE, "DECODE");
        tick; // EXECUTE
        check(state === S_EXECUTE, "EXECUTE NOP");
        tick; // WB
        check(state === S_WB && done_pulse === 1, "WB + done");
        tick; // back to IDLE
        fifo_empty = 1;
        check(state === S_IDLE, "back to IDLE");

        // ---- MOVI (opcode 21) ----
        // Imm=0x00AA, Rd=3  =>  {imm[31:14], Rs, Rd, op}
        ir = {16'h00AA, 4'd0, 4'd3, 6'd21};
        fifo_empty = 0;
        wait_state(S_EXECUTE);
        check(use_imm === 1 && gpr_we === 1 && gpr_wa === 4'd3, "MOVI sets use_imm+we");
        wait_state(S_WB);
        fifo_empty = 1;
        wait_state(S_IDLE);

        // ---- ADD (opcode 19) ----
        ir = {14'd0, 4'd2, 4'd1, 4'd4, 6'd19}; // Rt=2 Rs=1 Rd=4
        fifo_empty = 0;
        wait_state(S_EXECUTE);
        check(alu_op === 3'b000 && gpr_we === 1, "ADD alu_op=000");
        wait_state(S_WB);
        fifo_empty = 1;
        wait_state(S_IDLE);

        // ---- SET_BG_X (opcode 4) ----
        ir = {8'd0, 8'd77, 10'd0, 6'd4};
        fifo_empty = 0;
        wait_state(S_EXECUTE);
        check(gfx_wr_en === 1 && gfx_addr === 16'h0001 && gfx_data[7:0] === 8'd77,
              "SET_BG_X writes addr 1 data 77");
        wait_state(S_WB);
        fifo_empty = 1;
        wait_state(S_IDLE);

        // ---- HALT ----
        ir = {26'd0, 6'd63};
        fifo_empty = 0;
        wait_state(S_HALT);
        check(halt_flag === 1, "HALT flag set");

        if (errors == 0)
            $display("=== tb_control_unit: ALL PASSED ===");
        else
            $display("=== tb_control_unit: %0d ERROR(S) ===", errors);
        $finish;
    end

endmodule
