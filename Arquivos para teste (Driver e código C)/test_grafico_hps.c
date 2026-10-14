/* Teste das capacidades gráficas do coprocessador via HPS <-> PIO

Cenários:
1. Scroll do Background (absoluto + relativo)
2. Mostrar e mover um sprite
3. Trocar padrão de sprite (SPR_PAT)
4. Mostrar e mover um polígono
5. Demo completa: 32 sprites + 4 polígonos (todos os tipos) + scroll
6. Tiles: SET_TILE no tilemap oculto + SWAP_BG
7. Modo fila e passo a passo (antes: SW[1] e KEY[1])
8. FIFO cheia, HALT e reset por software (antes: reprogramar o .sof)
9. Troca de tiles em intervalos (tilemap oculto não aparece até o SWAP_BG)
10. Troca de background (SWAP_BG A <-> B, parado e com scroll)
11. Múltiplos sprites com movimentação
12. Múltiplos polígonos com movimentação
13. Transparência (sprite 4 sobre polígono alternando 0x00 / verde)
14. Troca de prioridade (sprite x polígono e sprite x sprite)
15. Espelhamentos horizontal e vertical
*/

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <unistd.h>
#include <string.h>

#include "coproc_driver.h"      /* driver em assembly: coproc_driver.s */

/* Bits de pio_status (definidos no coproc_driver.h) */
#define STATUS_BUSY         COPROC_ST_BUSY
#define STATUS_MODO_FILA    COPROC_ST_MODO_FILA
#define STATUS_FIFO_FULL    COPROC_ST_FIFO_FULL
#define STATUS_FIFO_EMPTY   COPROC_ST_FIFO_EMPTY
#define STATUS_VSYNC        COPROC_ST_VSYNC
#define STATUS_HALT         COPROC_ST_HALT
#define STATUS_BG_FRENTE    COPROC_ST_BG_FRENTE
#define STATUS_FB_FRENTE    COPROC_ST_FB_FRENTE

/* Geometria assumida da tela e dos sprites */
#define TELA_W   320
#define TELA_H   240
#define SPR_TAM  16
#define N_SPR    32        /* sprites/padrões disponíveis */
#define N_POLY   4         /* slots de polígono */

/* Alvos de SET_TILE */
#define ALVO_OCULTO   0
#define ALVO_VISIVEL  1
#define ALVO_AMBOS    2

/* Opcodes da ISA (6 bits LSBs)*/
enum {
    OP_NOP      =  0,
    OP_WAIT_VS  =  1,
    OP_SWAP_FB  =  2,
    OP_SET_LAYER=  3,
    OP_SET_BG_X =  4,
    OP_SET_BG_Y =  5,
    OP_MOV_BG   =  6,
    OP_SPR_POS  =  7,
    OP_SPR_MOV  =  8,
    OP_SPR_CFG  =  9,
    OP_SPR_HIDE = 10,
    OP_SPR_SEL  = 11,
    OP_SPR_PAT  = 12,
    OP_PLY_DRAW = 13,
    OP_PLY_ADJ  = 14,
    OP_PLY_COR  = 15,
    OP_PLY_MOV  = 16,
    OP_PLY_HIDE = 17,
    OP_SET_PRI  = 18,
    OP_MOVI     = 21,
    OP_SWAP_BG  = 27,
    OP_SET_TILE = 28,
    OP_HALT     = 63
};

/* Codificadores de instrução*/

/* Formato G: f[25:0] << 6 | opcode */
static inline uint32_t enc_G(uint32_t f, uint8_t op)
{
    return ((f & 0x3FFFFFFu) << 6) | (op & 0x3F);
}

/* SET_LAYER  f[2:0] = {poly, spr, bg} */
static inline uint32_t ENC_SET_LAYER(int poly, int spr, int bg)
{
    return enc_G(((poly & 1) << 2) | ((spr & 1) << 1) | (bg & 1), OP_SET_LAYER);
}

/* SET_BG_X / SET_BG_Y  f[7:0] = valor */
static inline uint32_t ENC_SET_BG_X(uint8_t x) { return enc_G(x, OP_SET_BG_X); }
static inline uint32_t ENC_SET_BG_Y(uint8_t y) { return enc_G(y, OP_SET_BG_Y); }

/* SET_PRI  1 = sprite na frente do polígono, 0 = polígono na frente */
static inline uint32_t ENC_SET_PRI(int spo) { return enc_G(spo & 1, OP_SET_PRI); }

/* MOVI Rd, imm16   (mesma ordem do assembly; Rd = 1..15, R0 é fixo em 0)
 * Valores negativos: complemento de 2 (ex.: -2 -> 0xFFFE)            */
static inline uint32_t ENC_MOVI(uint8_t rd, uint16_t imm)
{
    return ((uint32_t)imm << 14) | ((uint32_t)(rd & 0xF) << 6) | OP_MOVI;
}

/* MOV_BG  scroll += (Rs, Rt) */
static inline uint32_t ENC_MOV_BG(uint8_t rs, uint8_t rt)
{
    return ((uint32_t)(rt & 0xF) << 14) | ((uint32_t)(rs & 0xF) << 10) | OP_MOV_BG;
}

/* SPR_POS  idx, x9, y9 */
static inline uint32_t ENC_SPR_POS(uint8_t idx, uint16_t x, uint16_t y)
{
    return enc_G(((uint32_t)(idx & 0x1F) << 21) |
                 ((uint32_t)(x   & 0x1FF) << 12) |
                 ((uint32_t)(y   & 0x1FF) <<  3), OP_SPR_POS);
}

/* SPR_CFG  idx, en, fh, fv, pri(0..3)  — NÃO altera a posição */
static inline uint32_t ENC_SPR_CFG(uint8_t idx, int en, int fh, int fv, int pri)
{
    return enc_G(((uint32_t)(idx & 0x1F) << 21) |
                 ((en  & 1)    <<  4) |
                 ((fh  & 1)    <<  3) |
                 ((fv  & 1)    <<  2) |
                 (pri  & 3), OP_SPR_CFG);
}

/* SPR_PAT  idx, padrão 0..31 */
static inline uint32_t ENC_SPR_PAT(uint8_t idx, uint8_t pat)
{
    return enc_G(((uint32_t)(idx & 0x1F) << 21) | (pat & 0x1F), OP_SPR_PAT);
}

/* SPR_HIDE */
static inline uint32_t ENC_SPR_HIDE(uint8_t idx)
{
    return enc_G((uint32_t)(idx & 0x1F) << 21, OP_SPR_HIDE);
}

/* SPR_MOV  idx, Rs=dx, Rt=dy */
static inline uint32_t ENC_SPR_MOV(uint8_t idx, uint8_t rs, uint8_t rt)
{
    return ((uint32_t)(idx & 0x1F) << 18) | ((uint32_t)(rt & 0xF) << 14) |
           ((uint32_t)(rs  & 0xF)  << 10) | OP_SPR_MOV;
}

/* PLY_DRAW  slot(0..3), tipo(0..7), x9, y9  (também habilita o slot)
 * tipo: 0=retângulo, 1=tri. retângulo, 2/3=isósceles, 4=escaleno, 5=quadrado */
static inline uint32_t ENC_PLY_DRAW(uint8_t slot, uint8_t tipo,
                                    uint16_t x, uint16_t y)
{
    return enc_G(((uint32_t)(slot & 3)  << 24) |
                 ((uint32_t)(tipo & 7)  << 21) |
                 ((uint32_t)(x    & 0x1FF) << 12) |
                 ((uint32_t)(y    & 0x1FF) <<  3), OP_PLY_DRAW);
}

