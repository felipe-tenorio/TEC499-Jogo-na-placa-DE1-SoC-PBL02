`timescale 1ns/1ps
//==============================================================================
// Stubs para simulação (substituem IPs Altera / RAMs geradas)
// Inclua este arquivo ANTES dos RTL originais na lista de compilação
// ou use +define+SIM_STUBS e wrappers condicionais.
//==============================================================================

// ---- PLL pixel (meu_pll) ----
module meu_pll (
    input  wire refclk,
    output wire outclk_0,
    output wire locked
);
    // Gera clock ~25 MHz a partir de 50 MHz (divide por 2)
    reg div = 0;
    always @(posedge refclk) div <= ~div;
    assign outclk_0 = div;
    assign locked   = 1'b1;
endmodule

// ---- PLL sistema 100 MHz (pllpara100) ----
module pllpara100 (
    input  wire refclk,
    input  wire rst,
    output wire outclk_0,
    output wire locked
);
    // Em simulação usamos o próprio CLOCK_50 como clk_sys
    assign outclk_0 = refclk;
    assign locked   = ~rst;
endmodule

// ---- RAMs comportamentais (mesmas portas dos IPs gerados) ----
module ram_tilemap (
    input  wire        clock,
    input  wire [7:0]  data,
    input  wire [10:0] rdaddress,
    input  wire [10:0] wraddress,
    input  wire        wren,
    output reg  [7:0]  q
);
    reg [7:0] mem [0:2047];
    integer i;
    initial for (i = 0; i < 2048; i = i + 1) mem[i] = 8'd0;
    always @(posedge clock) begin
        if (wren) mem[wraddress] <= data;
        q <= mem[rdaddress];
    end
endmodule

module ram_tilemapB (
    input  wire        clock,
    input  wire [7:0]  data,
    input  wire [10:0] rdaddress,
    input  wire [10:0] wraddress,
    input  wire        wren,
    output reg  [7:0]  q
);
    reg [7:0] mem [0:2047];
    integer i;
    initial for (i = 0; i < 2048; i = i + 1) mem[i] = 8'd0;
    always @(posedge clock) begin
        if (wren) mem[wraddress] <= data;
        q <= mem[rdaddress];
    end
endmodule

module ram_sprites (
    input  wire        clock,
    input  wire [7:0]  data,
    input  wire [13:0] rdaddress,
    input  wire [13:0] wraddress,
    input  wire        wren,
    output reg  [7:0]  q
);
    // Reduzido para simulação (apenas 256 entradas)
    reg [7:0] mem [0:255];
    integer i;
    initial for (i = 0; i < 256; i = i + 1) mem[i] = 8'd0;
    always @(posedge clock) begin
        if (wren) mem[wraddress[7:0]] <= data;
        q <= mem[rdaddress[7:0]];
    end
endmodule

module ram_padrao_tiles (
    input  wire        clock,
    input  wire [7:0]  data,
    input  wire [13:0] rdaddress,
    input  wire [13:0] wraddress,
    input  wire        wren,
    output reg  [7:0]  q
);
    reg [7:0] mem [0:255];
    integer i;
    initial for (i = 0; i < 256; i = i + 1) mem[i] = 8'd0;
    always @(posedge clock) begin
        if (wren) mem[wraddress[7:0]] <= data;
        q <= mem[rdaddress[7:0]];
    end
endmodule
