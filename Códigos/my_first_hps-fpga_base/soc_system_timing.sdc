#************************************************************
# THIS IS A WIZARD-GENERATED FILE.                           
#
# Version 13.1.0 Build 162 10/23/2013 SJ Full Version
#
#************************************************************

# Copyright (C) 1991-2013 Altera Corporation
# Your use of Altera Corporation's design tools, logic functions 
# and other software and tools, and its AMPP partner logic 
# functions, and any output files from any of the foregoing 
# (including device programming or simulation files), and any 
# associated documentation or information are expressly subject 
# to the terms and conditions of the Altera Program License 
# Subscription Agreement, Altera MegaCore Function License 
# Agreement, or other applicable license agreement, including, 
# without limitation, that your use is for the sole purpose of 
# programming logic devices manufactured by Altera and sold by 
# Altera or its authorized distributors.  Please refer to the 
# applicable agreement for further details.



# Clock constraints

create_clock -name "clock_50_1" -period 20.000ns [get_ports {CLOCK_50}]
create_clock -name "clock_50_2" -period 20.000ns [get_ports {CLOCK2_50}]
create_clock -name "clock_50_3" -period 20.000ns [get_ports {CLOCK3_50}]
create_clock -name "clock_50_4" -period 20.000ns [get_ports {CLOCK4_50}]
create_clock -name "clock_27_1" -period 37.000ns [get_ports {TD_CLK27}]


# Automatically constrain PLL and other generated clocks
derive_pll_clocks -create_base_clocks

# Automatically calculate clock uncertainty to jitter and other effects.
derive_clock_uncertainty

# tsu/th constraints

# tco constraints

# tpd constraints

# ----------------------------------------------------------------------------
# Coprocessador: cruzamentos clk_sys (100 MHz) <-> clk_pix (25 MHz)
# Os registradores abaixo sao o 1o estagio de sincronizadores; o dado so e
# usado depois de estabilizar (copia na VSYNC / 2-3 flops), entao o caminho
# ate eles nao precisa ser analisado como sincrono.
# ----------------------------------------------------------------------------
set_false_path -to [get_registers {*u_coproc|attr_meta[*]}]
set_false_path -to [get_registers {*u_coproc|swap_bg_sync[0]}]
set_false_path -to [get_registers {*u_coproc|swap_fb_sync[0]}]
set_false_path -to [get_registers {*u_coproc|bg_frente_s[0]}]
set_false_path -to [get_registers {*u_coproc|fb_frente_s[0]}]
set_false_path -to [get_registers {*u_coproc|vs1}]

# ----------------------------------------------------------------------------
# Modo fila / ISSP: entradas assíncronas (SW[1], KEY[0..1], ISSP via JTAG)
# Todas passam por sincronizadores; o dado ISSP[31:0] é estável quando o
# toggle do bit 32 atravessa os flops.
# ----------------------------------------------------------------------------
set_false_path -to [get_registers {*u_coproc|hold_s[0]}]
set_false_path -to [get_registers {*u_coproc|step_s[0]}]
set_false_path -to [get_registers {*u_coproc|u_pio|tgl_d1}]
set_false_path -to [get_registers {*u_coproc|u_pio|push_d1}]
set_false_path -from [get_keepers {*issp_inst*}] -to [get_registers {*u_coproc|u_pio|*}]
