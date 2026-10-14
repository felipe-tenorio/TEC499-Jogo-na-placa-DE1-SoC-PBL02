#!/bin/bash
# Executa todos os testbenches unitários com Icarus Verilog
set -e
TB_DIR="$(cd "$(dirname "$0")" && pwd)"
RTL="$(cd "$TB_DIR/../project/PBL02_AFJ_Final_ev/PBL_com_H/PBL_com_H/my_first_hps-fpga_base/rtl" && pwd)"
OUT="$TB_DIR/sim_out"
mkdir -p "$OUT"
cd "$OUT"

run_one () {
    local name="$1"
    shift
    echo "------------------------------------------------------------"
    echo ">>> $name"
    iverilog -g2012 -o "sim_$name" "$@" && vvp "sim_$name"
    echo
}

run_one alu \
    "$RTL/alu.v" "$TB_DIR/tb_alu.v"

run_one gpr \
    "$RTL/gpr_bank.v" "$TB_DIR/tb_gpr_bank.v"

run_one fifo \
    "$RTL/fifo_cmd.v" "$TB_DIR/tb_fifo_cmd.v"

run_one pio \
    "$RTL/pio_cmd_iface.v" "$TB_DIR/tb_pio_cmd_iface.v"

run_one cu \
    "$RTL/control_unit.v" "$TB_DIR/tb_control_unit.v"

run_one isa \
    "$RTL/alu.v" "$RTL/gpr_bank.v" "$RTL/fifo_cmd.v" \
    "$RTL/control_unit.v" "$RTL/isa_core.v" \
    "$TB_DIR/tb_isa_core.v"

run_one banco \
    "$RTL/banco_registradores.v" "$TB_DIR/tb_banco_registradores.v"

echo "============================================================"
echo "Todos os testbenches unitários finalizados."
echo "Para integração, veja README_TESTBENCHES.md"