/* PLY_COR  slot, cor RRRGGGBB (0x00 = transparente) */
static inline uint32_t ENC_PLY_COR(uint8_t slot, uint8_t cor)
{
    return enc_G(((uint32_t)(slot & 3) << 24) | cor, OP_PLY_COR);
}

/* PLY_ADJ  slot, size9 */
static inline uint32_t ENC_PLY_ADJ(uint8_t slot, uint16_t size)
{
    return ((uint32_t)(slot & 3) << 23) | ((uint32_t)(size & 0x1FF) << 14) | OP_PLY_ADJ;
}

/* PLY_MOV  slot, Rs=dx, Rt=dy */
static inline uint32_t ENC_PLY_MOV(uint8_t slot, uint8_t rs, uint8_t rt)
{
    return ((uint32_t)(slot & 3) << 18) | ((uint32_t)(rt & 0xF) << 14) |
           ((uint32_t)(rs & 0xF) << 10) | OP_PLY_MOV;
}

/* PLY_HIDE */
static inline uint32_t ENC_PLY_HIDE(uint8_t slot)
{
    return enc_G((uint32_t)(slot & 3) << 24, OP_PLY_HIDE);
}

/* SET_TILE alvo(0=oculto,1=visível,2=ambos), linha 0..29, coluna 0..39, tile */
static inline uint32_t ENC_SET_TILE(uint8_t alvo, uint8_t lin, uint8_t col, uint8_t tile)
{
    return enc_G(((uint32_t)(alvo & 3) << 24) | ((uint32_t)(lin & 0x1F) << 19) |
                 ((uint32_t)(col & 0x3F) << 13) | tile, OP_SET_TILE);
}

static inline uint32_t ENC_WAIT_VS(void) { return OP_WAIT_VS; }
static inline uint32_t ENC_SWAP_FB(void) { return OP_SWAP_FB; }
static inline uint32_t ENC_SWAP_BG(void) { return OP_SWAP_BG; }
static inline uint32_t ENC_NOP(void)     { return OP_NOP; }
static inline uint32_t ENC_HALT(void)    { return OP_HALT; }

/* Camada de hardware: chamadas ao driver em assembly*/
int pio_init(void)
{
    int r = coproc_init();
    if (r < 0) {
        fprintf(stderr, "coproc_init: %s%s\n", strerror(-r),
                (r == -13 || r == -1) ? " — rode com sudo" : "");
        return -1;
    }
    printf("[driver] ponte LW mapeada\n");
    return 0;
}

void pio_close(void)
{
    coproc_close();
}

static uint8_t pio_read_status(void)
{
    int s = coproc_status();
    return (s < 0) ? 0 : (uint8_t)s;
}

void print_status(const char *tag)
{
    uint8_t s = pio_read_status();
    printf("%s STATUS=0x%02X [", tag, s);
    if (s & STATUS_BUSY)       printf("BUSY ");
    if (s & STATUS_MODO_FILA)  printf("FILA ");
    if (s & STATUS_FIFO_FULL)  printf("FULL ");
    if (s & STATUS_FIFO_EMPTY) printf("EMPTY ");
    if (s & STATUS_VSYNC)      printf("VSYNC ");
    if (s & STATUS_HALT)       printf("HALT ");
    printf("BG=%c FB=%c]\n", (s & STATUS_BG_FRENTE) ? 'B' : 'A',
                             (s & STATUS_FB_FRENTE) ? 'B' : 'A');
}

/* Envia uma instrução pelo driver (que espera ela terminar) e trata erros.
 * Depois do 1º erro, as próximas chamadas são ignoradas (o menu faz um
 * reset total antes do teste seguinte). */
static int erro_fatal = 0;

int isa_send(uint32_t instr)
{
    if (erro_fatal)
        return -1;

    int r = coproc_send(instr);
    if (r == COPROC_OK)
        return 0;

    switch (r) {
    case COPROC_ERR_FIFO_CHEIA:
        fprintf(stderr, "ERRO: FIFO cheia por 2 s (modo fila ligado? coproc_modo_fila(0))\n");
        break;
    case COPROC_ERR_TIMEOUT: {
        uint8_t s = pio_read_status();
        fprintf(stderr, "ERRO: instr=0x%08X não terminou (STATUS=0x%02X)%s\n",
                instr, s,
                (!(s & STATUS_FIFO_EMPTY) && !(s & STATUS_BUSY))
                    ? " — fila parada: modo fila ligado (coproc_modo_fila(0))" : "");
        break;
    }
    case COPROC_ERR_HALT:
        fprintf(stderr, "ERRO: coprocessador em HALT — use coproc_reset(0)\n");
        break;
    case COPROC_ERR_NAO_INIT:
        fprintf(stderr, "ERRO: driver não iniciado (coproc_init)\n");
        break;
    default:
        fprintf(stderr, "ERRO: coproc_send retornou %d\n", r);
    }
    erro_fatal = 1;
    return -1;
}

/* Envia lista de instruções */
int isa_send_list(const uint32_t *list, int n)
{
    for (int i = 0; i < n; i++) {
        if (isa_send(list[i]) < 0)
            return -1;
    }
    return 0;
}

/* Fecha um quadro: SWAP_FB mostra na tela tudo o que foi enviado antes.
 * É bloqueante (~33 ms), então também controla a velocidade da animação. */
static void quadro(void)
{
    isa_send(ENC_SWAP_FB());
}

static void pausa_ms(int ms)
{
    unsigned int seg = (unsigned int)(ms * 1000);
    usleep(seg);
}

/* Prepara o coprocessador sem depender das chaves/botões:
 *   1) confere se o .sof gravado tem o comando CTRL (modo fila liga/desliga)
 *   2) reset por software: sai do HALT, esvazia a fila, desliga o modo fila
 *      total = 1: também zera os registradores gráficos (modo menu)
 *      total = 0: mantém a cena atual (modo arquivo -f/-p, para rodar os
 *                 arquivos tNN em sequência como no antigo ISSP)
 *   3) envia SWAP_FB e confere se o frame buffer da frente trocou */
static int preparar(int total)
{
    uint8_t s = pio_read_status();
    if (s & STATUS_HALT)
        printf("  coprocessador estava em HALT (execução anterior)\n");
    if (!(s & STATUS_FIFO_EMPTY))
        printf("  a fila tinha instruções pendentes\n");

    coproc_modo_fila(1);
    int liga = pio_read_status() & STATUS_MODO_FILA;
    coproc_modo_fila(0);
    int desliga = pio_read_status() & STATUS_MODO_FILA;
    if (!liga || desliga || coproc_fila_qtd() < 0) {
        fprintf(stderr,
            "O .sof gravado não reconhece os comandos CTRL (opcode 62).\n"
            "Compile o projeto atualizado no Quartus e grave o novo .sof.\n");
        return -1;
    }

    coproc_reset(total);                   /* reset por software */
    coproc_modo_fila(0);
    s = pio_read_status();
    if ((s & STATUS_HALT) || !(s & STATUS_FIFO_EMPTY)) {
        fprintf(stderr, "Reset por software não limpou o coprocessador (STATUS=0x%02X)\n", s);
        return -1;
    }

    uint8_t fb_antes = s & STATUS_FB_FRENTE;
    if (isa_send(ENC_SWAP_FB()) < 0)
        return -1;
    if ((pio_read_status() & STATUS_FB_FRENTE) == fb_antes) {
        fprintf(stderr,
            "SWAP_FB não trocou o frame buffer: confira se o .sof certo está\n"
            "gravado e se a VGA está gerando sinal.\n");
        return -1;
    }
    printf("[OK] Coprocessador pronto (reset por software, modo normal)\n");
    return 0;
}

