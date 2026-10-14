/* isa_coproc.h — Codificação das instruções do Coprocessador Gráfico
 *
 * Formato (bits 31 -> 0), OPCODE nos 6 bits menos significativos:
 *   R : 0[31:18] | Rt[17:14] | Rs[13:10] | Rd[9:6] | OPCODE[5:0]
 *   I : Imm[31:14]           | Rs[13:10] | Rd[9:6] | OPCODE[5:0]
 *   G : campos gráficos[31:6]                      | OPCODE[5:0]
 *   J : alvo/flags[31:6]                           | OPCODE[5:0]
 *
 * Nos tipos G/J os campos são descritos relativos a f = instr[31:6],
 * ou seja, o bit f[k] fica no bit (k+6) da palavra.
 */
#ifndef ISA_COPROC_H
#define ISA_COPROC_H

#include <stdint.h>

/* ---------------- Opcodes ---------------- */
enum {
    OP_NOP      = 0,
    OP_WAIT_VS  = 1,
    OP_SWAP_FB  = 2,   /* troca do frame buffer duplo (na VSYNC)      */
    OP_SET_LAYER= 3,
    OP_SET_BG_X = 4,
    OP_SET_BG_Y = 5,
    OP_MOV_BG   = 6,
    OP_SPR_POS  = 7,
    OP_SPR_MOV  = 8,
    OP_SPR_CFG  = 9,
    OP_SPR_HIDE = 10,
    OP_SPR_SEL  = 11,
    OP_SPR_PAT  = 12,
    OP_PLY_DRAW = 13,
    OP_PLY_ADJ  = 14,
    OP_PLY_COR  = 15,
    OP_PLY_MOV  = 16,
    OP_PLY_HIDE = 17,
    OP_SET_PRI  = 18,
    OP_ADD      = 19,
    OP_SUB      = 20,
    OP_MOVI     = 21,
    OP_MOV      = 22,
    OP_AND      = 23,
    OP_OR       = 24,
    OP_JMP      = 25,
    OP_BEQ      = 26,
    OP_SWAP_BG  = 27,  /* troca tilemap A <-> B do background (na VSYNC) */
    OP_SET_TILE = 28,  /* escreve um tile no tilemap                  */
    OP_WR_RAM   = 29,  /* escrita genérica nas memórias de vídeo      */
    OP_CTRL     = 62,  /* comando do host: não entra na FIFO          */
    OP_HALT     = 63
};

/* Alvos de SET_TILE */
#define TILE_OCULTO   0u   /* tilemap que NÃO está na tela (back)  */
#define TILE_VISIVEL  1u   /* tilemap que está na tela (front)     */
#define TILE_AMBOS    2u   /* escreve em A e B                     */

/* Memórias de WR_RAM */
#define MEM_TILEMAP_A   0u /* 11 bits de endereço (0..2047)         */
#define MEM_TILEMAP_B   1u
#define MEM_PAD_TILES   2u /* 14 bits: tile*64 + y*8 + x            */
#define MEM_PAD_SPRITES 3u /* 14 bits                               */

/* ---------------- Montadores de formato ---------------- */
#define F(v, msb, lsb)  ((((uint32_t)(v)) & ((1u << ((msb)-(lsb)+1)) - 1u)) << (lsb))
#define G(op, f26)      (((uint32_t)(f26) << 6) | ((op) & 0x3Fu))
#define ENC_R(op, rd, rs, rt) (F(rt,17,14) | F(rs,13,10) | F(rd,9,6) | ((op) & 0x3Fu))
#define ENC_I(op, imm18, rs, rd) (F(imm18,31,14) | F(rs,13,10) | F(rd,9,6) | ((op) & 0x3Fu))

/* ---------------- Instruções ---------------- */
#define I_NOP()            G(OP_NOP, 0)
#define I_WAIT_VS()        G(OP_WAIT_VS, 0)
#define I_SWAP_FB()        G(OP_SWAP_FB, 0)
#define I_SWAP_BG()        G(OP_SWAP_BG, 0)
#define I_HALT()           G(OP_HALT, 0)
/* CTRL cmd: 1 FILA_ON, 2 FILA_OFF, 3 PASSO, 4 RESET_ISA, 5 RESET_TOTAL,
 *           6 VER_QTD, 7 VER_STATUS */
#define I_CTRL(cmd)        G(OP_CTRL, F(cmd,3,0))

