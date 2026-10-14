@ coproc_driver.s — Driver do coprocessador gráfico (HPS ARMv7 / Linux)
@  Camada de acesso ao hardware, chamada pelo código C (AAPCS).
@  Nada depende das chaves ou botões da placa: modo fila, passo a passo
@  e reset são comandos CTRL (opcode 62) enviados por estas funções.
@
@  Básico
@     int  coproc_init(void);            0 = ok, < 0 = -errno
@     void coproc_close(void);
@     int  coproc_status(void);          pio_status (0..255) ou -4
@     int  coproc_send(uint32_t instr);  enfileira e espera terminar
@     int  coproc_enfileira(uint32_t instr);  só enfileira (modo fila)
@     int  coproc_espera(void);          espera FIFO vazia e busy = 0
@  Controle (substituem SW[1], KEY[1] e o reset da placa)
@     int  coproc_ctrl(uint32_t cmd);    envia comando CTRL genérico
@     int  coproc_modo_fila(int on);     1 = só acumula, 0 = executa
@     int  coproc_passo(void);           executa 1 instrução da fila
@     int  coproc_reset(int total);      0 = ISA (FIFO/FSM/HALT/R1-R15)
@                                        1 = ISA + registradores gráficos
@     int  coproc_fila_qtd(void);        nº de instruções na FIFO (0..32)
@
@  Retornos negativos: -1 FIFO cheia, -2 timeout, -3 HALT,
@                      -4 não iniciado, -5 hardware sem suporte a CTRL
@
@  Caminho:  HPS --(ponte LW, 0xFF200000)--> PIOs --> pio_cmd_iface --> FIFO
@     pio_cmd_data  LW + 0x10010   (32 bits, saída)   palavra da instrução
@     pio_cmd_push  LW + 0x10020   ( 1 bit,  saída)   borda de subida = push
@     pio_status    LW + 0x10030   ( 8 bits, entrada)
@        [0]busy [1]modo_fila [2]fifo_full [3]fifo_empty [4]vsync [5]halt
@        [6]tilemap na tela (0=A,1=B) [7]frame buffer na tela (0=A,1=B)
@
@  Montar junto com o C:   gcc -O2 -Wall -o prog prog.c coproc_driver.s
@
@  AAPCS: argumentos em r0-r3, retorno em r0; r4-r11 preservados;
@  r7 guarda o número da syscall.

        .syntax unified
        .arch   armv7-a
        .arm

@Endereços (soc_system.qsys / hps_0.h)
        .equ LW_PAGINA,     0xFF200      @ 0xFF200000 / 4096 (mmap2 usa páginas)
        .equ LW_SPAN,       0x20000      @ mapeia 128 KB da ponte LW
        .equ PIO_OFS,       0x10000      @ os 3 PIOs ficam em LW + 0x100x0
        .equ OFS_DATA,      0x10         @ pio_cmd_data  - PIO_OFS
        .equ OFS_PUSH,      0x20         @ pio_cmd_push  - PIO_OFS
        .equ OFS_STATUS,    0x30         @ pio_status    - PIO_OFS

@Bits de status
        .equ ST_BUSY,       0x01
        .equ ST_FILA,       0x02
        .equ ST_FULL,       0x04
        .equ ST_EMPTY,      0x08
        .equ ST_HALT,       0x20
        .equ OP_HALT,       63

@Comandos CTRL (opcode 62, não entram na FIFO)
        .equ OP_CTRL,        62
        .equ C_FILA_ON,      1
        .equ C_FILA_OFF,     2
        .equ C_PASSO,        3
        .equ C_RESET_ISA,    4
        .equ C_RESET_TOTAL,  5
        .equ C_VER_QTD,      6           @ pio_status = {1, modo_fila, qtd[5:0]}
        .equ C_VER_STATUS,   7

@Syscalls Linux ARM EABI (número em r7)
        .equ SYS_OPEN,      5
        .equ SYS_CLOSE,     6
        .equ SYS_MUNMAP,    91
        .equ SYS_NANOSLEEP, 162
        .equ SYS_MMAP2,     192

        .equ O_RDWR_SYNC,   0x101002     @ O_RDWR | O_SYNC (acesso não cacheado)
        .equ PROT_RW,       3            @ PROT_READ | PROT_WRITE
        .equ MAP_SHARED,    1

        .equ TIMEOUT_POLLS, 20000        @ 20000 x 100 us = 2 s

@ Dados
        .data
        .align 2