/* Esconde todos os sprites e polígonos */
static void esconde_tudo(void)
{
    for (int i = 0; i < N_SPR; i++)
        isa_send(ENC_SPR_HIDE(i));
    for (int i = 0; i < N_POLY; i++)
        isa_send(ENC_PLY_HIDE(i));
}

/* Deixa a tela num estado conhecido (os registradores não zeram entre
 * execuções do programa, só no reset da FPGA). */
static void estado_inicial(void)
{
    isa_send(ENC_SET_LAYER(1, 1, 1));
    isa_send(ENC_SET_BG_X(0));
    isa_send(ENC_SET_BG_Y(0));
    isa_send(ENC_SET_PRI(1));
    esconde_tudo();
    quadro();
}

/* Utilitários para animações com vários objetos */

/* Velocidades por registrador: R1..R7 = -3..+3 (R4 = 0).
 * VREG(v) devolve o registrador que contém v. Os testes novos usam só
 * esses registradores nas instruções SPR_MOV / PLY_MOV / MOV_BG. */
#define VREG(v)  ((uint8_t)((v) + 4))

static void carrega_velocidades(void)
{
    for (int v = -3; v <= 3; v++)
        isa_send(ENC_MOVI(VREG(v), (uint16_t)(int16_t)v));
}

/* Objeto em movimento: posição acompanhada em C para quicar nas bordas */
typedef struct { int x, y, vx, vy; } Obj;

static int vel_aleat(void)
{
    int v = 1 + rand() % 3;
    return (rand() & 1) ? v : -v;
}

/* Calcula o próximo passo; inverte a velocidade antes de sair da tela */
static void prox(Obj *o, int larg, int alt)
{
    if (o->x + o->vx < 0 || o->x + o->vx > TELA_W - larg) o->vx = -o->vx;
    if (o->y + o->vy < 0 || o->y + o->vy > TELA_H - alt)  o->vy = -o->vy;
    o->x += o->vx;
    o->y += o->vy;
}

/*sprites*/

/* Configura n sprites (padrão i), em grade 8 x 4, com velocidades aleatórias */
static void sprites_inicia(Obj *s, int n)
{
    for (int i = 0; i < n; i++) {
        s[i].x  = 8 + (i % 8) * 38;
        s[i].y  = 16 + (i / 8) * 50;
        s[i].vx = vel_aleat();
        s[i].vy = vel_aleat();
        isa_send(ENC_SPR_PAT(i, i % N_SPR));
        isa_send(ENC_SPR_POS(i, s[i].x, s[i].y));
        isa_send(ENC_SPR_CFG(i, 1, 0, 0, i & 3));
    }
}

static void sprites_passo(Obj *s, int n)
{
    for (int i = 0; i < n; i++) {
        prox(&s[i], SPR_TAM, SPR_TAM);
        isa_send(ENC_SPR_MOV(i, VREG(s[i].vx), VREG(s[i].vy)));
    }
}

/*polígonos */
typedef struct { Obj o; int tipo, tam; uint8_t cor; } Poly;

#define N_TIPOS 6
static const char *TIPO_NOME[N_TIPOS] = {
    "retângulo", "triângulo retângulo", "triângulo isósceles (2)",
    "triângulo isósceles (3)", "triângulo escaleno", "quadrado"
};
static const uint8_t PALETA[8] = { 0xE0, 0x1C, 0x03, 0xFC, 0xE3, 0x1F, 0xFF, 0xF4 };
static const int TAMS[4] = { 24, 40, 56, 72 };

static void poly_desenha(int slot, const Poly *p)
{
    isa_send(ENC_PLY_COR(slot, p->cor));
    isa_send(ENC_PLY_ADJ(slot, p->tam));
    isa_send(ENC_PLY_DRAW(slot, p->tipo, p->o.x, p->o.y));
}

static void poly_passo(int slot, Poly *p)
{
    prox(&p->o, p->tam, p->tam);
    isa_send(ENC_PLY_MOV(slot, VREG(p->o.vx), VREG(p->o.vy)));
}

/* Inicia n polígonos com os tipos dados, tamanhos e cores diferentes */
static void polys_inicia(Poly *p, const int *tipos, int n)
{
    for (int i = 0; i < n; i++) {
        p[i].tipo = tipos[i];
        p[i].tam  = TAMS[i % 4];
        p[i].cor  = PALETA[i % 8];
        p[i].o.x  = 20 + i * 70;
        p[i].o.y  = 20 + (i & 1) * 90;
        p[i].o.vx = vel_aleat();
        p[i].o.vy = vel_aleat();
        poly_desenha(i, &p[i]);
    }
}

/*Testes gráficos*/

/* 1. Scroll do Background*/
void teste_scroll_bg(void)
{
    printf("\n=== [1] SCROLL DO BACKGROUND ===\n");

    /* habilita só o layer de BG */
    isa_send(ENC_SET_LAYER(0, 0, 1));

    /* posição absoluta inicial (0,0) */
    isa_send(ENC_SET_BG_X(0));
    isa_send(ENC_SET_BG_Y(0));
    quadro();
    printf("  BG em (0,0)\n");
    usleep(500000);

    /* scroll absoluto para (80, 40) */
    isa_send(ENC_SET_BG_X(80));
    isa_send(ENC_SET_BG_Y(40));
    quadro();
    printf("  BG absoluto -> (80,40)\n");
    usleep(500000);

    /* scroll relativo: R1 = dx = 2, R2 = dy = 1 */
    isa_send(ENC_MOVI(1, 2));
    isa_send(ENC_MOVI(2, 1));

    printf("  Scroll relativo (+2,+1) x 40 quadros...\n");
    for (int i = 0; i < 40; i++) {
        isa_send(ENC_MOV_BG(1, 2));   /* scroll += (R1, R2) */
        quadro();
    }
    printf("  Scroll BG concluído (esperado: 160,80)\n");
    print_status("  ");
}

/*2. Mostrar e mover um sprite */
void teste_sprite_mostrar_mover(void)
{
    printf("\n=== [2] MOSTRAR E MOVER SPRITE ===\n");

    const uint8_t SPR = 0;   /* sprite índice 0 */

    /* habilita BG + sprites */
    isa_send(ENC_SET_LAYER(0, 1, 1));

    /* padrão 0 e posição antes de habilitar */
    isa_send(ENC_SPR_PAT(SPR, 0));
    isa_send(ENC_SPR_POS(SPR, 100, 80));

    /* habilitado, sem flip, prioridade 1 */
    isa_send(ENC_SPR_CFG(SPR, 1 /*en*/, 0 /*fh*/, 0 /*fv*/, 1 /*pri*/));
    quadro();
    printf("  Sprite %d em (100,80) padrão 0\n", SPR);
    usleep(500000);

    /* movimento relativo: R3 = dx = 3, R4 = dy = 2 */
    isa_send(ENC_MOVI(3, 3));
    isa_send(ENC_MOVI(4, 2));

    printf("  Movendo sprite (+3,+2) x 50 quadros...\n");
    for (int i = 0; i < 50; i++) {
        isa_send(ENC_SPR_MOV(SPR, 3, 4));
        quadro();
    }

    /* volta em diagonal com valores negativos: R5 = -3, R6 = -2 */
    isa_send(ENC_MOVI(5, (uint16_t)-3));
    isa_send(ENC_MOVI(6, (uint16_t)-2));
    printf("  Voltando (-3,-2) x 50 quadros...\n");
    for (int i = 0; i < 50; i++) {
        isa_send(ENC_SPR_MOV(SPR, 5, 6));
        quadro();
    }
    printf("  Movimento de sprite concluído (esperado: de volta em 100,80)\n");
    print_status("  ");
}