#define I_SET_LAYER(bg, spr, poly) G(OP_SET_LAYER, F(poly,2,2) | F(spr,1,1) | F(bg,0,0))
#define I_SET_BG_X(v)      G(OP_SET_BG_X, F(v,7,0))
#define I_SET_BG_Y(v)      G(OP_SET_BG_Y, F(v,7,0))
#define I_SET_PRI(spo)     G(OP_SET_PRI, F(spo,0,0))

#define I_SPR_POS(idx, x, y)   G(OP_SPR_POS, F(idx,25,21) | F(x,20,12) | F(y,11,3))
#define I_SPR_CFG(idx, en, fh, fv, pri) \
    G(OP_SPR_CFG, F(idx,25,21) | F(en,4,4) | F(fh,3,3) | F(fv,2,2) | F(pri,1,0))
#define I_SPR_HIDE(idx)        G(OP_SPR_HIDE, F(idx,25,21))
#define I_SPR_SEL(idx)         G(OP_SPR_SEL, F(idx,4,0))
#define I_SPR_PAT(idx, pat)    G(OP_SPR_PAT, F(idx,25,21) | F(pat,4,0))

#define I_PLY_DRAW(slot, tipo, x, y) \
    G(OP_PLY_DRAW, F(slot,25,24) | F(tipo,23,21) | F(x,20,12) | F(y,11,3))
#define I_PLY_COR(slot, cor)   G(OP_PLY_COR, F(slot,25,24) | F(cor,7,0))
#define I_PLY_HIDE(slot)       G(OP_PLY_HIDE, F(slot,25,24))

/* SET_TILE alvo, linha(0..29), coluna(0..39), tile(0..255) */
#define I_SET_TILE(alvo, lin, col, tile) \
    G(OP_SET_TILE, F(alvo,25,24) | F(lin,23,19) | F(col,18,13) | F(tile,7,0))
/* WR_RAM mem, endereço(14 bits), dado(8 bits) */
#define I_WR_RAM(mem, addr, dado) \
    G(OP_WR_RAM, F(mem,25,24) | F(addr,21,8) | F(dado,7,0))

/* Tipo I com campos específicos (posições absolutas na palavra) */
#define I_MOVI(rd, imm16)      (F(imm16,29,14) | F(rd,9,6) | OP_MOVI)
#define I_MOV_BG(rs_dx, rt_dy) (F(rt_dy,17,14) | F(rs_dx,13,10) | OP_MOV_BG)
#define I_SPR_MOV(idx, rs, rt) (F(idx,22,18) | F(rt,17,14) | F(rs,13,10) | OP_SPR_MOV)
#define I_PLY_ADJ(slot, size)  (F(slot,24,23) | F(size,22,14) | OP_PLY_ADJ)
#define I_PLY_MOV(slot, rs, rt)(F(slot,19,18) | F(rt,17,14) | F(rs,13,10) | OP_PLY_MOV)
#define I_BEQ(rs, rt, off)     (F(off,31,18) | F(rt,17,14) | F(rs,13,10) | OP_BEQ)
#define I_JMP(alvo)            G(OP_JMP, F(alvo,25,0))

/* Tipo R */
#define I_ADD(rd, rs, rt)  ENC_R(OP_ADD, rd, rs, rt)
#define I_SUB(rd, rs, rt)  ENC_R(OP_SUB, rd, rs, rt)
#define I_AND(rd, rs, rt)  ENC_R(OP_AND, rd, rs, rt)
#define I_OR(rd, rs, rt)   ENC_R(OP_OR,  rd, rs, rt)
#define I_MOV(rd, rs)      ENC_R(OP_MOV, rd, rs, 0)

/* ---------------- STATUS (pio_status) ---------------- */
#define ST_BUSY       (1u << 0)
#define ST_MODO_FILA  (1u << 1)   /* 1 = FIFO só acumula (CTRL FILA_ON)  */
#define ST_FIFO_FULL  (1u << 2)
#define ST_FIFO_EMPTY (1u << 3)
#define ST_VSYNC      (1u << 4)
#define ST_HALT       (1u << 5)
#define ST_BG_FRENTE  (1u << 6)   /* 0 = tilemap A na tela, 1 = B      */
#define ST_FB_FRENTE  (1u << 7)   /* 0 = frame buffer A na tela, 1 = B */

#endif /* ISA_COPROC_H */