fd_mem:     .word   -1                  @ descritor de /dev/mem
lw_base:    .word   0                   @ endereço virtual da ponte LW
pio_base:   .word   0                   @ lw_base + 0x10000 (0 = não iniciado)

        .section .rodata
        .align 2
caminho:    .asciz  "/dev/mem"
        .align 2
espera_ts:  .word   0, 100000           @ struct timespec {0 s, 100 000 ns}

        .text

@  int coproc_init(void)
@    Abre /dev/mem, mapeia a ponte LW e põe o pio_status na página normal.
@    Retorna 0 ou -errno.
        .global coproc_init
        .type   coproc_init, %function
coproc_init:
        push    {r4, r5, r7, lr}

        ldr     r0, =pio_base           @ já iniciado? retorna 0
        ldr     r0, [r0]
        cmp     r0, #0
        movne   r0, #0
        bne     .Linit_fim

        @ fd = open("/dev/mem", O_RDWR | O_SYNC)
        ldr     r0, =caminho
        ldr     r1, =O_RDWR_SYNC
        mov     r2, #0
        mov     r7, #SYS_OPEN
        svc     #0
        cmp     r0, #0
        blt     .Linit_fim              @ r0 = -errno (ex.: -13 sem sudo)
        mov     r4, r0                  @ r4 = fd
        ldr     r1, =fd_mem
        str     r0, [r1]

        @ base = mmap2(NULL, LW_SPAN, PROT_RW, MAP_SHARED, fd, LW_PAGINA)
        mov     r0, #0
        mov     r1, #LW_SPAN
        mov     r2, #PROT_RW
        mov     r3, #MAP_SHARED
        ldr     r5, =LW_PAGINA          @ 6º argumento (r4 = fd já está certo)
        mov     r7, #SYS_MMAP2
        svc     #0
        cmn     r0, #4096               @ -4095..-1 = erro
        bhi     .Linit_erro_mmap

        ldr     r1, =lw_base
        str     r0, [r1]
        add     r5, r0, #PIO_OFS
        ldr     r1, =pio_base
        str     r5, [r1]

        mov     r1, #0                  @ push em nível baixo antes do 1º envio
        str     r1, [r5, #OFS_PUSH]
        dsb

        @ garante pio_status na página normal (um programa anterior pode
        @ ter parado no meio de coproc_fila_qtd)
        ldr     r4, =(C_VER_STATUS << 6) | OP_CTRL
        bl      envia_palavra

        mov     r0, #0
        b       .Linit_fim

.Linit_erro_mmap:
        mov     r5, r0                  @ guarda -errno
        mov     r0, r4
        mov     r7, #SYS_CLOSE
        svc     #0
        ldr     r1, =fd_mem
        mvn     r0, #0
        str     r0, [r1]                @ fd_mem = -1
        mov     r0, r5
.Linit_fim:
        pop     {r4, r5, r7, pc}
        .size   coproc_init, . - coproc_init

@ void coproc_close(void)
        .global coproc_close
        .type   coproc_close, %function
coproc_close:
        push    {r4, r5, r7, lr}

        ldr     r4, =lw_base
        ldr     r0, [r4]
        cmp     r0, #0
        beq     1f
        mov     r1, #LW_SPAN
        mov     r7, #SYS_MUNMAP         @ munmap(lw_base, LW_SPAN)
        svc     #0
        mov     r0, #0
        str     r0, [r4]                @ lw_base  = 0
        ldr     r1, =pio_base
        str     r0, [r1]                @ pio_base = 0
1:
        ldr     r4, =fd_mem
        ldr     r0, [r4]
        cmp     r0, #0
        blt     2f
        mov     r7, #SYS_CLOSE          @ close(fd_mem)
        svc     #0
        mvn     r0, #0
        str     r0, [r4]                @ fd_mem = -1
2:
        pop     {r4, r5, r7, pc}
        .size   coproc_close, . - coproc_close

@int coproc_status(void)
@Lê pio_status (8 bits). Retorna -4 se o driver não foi iniciado.
        .global coproc_status
        .type   coproc_status, %function
coproc_status:
        ldr     r1, =pio_base
        ldr     r1, [r1]
        cmp     r1, #0
        mvneq   r0, #3                  @ -4 = COPROC_ERR_NAO_INIT
        bxeq    lr
        ldr     r0, [r1, #OFS_STATUS]
        and     r0, r0, #0xFF
        bx      lr
        .size   coproc_status, . - coproc_status

@ int coproc_enfileira(uint32_t instr)
@    Espera haver espaço na FIFO e envia a palavra (não espera executar).
@    Use com coproc_modo_fila(1) para montar uma fila de instruções.
@    Retorno: 0 | -1 FIFO cheia por 2 s | -3 HALT | -4 não iniciado
        .global coproc_enfileira
        .type   coproc_enfileira, %function
coproc_enfileira:
        push    {r4, r5, r6, lr}
        mov     r4, r0                  @ r4 = instrução
        bl      pega_base               @ r5 = base (ou retorna -4)
        beq     .Lenf_fim

        ldr     r6, =TIMEOUT_POLLS
.Lenf_espaco:
        ldr     r0, [r5, #OFS_STATUS]
        tst     r0, #ST_HALT
        mvnne   r0, #2                  @ -3: em HALT a fila não anda
        bne     .Lenf_fim
        tst     r0, #ST_FULL
        beq     .Lenf_escreve
        bl      espera_100us
        subs    r6, r6, #1
        bne     .Lenf_espaco
        mvn     r0, #0                  @ -1: FIFO continua cheia
        b       .Lenf_fim

.Lenf_escreve:
        bl      envia_palavra
        mov     r0, #0
.Lenf_fim:
        pop     {r4, r5, r6, pc}
        .size   coproc_enfileira, . - coproc_enfileira

@  int coproc_espera(void)
@    Espera o coprocessador terminar tudo: FIFO vazia E busy = 0.
@    (só busy não basta: logo após o push a instrução pode estar ainda
@     na FIFO com busy = 0)
@    Retorno: 0 | -2 não terminou em 2 s (modo fila ligado?) | -3 HALT | -4
        .global coproc_espera
        .type   coproc_espera, %function
coproc_espera:
        push    {r4, r5, r6, lr}
        bl      pega_base
        beq     .Lesp_fim

        ldr     r6, =TIMEOUT_POLLS
.Lesp_loop:
        ldr     r0, [r5, #OFS_STATUS]
        tst     r0, #ST_HALT
        mvnne   r0, #2                  @ -3
        bne     .Lesp_fim
        and     r1, r0, #(ST_EMPTY | ST_BUSY)
        cmp     r1, #ST_EMPTY           @ vazia e não ocupado?
        moveq   r0, #0
        beq     .Lesp_fim
        bl      espera_100us
        subs    r6, r6, #1
        bne     .Lesp_loop
        mvn     r0, #1                  @ -2
.Lesp_fim:
        pop     {r4, r5, r6, pc}
        .size   coproc_espera, . - coproc_espera

@ int coproc_send(uint32_t instr)
@    coproc_enfileira + coproc_espera. HALT terminar em HALT é sucesso.
@    Retorno: 0 | -1 | -2 | -3 | -4
        .global coproc_send
        .type   coproc_send, %function
coproc_send:
        push    {r4, lr}
        mov     r4, r0
        bl      coproc_enfileira
        cmp     r0, #0
        bne     .Lsend_fim
        bl      coproc_espera
        cmn     r0, #3                  @ -3 (HALT)?
        bne     .Lsend_fim
        and     r1, r4, #0x3F
        cmp     r1, #OP_HALT            @ a instrução era o próprio HALT
        moveq   r0, #0
.Lsend_fim:
        pop     {r4, pc}
        .size   coproc_send, . - coproc_send

@ int coproc_ctrl(uint32_t cmd)
@    Envia o comando CTRL 'cmd' (1..7). Não entra na FIFO: vale na hora,
@    mesmo com a FIFO cheia ou em HALT.  Retorno: 0 | -4
        .global coproc_ctrl
        .type   coproc_ctrl, %function
coproc_ctrl:
        push    {r4, r5, r6, lr}
        and     r0, r0, #0xF
        mov     r4, #OP_CTRL
        orr     r4, r4, r0, lsl #6      @ palavra = (cmd << 6) | 62
        bl      pega_base
        beq     .Lctrl_fim
        bl      envia_palavra
        mov     r0, #0
.Lctrl_fim:
        pop     {r4, r5, r6, pc}
        .size   coproc_ctrl, . - coproc_ctrl

@int coproc_modo_fila(int on)   on != 0: FIFO só acumula; 0: executa
        .global coproc_modo_fila
        .type   coproc_modo_fila, %function
coproc_modo_fila:
        cmp     r0, #0
        movne   r0, #C_FILA_ON
        moveq   r0, #C_FILA_OFF
        b       coproc_ctrl             @ chamada de cauda (retorna dela)
        .size   coproc_modo_fila, . - coproc_modo_fila

@ int coproc_reset(int total)
@    total = 0: RESET_ISA  (limpa FIFO, FSM, HALT e R1..R15)
@    total ≠ 0: RESET_TOTAL (+ sprites, polígonos, scroll, camadas,
@               e desliga o modo fila)
        .global coproc_reset
        .type   coproc_reset, %function
coproc_reset:
        cmp     r0, #0
        movne   r0, #C_RESET_TOTAL
        moveq   r0, #C_RESET_ISA
        b       coproc_ctrl
        .size   coproc_reset, . - coproc_reset

@  int coproc_passo(void)
@    No modo fila, executa UMA instrução e espera ela terminar (busy = 0).
@    Retorno: 0 | -2 timeout | -3 HALT (inclusive se a instrução era HALT) | -4
        .global coproc_passo
        .type   coproc_passo, %function
coproc_passo:
        push    {r4, r5, r6, lr}
        mov     r4, #((C_PASSO << 6) | OP_CTRL)
        bl      pega_base
        beq     .Lpasso_fim
        bl      envia_palavra           @ a instrução já começou ao voltar

        ldr     r6, =TIMEOUT_POLLS
.Lpasso_loop:
        ldr     r0, [r5, #OFS_STATUS]
        tst     r0, #ST_HALT
        mvnne   r0, #2                  @ -3
        bne     .Lpasso_fim
        tst     r0, #ST_BUSY
        moveq   r0, #0
        beq     .Lpasso_fim
        bl      espera_100us
        subs    r6, r6, #1
        bne     .Lpasso_loop
        mvn     r0, #1                  @ -2
.Lpasso_fim:
        pop     {r4, r5, r6, pc}
        .size   coproc_passo, . - coproc_passo

@ int coproc_fila_qtd(void)
@    Quantas instruções estão na FIFO (0..32). Troca o pio_status para a
@    página {1, modo_fila, qtd[5:0]}, lê e volta para a página normal.
@    Retorno: 0..32 | -4 | -5 (bit 7 não veio em 1: .sof sem comando CTRL)
        .global coproc_fila_qtd
        .type   coproc_fila_qtd, %function
coproc_fila_qtd:
        push    {r4, r5, r6, lr}
        bl      pega_base
        beq     .Lqtd_fim
        ldr     r4, =(C_VER_QTD << 6) | OP_CTRL
        bl      envia_palavra
        ldr     r6, [r5, #OFS_STATUS]   @ {1, modo_fila, qtd}
        ldr     r4, =(C_VER_STATUS << 6) | OP_CTRL
        bl      envia_palavra
        tst     r6, #0x80
        mvneq   r0, #4                  @ -5: hardware antigo
        andne   r0, r6, #0x3F
.Lqtd_fim:
        pop     {r4, r5, r6, pc}
        .size   coproc_fila_qtd, . - coproc_fila_qtd

@ pega_base (interno): r5 = pio_base. Se não iniciado: r0 = -4 e Z = 1.
@  Não altera r4.
        .type   pega_base, %function
pega_base:
        ldr     r5, =pio_base
        ldr     r5, [r5]
        cmp     r5, #0
        mvneq   r0, #3                  @ -4
        bx      lr
        .size   pega_base, . - pega_base

@  envia_palavra (interno): escreve r4 em pio_cmd_data e dá o pulso de
@  push 0 -> 1 -> 0. r5 = base dos PIOs. Usa r0.
@    - dsb depois de cada escrita: garante a ordem dado -> push e que a
@      escrita chegou ao PIO
@    - 2 leituras de status com push = 1: mantêm o pulso por centenas de
@      ns (o FPGA precisa de ~20 ns) e, ao voltar, o comando já foi
@      capturado/aplicado pelo FPGA
        .type   envia_palavra, %function
envia_palavra:
        str     r4, [r5, #OFS_DATA]     @ pio_cmd_data = palavra
        dsb
        mov     r0, #1
        str     r0, [r5, #OFS_PUSH]     @ push = 1 (borda de subida)
        dsb
        ldr     r0, [r5, #OFS_STATUS]
        ldr     r0, [r5, #OFS_STATUS]
        mov     r0, #0
        str     r0, [r5, #OFS_PUSH]     @ push = 0
        dsb
        bx      lr
        .size   envia_palavra, . - envia_palavra

@ espera_100us (interno) — nanosleep({0, 100000}, NULL). Usa r0, r1.
        .type   espera_100us, %function
espera_100us:
        push    {r7, lr}
        ldr     r0, =espera_ts
        mov     r1, #0
        mov     r7, #SYS_NANOSLEEP
        svc     #0
        pop     {r7, pc}
        .size   espera_100us, . - espera_100us

        .ltorg

        .section .note.GNU-stack,"",%progbits