/*3. Trocar padrões de sprite*/
void teste_trocar_sprites(void)
{
    printf("\n=== [3] TROCAR PADRÕES DE SPRITE ===\n");

    const uint8_t SPR = 0;

    isa_send(ENC_SET_LAYER(0, 1, 1));

    /* garante que o sprite está visível no centro */
    isa_send(ENC_SPR_POS(SPR, 152, 112));
    isa_send(ENC_SPR_CFG(SPR, 1, 0, 0, 1));

    printf("  Alternando padrões 0..7 a cada 300 ms...\n");
    for (int ciclo = 0; ciclo < 3; ciclo++) {
        for (uint8_t pat = 0; pat < 8; pat++) {
            isa_send(ENC_SPR_PAT(SPR, pat));
            quadro();
            printf("    padrão = %d\n", pat);
            usleep(300000);
        }
    }

    /* espelhamentos */
    isa_send(ENC_SPR_PAT(SPR, 0));
    isa_send(ENC_SPR_CFG(SPR, 1, 1, 0, 1));  quadro();
    printf("  Flip horizontal\n");  usleep(600000);
    isa_send(ENC_SPR_CFG(SPR, 1, 0, 1, 1));  quadro();
    printf("  Flip vertical\n");    usleep(600000);
    isa_send(ENC_SPR_CFG(SPR, 1, 0, 0, 1));  quadro();

    /* segundo sprite (índice 1) com outro padrão, sobreposto ao primeiro */
    const uint8_t SPR2 = 1;
    isa_send(ENC_SPR_PAT(SPR2, 3));
    isa_send(ENC_SPR_POS(SPR2, 160, 118));
    isa_send(ENC_SPR_CFG(SPR2, 1, 0, 0, 2));    /* pri 2 > pri 1: fica na frente */
    quadro();
    printf("  Sprite 1 (padrão 3) na frente do sprite 0\n");
    usleep(800000);

    isa_send(ENC_SPR_CFG(SPR2, 1, 0, 0, 0));    /* pri 0 < pri 1: vai para trás */
    quadro();
    printf("  Sprite 1 atrás do sprite 0\n");
    usleep(800000);

    /* esconde o segundo sprite */
    isa_send(ENC_SPR_HIDE(SPR2));
    quadro();
    printf("  Sprite 1 escondido\n");
    print_status("  ");
}

/* 4. Mostrar e mover polígono */
void teste_poligono(void)
{
    printf("\n=== [4] MOSTRAR E MOVER POLÍGONO ===\n");

    const uint8_t SLOT = 0;

    /* habilita todos os layers */
    isa_send(ENC_SET_LAYER(1, 1, 1));

    /* cor e tamanho primeiro (cor 0x00 é transparente) */
    isa_send(ENC_PLY_COR(SLOT, 0xE0));        /* vermelho RRR=111 */
    isa_send(ENC_PLY_ADJ(SLOT, 40));          /* tamanho 40 */
    isa_send(ENC_PLY_DRAW(SLOT, 0 /*retângulo*/, 50, 50));
    quadro();
    printf("  Polígono slot %d: retângulo em (50,50) tamanho 40 cor 0xE0\n", SLOT);
    usleep(600000);

    /* muda para triângulo (tipo 1) e cor verde */
    isa_send(ENC_PLY_COR(SLOT, 0x1C));        /* verde GGG=111 */
    isa_send(ENC_PLY_DRAW(SLOT, 1 /*triângulo*/, 50, 50));
    quadro();
    printf("  Mudou para triângulo cor 0x1C\n");
    usleep(600000);

    /* movimento relativo: R7 = dx = 2, R8 = dy = 1 */
    isa_send(ENC_MOVI(7, 2));
    isa_send(ENC_MOVI(8, 1));

    printf("  Movendo polígono (+2,+1) x 60 quadros...\n");
    for (int i = 0; i < 60; i++) {
        isa_send(ENC_PLY_MOV(SLOT, 7, 8));
        quadro();
    }

    /* aumenta o tamanho */
    isa_send(ENC_PLY_ADJ(SLOT, 70));
    quadro();
    printf("  Tamanho aumentado para 70\n");
    usleep(500000);

    /* segundo polígono (slot 1) – quadrado azul */
    isa_send(ENC_PLY_COR(1, 0x03));           /* azul BB=11 */
    isa_send(ENC_PLY_ADJ(1, 30));
    isa_send(ENC_PLY_DRAW(1, 5 /*quadrado*/, 220, 150));
    quadro();
    printf("  Slot 1: quadrado azul em (220,150)\n");
    usleep(800000);

    /* prioridade sprite x polígono: põe o sprite 0 sobre o quadrado */
    isa_send(ENC_SPR_POS(0, 228, 158));
    isa_send(ENC_SPR_CFG(0, 1, 0, 0, 1));
    isa_send(ENC_SET_PRI(1));  quadro();
    printf("  SET_PRI 1: sprite na frente do quadrado\n");  usleep(800000);
    isa_send(ENC_SET_PRI(0));  quadro();
    printf("  SET_PRI 0: quadrado na frente do sprite\n");  usleep(800000);
    isa_send(ENC_SET_PRI(1));

    /* esconde o polígono do slot 0 */
    isa_send(ENC_PLY_HIDE(SLOT));
    quadro();
    printf("  Slot 0 escondido\n");
    print_status("  ");
}

/* 5. Demo completa: tudo junto, em movimento */
#define DEMO_QUADROS     360     /* ~12 s */
#define DEMO_TROCA_POLY  45      /* a cada 45 quadros muda tipo/tamanho/cor */

void demo_completa(void)
{
    printf("\n=== [5] DEMO COMPLETA (32 sprites + 4 polígonos + scroll) ===\n");

    srand(42);
    isa_send(ENC_SET_LAYER(1, 1, 1));
    isa_send(ENC_SET_PRI(1));                 /* sprites na frente dos polígonos */
    isa_send(ENC_SET_BG_X(0));
    isa_send(ENC_SET_BG_Y(0));

    /* os 32 sprites, cada um com um padrão (0..31) */
    Obj spr[N_SPR];
    sprites_inicia(spr, N_SPR);

    /* os 4 slots de polígono, começando em tipos diferentes */
    Poly pol[N_POLY];
    const int tipos0[N_POLY] = { 0, 1, 2, 4 };
    polys_inicia(pol, tipos0, N_POLY);
    quadro();

    printf("  Animando %d quadros: tipos de polígono, tamanhos e cores mudam a cada %d.\n",
           DEMO_QUADROS, DEMO_TROCA_POLY);
    for (int f = 0; f < DEMO_QUADROS; f++) {
        isa_send(ENC_MOV_BG(VREG(1), VREG(0)));     /* scroll (+1,0) */
        sprites_passo(spr, N_SPR);

        int troca = (f > 0 && f % DEMO_TROCA_POLY == 0);
        if (troca)
            printf("  quadro %3d:", f);
        for (int s = 0; s < N_POLY; s++) {
            if (troca) {
                int ciclo = f / DEMO_TROCA_POLY;
                pol[s].tipo = (pol[s].tipo + 1) % N_TIPOS;
                pol[s].tam  = TAMS[(ciclo + s) % 4];
                pol[s].cor  = PALETA[(ciclo * 3 + s) % 8];
                if (pol[s].o.x + pol[s].tam > TELA_W) pol[s].o.x = TELA_W - pol[s].tam;
                if (pol[s].o.y + pol[s].tam > TELA_H) pol[s].o.y = TELA_H - pol[s].tam;
                poly_desenha(s, &pol[s]);
                printf(" [%d]%s/%d", s, TIPO_NOME[pol[s].tipo], pol[s].tam);
            } else {
                poly_passo(s, &pol[s]);
            }
        }
        if (troca)
            printf("\n");
        quadro();
    }
    printf("  Demo completa finalizada\n");
    print_status("  ");
}

