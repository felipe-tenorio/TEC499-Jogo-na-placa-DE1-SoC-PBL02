/*
 * coproc_driver.h — interface C do driver em assembly (coproc_driver.s)
 *
 * Nada depende das chaves ou botões da placa: o modo fila, o passo a
 * passo e o reset são comandos CTRL (opcode 62) enviados pelo driver.
 *
 * Uso típico:
 *     if (coproc_init() < 0) { ...erro... }
 *     coproc_send(instrucao);              // envia e espera terminar
 *     ...
 *     coproc_modo_fila(1);                 // monta uma fila sem executar
 *     coproc_enfileira(i1); coproc_enfileira(i2);
 *     coproc_passo();                      // executa só a primeira
 *     coproc_modo_fila(0); coproc_espera();  // executa o resto
 *     ...
 *     coproc_reset(0);                     // sai do HALT sem reprogramar
 *     coproc_close();
 *
 * Compilar:  gcc -O2 -Wall -o prog prog.c coproc_driver.s
 */
#ifndef COPROC_DRIVER_H
#define COPROC_DRIVER_H

#include <stdint.h>

/* Retornos */
#define COPROC_OK              0
#define COPROC_ERR_FIFO_CHEIA (-1)  /* FIFO cheia por 2 s (modo fila ligado?)     */
#define COPROC_ERR_TIMEOUT    (-2)  /* não terminou em 2 s (modo fila ligado?)    */
#define COPROC_ERR_HALT       (-3)  /* coprocessador em HALT: use coproc_reset(0) */
#define COPROC_ERR_NAO_INIT   (-4)  /* coproc_init() não foi chamado              */
#define COPROC_ERR_HW         (-5)  /* .sof gravado não tem o comando CTRL        */

/* Bits de pio_status */
#define COPROC_ST_BUSY        (1u << 0)
#define COPROC_ST_MODO_FILA   (1u << 1)  /* 1 = FIFO só acumula                */
#define COPROC_ST_FIFO_FULL   (1u << 2)
#define COPROC_ST_FIFO_EMPTY  (1u << 3)
#define COPROC_ST_VSYNC       (1u << 4)
#define COPROC_ST_HALT        (1u << 5)
#define COPROC_ST_BG_FRENTE   (1u << 6)  /* 0 = tilemap A na tela, 1 = B       */
#define COPROC_ST_FB_FRENTE   (1u << 7)  /* 0 = frame buffer A na tela, 1 = B  */

/* Comandos CTRL (palavra = (cmd << 6) | 62; não entram na FIFO) */
#define COPROC_CTRL_FILA_ON     1
#define COPROC_CTRL_FILA_OFF    2
#define COPROC_CTRL_PASSO       3
#define COPROC_CTRL_RESET_ISA   4
#define COPROC_CTRL_RESET_TOTAL 5
#define COPROC_CTRL_VER_QTD     6
#define COPROC_CTRL_VER_STATUS  7

/* ---- básico ---- */
int  coproc_init(void);                 /* abre /dev/mem (sudo). 0 ou -errno      */
void coproc_close(void);
int  coproc_status(void);               /* pio_status 0..255 ou COPROC_ERR_NAO_INIT */
int  coproc_send(uint32_t instr);       /* enfileira e espera terminar            */
int  coproc_enfileira(uint32_t instr);  /* só enfileira (não espera executar)     */
int  coproc_espera(void);               /* espera FIFO vazia e busy = 0           */

/* ---- controle por software (substituem SW[1], KEY[1] e o reset) ---- */
int  coproc_ctrl(uint32_t cmd);         /* comando CTRL genérico (1..7)           */
int  coproc_modo_fila(int on);          /* 1: FIFO só acumula; 0: executa         */
int  coproc_passo(void);                /* executa 1 instrução da fila e espera   */
int  coproc_reset(int total);           /* 0: FIFO/FSM/HALT/R1-R15; 1: + gráficos */
int  coproc_fila_qtd(void);             /* instruções na FIFO (0..32)             */

#endif /* COPROC_DRIVER_H */