/* 6. Tiles: SET_TILE no buffer oculto + SWAP_BG*/
void teste_tiles(void)
{
    printf("\n=== [6] TILES (SET_TILE + SWAP_BG) ===\n");

    isa_send(ENC_SET_LAYER(0, 0, 1));
    isa_send(ENC_SET_BG_X(0));
    isa_send(ENC_SET_BG_Y(0));
    quadro();
    print_status("  antes:");

    /* escreve uma diagonal de tiles 0 no tilemap OCULTO: não aparece ainda */
    for (int i = 0; i < 30; i++)
        isa_send(ENC_SET_TILE(0 /*oculto*/, i, i, 0));
    quadro();
    printf("  Diagonal escrita no tilemap oculto (tela sem mudança)\n");
    usleep(1000000);

    /* troca o tilemap: a diagonal aparece de uma vez */
    isa_send(ENC_SWAP_BG());
    quadro();
    print_status("  depois do SWAP_BG:");
    printf("  Diagonal visível\n");
    usleep(1500000);

    /* volta ao tilemap original */
    isa_send(ENC_SWAP_BG());
    quadro();
    printf("  Tilemap original de volta\n");
}

/*verificações automáticas (testes 7, 8, 9 e 10) */
static int n_ok = 0, n_falhas = 0;
static void confere(int cond, const char *msg)
{
    if (cond) { n_ok++;     printf("    ok     %s\n", msg); }
    else      { n_falhas++; printf("    FALHA  %s\n", msg); }
}

/* 7. Modo fila e passo a passo (antes SW[1] / KEY[1]) */
void teste_modo_fila(void)
{
    printf("\n=== [7] MODO FILA E PASSO A PASSO (por software) ===\n");

    /* cena: fundo + sprite 0 à esquerda */
    isa_send(ENC_SET_LAYER(0, 1, 1));
    isa_send(ENC_SPR_PAT(0, 0));
    isa_send(ENC_SPR_POS(0, 40, 100));
    isa_send(ENC_SPR_CFG(0, 1, 0, 0, 1));
    quadro();

    /* liga o modo fila: daqui em diante nada executa sozinho */
    coproc_modo_fila(1);
    confere(pio_read_status() & STATUS_MODO_FILA, "pio_status[1] indica modo fila");

    /* monta a fila: R1 = 12, R2 = 0 e 10 quadros de (SPR_MOV + SWAP_FB) */
    coproc_enfileira(ENC_MOVI(1, 12));
    coproc_enfileira(ENC_MOVI(2, 0));
    for (int i = 0; i < 10; i++) {
        coproc_enfileira(ENC_SPR_MOV(0, 1, 2));
        coproc_enfileira(ENC_SWAP_FB());
    }
    int qtd = coproc_fila_qtd();
    printf("  %d instruções na fila, nenhuma executada\n", qtd);
    confere(qtd == 22, "coproc_fila_qtd() == 22");
    confere(!(pio_read_status() & STATUS_BUSY), "coprocessador parado (não ocupado)");
    usleep(800000);

    /* executa 8 instruções, uma por vez (o sprite anda a cada SWAP_FB) */
    for (int i = 0; i < 8; i++) {
        int r = coproc_passo();
        printf("  passo %d -> %s, restam %d\n", i + 1,
               r == 0 ? "ok" : "erro", coproc_fila_qtd());
        usleep(400000);
    }
    confere(coproc_fila_qtd() == 14, "8 passos executaram exatamente 8 instruções");

    /* desliga o modo fila: o resto executa em sequência */
    coproc_modo_fila(0);
    confere(coproc_espera() == 0, "modo fila desligado: o resto da fila executou");
    confere(coproc_fila_qtd() == 0, "fila vazia no final");
    printf("  sprite deve ter andado 10 x 12 px para a direita\n");
    print_status("  ");
}

/* 8. FIFO cheia, HALT e reset por software */
void teste_reset(void)
{
    printf("\n=== [8] FIFO CHEIA, HALT E RESET POR SOFTWARE ===\n");
    uint8_t s;

    /* enche a fila (32) em modo fila */
    coproc_modo_fila(1);
    for (int i = 0; i < 32; i++)
        coproc_enfileira(ENC_NOP());
    s = pio_read_status();
    confere(coproc_fila_qtd() == 32 && (s & STATUS_FIFO_FULL), "fila com 32 instruções e bit FIFO_FULL");

    /* comandos CTRL funcionam mesmo com a fila cheia */
    coproc_reset(0);
    s = pio_read_status();
    confere((s & STATUS_FIFO_EMPTY) && coproc_fila_qtd() == 0, "coproc_reset(0) esvaziou a fila cheia");
    confere(s & STATUS_MODO_FILA, "reset da ISA mantém o modo fila escolhido");
    coproc_modo_fila(0);

    /* HALT: antes só saía reprogramando a FPGA */
    confere(coproc_send(ENC_HALT()) == 0, "HALT executado");
    s = pio_read_status();
    confere(s & STATUS_HALT, "pio_status indica HALT");
    confere(coproc_send(ENC_NOP()) == COPROC_ERR_HALT, "em HALT o coprocessador não executa nada");
    coproc_reset(0);
    confere(!(pio_read_status() & STATUS_HALT), "coproc_reset(0) tirou do HALT");
    confere(coproc_send(ENC_SWAP_FB()) == 0, "volta a executar instruções");

    /* mostra algo na tela para ver o efeito do reset total */
    isa_send(ENC_SET_LAYER(1, 1, 1));
    isa_send(ENC_SPR_POS(0, 150, 110));
    isa_send(ENC_SPR_CFG(0, 1, 0, 0, 1));
    quadro();
    printf("  sprite visível antes do reset total\n");
    usleep(800000);

    /* reset total: zera sprites, polígonos, scroll e camadas */
    coproc_reset(1);
    quadro();
    confere(!(pio_read_status() & STATUS_MODO_FILA), "reset total desliga o modo fila");
    printf("  reset total: tela preta (todas as camadas desligadas)\n");
    usleep(1000000);
}

/*  9. Troca de tiles em intervalos */
/* Interpretação: os tiles são alterados em etapas, com um intervalo entre
 * elas, SEMPRE no tilemap oculto. A tela continua mostrando o tilemap
 * antigo (nenhum tile alterado aparece) até o SWAP_BG. Depois, para
 * contraste, alterações no tilemap VISÍVEL aparecem faixa a faixa. */
#define ETAPAS_OCULTO   6      /* 6 faixas de 5 linhas = 30 linhas */
#define INTERVALO_MS    900

void teste_tiles_intervalos(void)
{
    printf("\n=== [9] TROCA DE TILES EM INTERVALOS ===\n");

    isa_send(ENC_SET_LAYER(0, 0, 1));
    isa_send(ENC_SET_BG_X(0));
    isa_send(ENC_SET_BG_Y(0));
    quadro();
    uint8_t bg0 = pio_read_status() & STATUS_BG_FRENTE;
    print_status("  inicio:");

    printf("  Parte 1: faixas de 5 linhas escritas no tilemap OCULTO, a cada %d ms\n",
           INTERVALO_MS);
    for (int etapa = 0; etapa < ETAPAS_OCULTO; etapa++) {
        for (int lin = etapa * 5; lin < etapa * 5 + 5; lin++)
            for (int col = 0; col < 40; col++)
                isa_send(ENC_SET_TILE(ALVO_OCULTO, lin, col, 1 + etapa));
        quadro();
        printf("    etapa %d: linhas %2d..%2d escritas com tile %d\n",
               etapa + 1, etapa * 5, etapa * 5 + 4, 1 + etapa);
        confere((pio_read_status() & STATUS_BG_FRENTE) == bg0,
                "tela continua no tilemap antigo (tiles alterados não aparecem)");
        pausa_ms(INTERVALO_MS);
    }

    printf("  Parte 2: SWAP_BG mostra todas as faixas de uma vez\n");
    isa_send(ENC_SWAP_BG());
    quadro();
    confere((pio_read_status() & STATUS_BG_FRENTE) != bg0, "SWAP_BG trocou o tilemap da tela");
    pausa_ms(2500);

    printf("  Parte 3 (contraste): escrita no tilemap VISÍVEL aparece na hora\n");
    for (int etapa = 0; etapa < 3; etapa++) {
        for (int lin = etapa * 10; lin < etapa * 10 + 10; lin++)
            for (int col = 0; col < 40; col++)
                isa_send(ENC_SET_TILE(ALVO_VISIVEL, lin, col, 8 + etapa));
        quadro();
        printf("    linhas %2d..%2d com tile %d (visível imediatamente)\n",
               etapa * 10, etapa * 10 + 9, 8 + etapa);
        pausa_ms(INTERVALO_MS);
    }

    /* volta ao tilemap que ficou intacto */
    isa_send(ENC_SWAP_BG());
    quadro();
    confere((pio_read_status() & STATUS_BG_FRENTE) == bg0, "SWAP_BG final: tilemap original de volta");
    pausa_ms(1000);
}

/*10. Troca de background */
void teste_troca_bg(void)
{
    printf("\n=== [10] TROCA DE BACKGROUND (SWAP_BG) ===\n");

    isa_send(ENC_SET_LAYER(0, 0, 1));
    isa_send(ENC_SET_BG_X(0));
    isa_send(ENC_SET_BG_Y(0));
    quadro();

    /* prepara o tilemap oculto com uma moldura + faixa central */
    printf("  Preparando tilemap oculto (moldura e faixa central)...\n");
    for (int col = 0; col < 40; col++) {
        isa_send(ENC_SET_TILE(ALVO_OCULTO, 0,  col, 2));
        isa_send(ENC_SET_TILE(ALVO_OCULTO, 29, col, 2));
    }
    for (int lin = 0; lin < 30; lin++) {
        isa_send(ENC_SET_TILE(ALVO_OCULTO, lin, 0,  2));
        isa_send(ENC_SET_TILE(ALVO_OCULTO, lin, 39, 2));
    }
    for (int col = 1; col < 39; col++) {
        isa_send(ENC_SET_TILE(ALVO_OCULTO, 14, col, 3));
        isa_send(ENC_SET_TILE(ALVO_OCULTO, 15, col, 3));
    }
    quadro();

    printf("  Parte 1: alternando A <-> B (8 trocas, 700 ms cada)\n");
    for (int i = 0; i < 8; i++) {
        uint8_t antes = pio_read_status() & STATUS_BG_FRENTE;
        isa_send(ENC_SWAP_BG());
        quadro();
        uint8_t depois = pio_read_status() & STATUS_BG_FRENTE;
        printf("    troca %d: tilemap na tela = %c\n", i + 1, depois ? 'B' : 'A');
        confere(antes != depois, "SWAP_BG alternou o tilemap da tela");
        pausa_ms(700);
    }

    printf("  Parte 2: trocas durante o scroll (a cada 30 quadros)\n");
    for (int f = 0; f < 120; f++) {
        isa_send(ENC_MOV_BG(VREG(2), VREG(1)));    /* scroll (+2,+1) */
        if (f % 30 == 29)
            isa_send(ENC_SWAP_BG());
        quadro();
    }
    print_status("  fim:");
}

/* 11. Múltiplos sprites com movimentação*/
void teste_sprites_multiplos(void)
{
    printf("\n=== [11] MÚLTIPLOS SPRITES COM MOVIMENTAÇÃO ===\n");
    srand(11);

    isa_send(ENC_SET_LAYER(0, 1, 1));

    const int N = 12;
    Obj spr[N_SPR];
    sprites_inicia(spr, N);
    quadro();
    printf("  %d sprites (padrões 0..%d) parados\n", N, N - 1);
    pausa_ms(1000);

    printf("  Movendo: cada sprite com velocidade própria, quicando nas bordas (250 quadros)\n");
    for (int f = 0; f < 250; f++) {
        sprites_passo(spr, N);
        quadro();
    }

    printf("  Escondendo os sprites um a um\n");
    for (int i = 0; i < N; i++) {
        isa_send(ENC_SPR_HIDE(i));
        quadro();
        pausa_ms(120);
    }
}

/* 12. Múltiplos polígonos com movimentação */
void teste_poligonos_multiplos(void)
{
    printf("\n=== [12] MÚLTIPLOS POLÍGONOS COM MOVIMENTAÇÃO ===\n");
    srand(12);

    isa_send(ENC_SET_LAYER(1, 0, 1));

    static const int grupos[2][N_POLY] = { { 0, 1, 2, 4 }, { 3, 4, 5, 2 } };
    for (int g = 0; g < 2; g++) {
        Poly pol[N_POLY];
        polys_inicia(pol, grupos[g], N_POLY);
        quadro();
        printf("  Grupo %d:", g + 1);
        for (int s = 0; s < N_POLY; s++)
            printf(" [%d]%s/%d/0x%02X", s, TIPO_NOME[pol[s].tipo], pol[s].tam, pol[s].cor);
        printf("\n");
        pausa_ms(800);

        printf("  Movendo os 4 polígonos (200 quadros)...\n");
        for (int f = 0; f < 200; f++) {
            for (int s = 0; s < N_POLY; s++)
                poly_passo(s, &pol[s]);
            quadro();
        }
    }

    for (int s = 0; s < N_POLY; s++)
        isa_send(ENC_PLY_HIDE(s));
    quadro();
}

/* 13. Transparência*/
/* Sprite 4 por cima de um polígono, com o background mantido. A cor do
 * polígono alterna entre 0x00 (transparente) e verde: quando é 0x00, o
 * que aparece atrás do sprite é o background; quando é verde, o polígono. */
#define SPR_TRANSP   4      /* índice do sprite usado no teste (0..31) */
#define PAT_TRANSP   4      /* padrão desenhado por esse sprite        */
#define COR_VERDE    0x1C
#define COR_TRANSP   0x00
#define CICLOS_TRANSP 6
#define POLY_TRANSP_TAM 64

void teste_transparencia(void)
{
    printf("\n=== [13] TRANSPARÊNCIA (sprite %d sobre polígono) ===\n", SPR_TRANSP);

    /* BG + sprites + polígonos ligados; sprite na frente do polígono */
    isa_send(ENC_SET_LAYER(1, 1, 1));
    isa_send(ENC_SET_PRI(1));

    /* polígono (quadrado) verde no centro da tela */
    int px = (TELA_W - POLY_TRANSP_TAM) / 2;
    int py = (TELA_H - POLY_TRANSP_TAM) / 2;
    isa_send(ENC_PLY_COR(0, COR_VERDE));
    isa_send(ENC_PLY_ADJ(0, POLY_TRANSP_TAM));
    isa_send(ENC_PLY_DRAW(0, 5 /*quadrado*/, px, py));

    /* sprite 4 centralizado em cima do polígono */
    isa_send(ENC_SPR_PAT(SPR_TRANSP, PAT_TRANSP));
    isa_send(ENC_SPR_POS(SPR_TRANSP, (TELA_W - SPR_TAM) / 2, (TELA_H - SPR_TAM) / 2));
    isa_send(ENC_SPR_CFG(SPR_TRANSP, 1, 0, 0, 1));
    quadro();
    printf("  Sprite %d (padrão %d) sobre o polígono verde\n", SPR_TRANSP, PAT_TRANSP);
    pausa_ms(1500);

    for (int i = 0; i < CICLOS_TRANSP; i++) {
        isa_send(ENC_PLY_COR(0, COR_TRANSP));
        quadro();
        printf("  [%d/%d] polígono 0x00 (transparente): atrás do sprite aparece o background\n",
               i + 1, CICLOS_TRANSP);
        pausa_ms(1200);

        isa_send(ENC_PLY_COR(0, COR_VERDE));
        quadro();
        printf("  [%d/%d] polígono verde 0x%02X: atrás do sprite aparece o polígono\n",
               i + 1, CICLOS_TRANSP, COR_VERDE);
        pausa_ms(1200);
    }

    isa_send(ENC_PLY_HIDE(0));
    isa_send(ENC_SPR_HIDE(SPR_TRANSP));
    quadro();
}

/* 14. Troca de prioridade */
void teste_prioridade(void)
{
    printf("\n=== [14] TROCA DE PRIORIDADE ===\n");

    isa_send(ENC_SET_LAYER(1, 1, 1));

    /* A) sprite x polígono: SET_PRI */
    isa_send(ENC_PLY_COR(0, 0x03));
    isa_send(ENC_PLY_ADJ(0, 80));
    isa_send(ENC_PLY_DRAW(0, 5, 120, 80));
    isa_send(ENC_SPR_PAT(0, 0));
    isa_send(ENC_SPR_POS(0, 150, 100));
    isa_send(ENC_SPR_CFG(0, 1, 0, 0, 1));
    quadro();
    printf("  A) SET_PRI alterna sprite/polígono\n");
    for (int i = 0; i < 3; i++) {
        isa_send(ENC_SET_PRI(1));  quadro();
        printf("    SET_PRI 1: sprite na frente do polígono\n");  pausa_ms(900);
        isa_send(ENC_SET_PRI(0));  quadro();
        printf("    SET_PRI 0: polígono na frente do sprite\n");  pausa_ms(900);
    }
    isa_send(ENC_SET_PRI(1));
    isa_send(ENC_PLY_HIDE(0));
    isa_send(ENC_SPR_HIDE(0));
    quadro();

    /* B) sprite x sprite: SPR_CFG pri 0..3 */
    static const int pat[3] = { 0, 3, 5 };
    for (int i = 0; i < 3; i++) {
        isa_send(ENC_SPR_PAT(i, pat[i]));
        isa_send(ENC_SPR_POS(i, 140 + i * 8, 100 + i * 6));
    }
    printf("  B) Prioridade entre sprites (SPR_CFG pri 0..3), 3 sprites sobrepostos\n");
    for (int volta = 0; volta < 2; volta++) {
        for (int k = 0; k < 3; k++) {
            for (int i = 0; i < 3; i++)
                isa_send(ENC_SPR_CFG(i, 1, 0, 0, 3 - ((i - k + 3) % 3)));
            quadro();
            printf("    sprite %d (padrão %d) na frente\n", k, pat[k]);
            pausa_ms(1000);
        }
    }
    for (int i = 0; i < 3; i++)
        isa_send(ENC_SPR_HIDE(i));
    quadro();
}

/*15. Espelhamentos */
void teste_espelhamentos(void)
{
    printf("\n=== [15] ESPELHAMENTOS HORIZONTAL E VERTICAL ===\n");

    isa_send(ENC_SET_LAYER(0, 1, 1));

    /* A) quatro sprites lado a lado: normal, fh, fv, fh+fv */
    static const int padroes[2] = { 0, 3 };
    static const char *rotulo[4] = { "normal", "horizontal", "vertical", "horizontal+vertical" };
    for (int p = 0; p < 2; p++) {
        for (int i = 0; i < 4; i++) {
            isa_send(ENC_SPR_PAT(i, padroes[p]));
            isa_send(ENC_SPR_POS(i, 60 + i * 60, 110));
            isa_send(ENC_SPR_CFG(i, 1, i & 1, (i >> 1) & 1, 1));
        }
        quadro();
        printf("  A) Padrão %d, da esquerda para a direita:", padroes[p]);
        for (int i = 0; i < 4; i++)
            printf(" %s%s", rotulo[i], i < 3 ? "," : "\n");
        pausa_ms(2500);
    }
    for (int i = 0; i < 4; i++)
        isa_send(ENC_SPR_HIDE(i));
    quadro();

    /* B) patrulha: sprite 0 anda na horizontal virando fh, sprite 1 na vertical virando fv */
    printf("  B) Patrulha: sprite 0 espelha na horizontal, sprite 1 na vertical\n");
    Obj h = { 0, 60, 3, 0 };
    Obj v = { 150, 0, 0, 3 };
    isa_send(ENC_SPR_PAT(0, 0));  isa_send(ENC_SPR_POS(0, h.x, h.y));
    isa_send(ENC_SPR_CFG(0, 1, 0, 0, 1));
    isa_send(ENC_SPR_PAT(1, 0));  isa_send(ENC_SPR_POS(1, v.x, v.y));
    isa_send(ENC_SPR_CFG(1, 1, 0, 0, 1));
    quadro();
    for (int f = 0; f < 330; f++) {
        int vx0 = h.vx, vy0 = v.vy;
        prox(&h, SPR_TAM, SPR_TAM);
        prox(&v, SPR_TAM, SPR_TAM);
        if (h.vx != vx0) {
            isa_send(ENC_SPR_CFG(0, 1, h.vx < 0, 0, 1));
            printf("    sprite 0 virou para a %s\n", h.vx < 0 ? "esquerda (fh=1)" : "direita (fh=0)");
        }
        if (v.vy != vy0) {
            isa_send(ENC_SPR_CFG(1, 1, 0, v.vy < 0, 1));
            printf("    sprite 1 virou para %s (fv=%d)\n", v.vy < 0 ? "cima" : "baixo", v.vy < 0);
        }
        isa_send(ENC_SPR_MOV(0, VREG(h.vx), VREG(h.vy)));
        isa_send(ENC_SPR_MOV(1, VREG(v.vx), VREG(v.vy)));
        quadro();
    }
    isa_send(ENC_SPR_HIDE(0));
    isa_send(ENC_SPR_HIDE(1));
    quadro();
}

/* arquivo de instruções (substitui o ISSP/Tcl) */
static int carrega_arquivo(const char *nome, uint32_t *v, int max)
{
    FILE *f = fopen(nome, "r");
    if (!f) { perror(nome); return -1; }
    char linha[256];
    int n = 0;
    while (fgets(linha, sizeof linha, f) && n < max) {
        char *c = strchr(linha, '#');
        if (c) *c = '\0';
        char *fim;
        unsigned long w = strtoul(linha, &fim, 16);   /* aceita 0x opcional */
        if (fim != linha) v[n++] = (uint32_t)w;
    }
    fclose(f);
    return n;
}

/* -f: executa tudo; -p: monta a fila e executa uma por ENTER */
static void executa_arquivo(const char *nome, int passo_a_passo)
{
    static uint32_t v[4096];
    int n = carrega_arquivo(nome, v, 4096);
    if (n <= 0) { fprintf(stderr, "nenhuma instrução em %s\n", nome); erro_fatal = 1; return; }
    printf("\n=== ARQUIVO %s: %d instruções%s ===\n", nome, n,
           passo_a_passo ? " (passo a passo: ENTER executa a próxima)" : "");

    if (!passo_a_passo) {
        for (int i = 0; i < n && !erro_fatal; i++) {
            printf("  [%3d] 0x%08X\n", i + 1, v[i]);
            isa_send(v[i]);
        }
        return;
    }

    /* passo a passo: a fila guarda até 32; monta em blocos */
    for (int base = 0; base < n && !erro_fatal; base += 32) {
        int bloco = (n - base < 32) ? n - base : 32;
        coproc_modo_fila(1);
        for (int i = 0; i < bloco; i++)
            coproc_enfileira(v[base + i]);
        printf("  %d instruções na fila\n", coproc_fila_qtd());
        for (int i = 0; i < bloco; i++) {
            printf("  ENTER -> [%3d] 0x%08X ", base + i + 1, v[base + i]);
            fflush(stdout);
            int ch;
            while ((ch = getchar()) != '\n' && ch != EOF) ;
            int r = coproc_passo();
            printf("   %s, restam %d\n", r == 0 ? "executada" :
                   r == COPROC_ERR_HALT ? "HALT" : "erro", coproc_fila_qtd());
            if (r == COPROC_ERR_HALT) { erro_fatal = 1; break; }
        }
    }
    coproc_modo_fila(0);
}

/* Menu de testes*/
typedef struct {
    const char *nome;
    void (*fn)(void);
} Teste;

static const Teste TESTES[] = {
    { "Scroll do background (absoluto + relativo)",            teste_scroll_bg },
    { "Mostrar e mover um sprite",                              teste_sprite_mostrar_mover },
    { "Trocar padrões de sprite (e flips básicos)",             teste_trocar_sprites },
    { "Mostrar e mover um polígono",                            teste_poligono },
    { "DEMO COMPLETA: 32 sprites + polígonos + scroll",         demo_completa },
    { "Tiles: SET_TILE no tilemap oculto + SWAP_BG",            teste_tiles },
    { "Modo fila e passo a passo",                              teste_modo_fila },
    { "FIFO cheia, HALT e reset por software",                  teste_reset },
    { "Troca de tiles em intervalos (oculto até o SWAP_BG)",    teste_tiles_intervalos },
    { "Troca de background (SWAP_BG)",                          teste_troca_bg },
    { "Múltiplos sprites com movimentação",                     teste_sprites_multiplos },
    { "Múltiplos polígonos com movimentação",                   teste_poligonos_multiplos },
    { "Transparência",                                          teste_transparencia },
    { "Troca de prioridade",                                    teste_prioridade },
    { "Espelhamentos vertical e horizontal",                    teste_espelhamentos },
};
#define N_TESTES ((int)(sizeof TESTES / sizeof TESTES[0]))

/* Roda o teste i (0-based) a partir de um estado conhecido */
static void executa_teste(int i)
{
    if (erro_fatal) {
        printf("  (erro anterior: reset total antes de continuar)\n");
        coproc_reset(1);
        coproc_modo_fila(0);
        erro_fatal = 0;
    }
    estado_inicial();
    carrega_velocidades();
    TESTES[i].fn();
}

static void mostra_menu(void)
{
    printf("\n==============================================================\n");
    printf("   MENU DE CENÁRIOS DE TESTE — Coprocessador Gráfico (HPS)\n");
    printf("==============================================================\n");
    for (int i = 0; i < N_TESTES; i++)
        printf("  [%2d] %s\n", i + 1, TESTES[i].nome);
    printf("--------------------------------------------------------------\n");
    printf("  [ A] Executar todos em sequência\n");
    printf("  [ S] Mostrar status do coprocessador\n");
    printf("  [ R] Reset total por software (limpa a tela)\n");
    printf("  [ 0] Sair\n");
    printf("==============================================================\n");
    printf("Escolha: ");
    fflush(stdout);
}

/* Lê uma linha; devolve 0 em EOF */
static int le_linha(char *buf, size_t n)
{
    if (!fgets(buf, (int)n, stdin))
        return 0;
    buf[strcspn(buf, "\r\n")] = '\0';
    return 1;
}

static void espera_enter(void)
{
    char tmp[16];
    printf("\nPressione ENTER para voltar ao menu...");
    fflush(stdout);
    le_linha(tmp, sizeof tmp);
}

static void menu(void)
{
    char linha[64];
    for (;;) {
        mostra_menu();
        if (!le_linha(linha, sizeof linha))
            return;                                   /* EOF (Ctrl+D) */

        char *p = linha;
        while (*p == ' ' || *p == '\t') p++;
        if (*p == '\0')
            continue;

        if (*p == '0' && p[1] == '\0') return;
        if (*p == 'q' || *p == 'Q')    return;

        if (*p == 'a' || *p == 'A') {
            for (int i = 0; i < N_TESTES; i++)
                executa_teste(i);
            espera_enter();
        } else if (*p == 's' || *p == 'S') {
            print_status("Status:");
        } else if (*p == 'r' || *p == 'R') {
            coproc_modo_fila(0);
            coproc_reset(1);
            erro_fatal = 0;
            quadro();
            printf("Reset total feito.\n");
        } else {
            char *fim;
            long k = strtol(p, &fim, 10);
            if (fim == p || k < 1 || k > N_TESTES) {
                printf("Opção inválida: \"%s\"\n", linha);
                continue;
            }
            executa_teste((int)k - 1);
            espera_enter();
        }
    }
}

/*main*/
int main(int argc, char *argv[])
{
    printf("============================================\n");
    printf("  Teste Gráfico HPS <-> Coprocessador (ISA)\n");
    printf("============================================\n");

    if (pio_init() < 0)
        return 1;

    print_status("Inicial");

    int modo_arquivo = (argc > 2 &&
                        (strcmp(argv[1], "-f") == 0 || strcmp(argv[1], "-p") == 0));

    if (preparar(!modo_arquivo) < 0) {
        pio_close();
        return 1;
    }

    /* -f / -p arquivo: executa um arquivo de instruções (mantém a cena) */
    if (modo_arquivo) {
        executa_arquivo(argv[2], argv[1][1] == 'p');
        printf("\n=== Fim%s ===\n", erro_fatal ? " (interrompido por erro)" : "");
        print_status("Final");
        pio_close();
        return erro_fatal ? 1 : 0;
    }

    if (argc > 1) {
        /* sem menu: um teste numerado ou "todos" */
        if (strcmp(argv[1], "todos") == 0) {
            for (int i = 0; i < N_TESTES; i++)
                executa_teste(i);
        } else {
            int k = atoi(argv[1]);
            if (k < 1 || k > N_TESTES) {
                fprintf(stderr, "Teste inválido: %s (use 1..%d ou \"todos\")\n", argv[1], N_TESTES);
                pio_close();
                return 1;
            }
            executa_teste(k - 1);
        }
    } else {
        menu();
    }

    if (n_ok + n_falhas)
        printf("\nVerificações automáticas: %d ok, %d falha(s)\n", n_ok, n_falhas);
    printf("\n=== Fim dos testes%s ===\n", erro_fatal ? " (interrompido por erro)" : "");
    print_status("Final");
    pio_close();
    return (erro_fatal || n_falhas) ? 1 : 0;
}
