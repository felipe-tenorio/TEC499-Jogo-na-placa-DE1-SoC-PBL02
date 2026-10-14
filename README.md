<div align="center">
<h1 align="center">
 TEC499-Jogo-na-placa-DE1-SoC-PBL02
</h1>
</div>

## Descrição do Projeto
<details>
  <summary>Descrição</summary>

  O repositório é um dos componentes da segunda fase de um projeto do desenvolvimento de um jogo que irá funcionar na placa **DE1-SoC**. Na primeira fase foi desenvolvido o núcleo de um coprocessador gráfico em FPGA capaz de desenhar background, sprites e polígonos no VGA. Porém, cada motor gráfico ainda precisava ser controlado individualmente, escrevendo diretamente nos seus registradores.

  Nesta segunda fase o núcleo foi transformado em um **coprocessador gráfico programável**: o software não conhece mais os detalhes internos de cada motor, ele apenas envia **instruções de 32 bits** de uma ISA própria. O hardware busca, decodifica e executa essas instruções, acionando os motores gráficos necessários. A arquitetura segue a organização de um processador convencional, com unidade de busca, registrador de instrução (IR), unidade de controle, banco de registradores, ULA, datapath e registradores de estado. As instruções são enviadas pelo processador ARM (HPS) da placa por meio de PIOs mapeados em memória (**busca passiva**).

  O objetivo final deste projeto é criar um coprocessador gráfico completo para suportar a renderização visual de um protótipo do jogo Bomberman, que será controlado por um driver Linux em Assembly ARM e por uma aplicação em C nas etapas futuras.

  Recursos utilizados nesta segunda fase:
  - Placa Terasic DE1-SoC Board com FPGA Cyclone V SoC 5CSEMA5F31C6 (HPS ARM Cortex-A9 dual-core);
  - Quartus Prime 25.1std.0 Lite Edition e Platform Designer (Qsys);
  - ModelSim - Intel FPGA Starter Edition 2020.1 (simulação);
  - Verilog (comportamental).


<details>
  <summary><h2>Requisitos da 2º Etapa</h2></summary>

  - Definir e documentar uma **ISA de 32 bits**, com formatos de instrução e sintaxe própria;
  - Implementar o ciclo de **busca/execução** de instruções;
  - A arquitetura deve ter: unidade de busca, **registrador de instrução (IR)**, **unidade de controle**, **banco de registradores**, **ULA**, **datapath** e **registrador de status**;
  - Toda operação deve ser consequência da execução de uma instrução da ISA;
  - O **compositor**, a **unidade de controle de quadro** e o **controlador VGA** devem operar continuamente;
  - Mecanismo de **sincronização com o VGA**;
  - Comunicação com **valid / busy / done**;
  - Escolha entre busca **ativa** (memória de instruções interna) ou **passiva** (fila de comandos vinda do ARM via MMIO);
  - Pelo menos um programa escrito no **Assembly da ISA**;
  - Testbench para cada módulo principal e um testbench de integração do coprocessador;
  - Relatório de síntese, utilização de recursos, frequência máxima e análise de timing.
</details>

<details>
<summary><h2>Requisitos funcionais</h2></summary>

### Requisitos funcionais

Requisito | Situação | Onde está
:--- | :---: | :---
ISA de 32 bits documentada (opcode de 6 bits + campos) | Atendido | `control_unit.v`
Unidade de busca (passiva, por fila de comandos) | Atendido | `pio_cmd_iface.v`, `fifo_cmd.v`
Registrador de instrução (IR) | Atendido | `isa_core.v`
Unidade de controle (FSM multiciclo) | Atendido | `control_unit.v`
Banco de registradores de propósito geral (16 × 16 bits) | Atendido | `gpr_bank.v`
ULA | Atendido | `alu.v`
Registrador de status lido pelo ARM | Atendido | `pio_cmd_iface.v` (`pio_status`)
Motores de background, sprites e polígonos como unidades funcionais | Atendido | `motor_background.v`, `motor_sprites.v`, `rasterizador_multi.v`
Unidade de controle de quadro (frame buffer duplo + troca na VSYNC) | Atendido | `frame_buffer_duplo.v`, `coprocessor_core.v`
Compositor e controlador VGA em operação contínua | Atendido | `compositor.v`, `vga_driver.v`
Escrita das memórias de vídeo em tempo de execução (tilemap e padrões) | Atendido | instruções `SET_TILE` e `WR_RAM`
Sincronização com o VGA (`WAIT_VS`, trocas de buffer na VSYNC) | Atendido | `control_unit.v`, `coprocessor_core.v`
Sinais busy / done / estado da fila | Atendido | `pio_status`, LEDs
Modo de execução passo a passo (depuração) | Atendido | comandos `CTRL FILA_ON / PASSO`

</details>

<details>
<summary><h2>Estrutura proposta e decisões tomadas</h2></summary>

### Visão geral da arquitetura

O top-level (`ghrd_top.v`) instancia o sistema do HPS gerado no Platform Designer (`soc_system`) e o coprocessador (`coprocessor_core.v`). O HPS se comunica com o coprocessador por três PIOs ligados ao barramento *lightweight HPS-to-FPGA*. Dentro do coprocessador, as instruções passam por uma interface de comandos, uma FIFO, o núcleo da ISA (IR, unidade de controle, banco de registradores e ULA) e, por fim, chegam ao banco de registradores gráficos e às memórias de vídeo, que alimentam os motores.

```mermaid
flowchart LR
    ARM["HPS (ARM Cortex-A9)"] -- "pio_cmd_data (32b)\npio_cmd_push (1b)" --> PIO["pio_cmd_iface\n(detecção de borda +\ncomandos CTRL)"]
    PIO -- "pio_status (8b)" --> ARM
    PIO --> FIFO["fifo_cmd\n32 × 32 bits"]
    subgraph ISA["isa_core (clk_sys = 100 MHz)"]
        FIFO --> IR["IR"]
        IR --> CU["control_unit\n(FSM)"]
        IR --> GPR["gpr_bank\n16 × 16 bits"]
        GPR --> ALU["alu"]
        ALU --> GPR
        GPR --> CU
    end
    CU -- "gfx_wr_en / addr / data" --> REGS["banco_registradores"]
    CU -- "mem_we / addr / data" --> MEM["RAMs de vídeo\ntilemap A/B, padrões"]
    REGS -- "cópia na VSYNC" --> SH["registradores\nsombra (clk_pix)"]
    subgraph PIX["Domínio de pixel (clk_pix = 25 MHz)"]
        SH --> BG["motor_background"]
        SH --> SPR["motor_sprites"]
        SH --> PLY["rasterizador_multi"]
        MEM --> BG
        MEM --> SPR
        BG --> COMP["compositor"]
        SPR --> COMP
        PLY --> COMP
        COMP --> FB["frame_buffer_duplo\n2 × 320 × 240"]
        FB --> VGA["vga_driver\n640 × 480 @ 60 Hz"]
    end
```

<div align="center">
 <figure>
  <img src="Docs/Diagrama_coprocessador_pbl2.jpg" width="700px"/>
  <figcaption>
    <p align="center">
     <b>Figura 1</b> - Diagrama do Coprocessador Gráfico
    </p>
  </figcaption>
 </figure>
</div>

### Busca passiva

Foi escolhida a **busca passiva**: em vez de uma memória de instruções interna, o coprocessador recebe as instruções do ARM por uma fila de comandos. Essa decisão foi tomada porque:
- o jogo final será executado no ARM, então é ele quem decide o que desenhar a cada quadro (posição do jogador, inimigos, explosões), algo que um programa fixo em `.mif` não conseguiria fazer;
- prepara diretamente o caminho para o driver Linux em Assembly ARM das próximas etapas;
- permite trocar o programa de teste sem recompilar a FPGA.

A consequência é que o controle de fluxo (laços e desvios) fica no programa do ARM, por isso `JMP` e `BEQ` não têm efeito no hardware.

### Domínios de clock e sincronização

Foram mantidos os dois PLLs da primeira etapa, gerados a partir do `CLOCK_50`:
- `meu_pll`: gera o clock de pixel de 25 MHz (`clk_pix`) para 640 × 480 a 60 Hz;
- `pllpara100`: gera o clock de sistema de 100 MHz (`clk_sys`), usado pela interface de comandos, pela ISA, pelo banco de registradores gráficos e pelas RAMs de vídeo.

O reset global combina o `hps_fpga_reset_n` com os sinais `locked` dos dois PLLs. Os cruzamentos entre os domínios são feitos da seguinte forma:
- **VSYNC → clk_sys:** sincronizador de 3 flip-flops com detecção de borda (`vsync_borda_sys`), usado pela instrução `WAIT_VS` e pelo bit de status;
- **Pedidos de troca (clk_sys → clk_pix):** cada pedido inverte um *toggle*, que atravessa 3 flip-flops e é convertido de volta em pulso no domínio de pixel;
- **Atributos gráficos (clk_sys → clk_pix):** todos os atributos de sprites, polígonos, camadas e scroll são concatenados em um único vetor, registrados uma vez no domínio de pixel (`attr_meta`) e só copiados para os registradores usados pelos motores (`attr_pix`) na borda da VSYNC. Assim, uma cena nunca é desenhada com metade dos atributos antigos e metade novos;
- **Buffer visível (clk_pix → clk_sys):** `bg_frente` e `fb_frente` passam por 2 flip-flops e são usados pela unidade de controle para saber quando uma troca terminou.

Os caminhos para o primeiro estágio de cada sincronizador foram marcados como `set_false_path` em `soc_system_timing.sdc`.

### Interface de comandos (pio_cmd_iface)

O ARM escreve a palavra de 32 bits em `pio_cmd_data` e gera uma borda de subida em `pio_cmd_push` (escreve 1 e depois 0). A interface detecta essa borda e:
- se o opcode for `62` (**CTRL**), executa um comando de controle sem passar pela FIFO;
- caso contrário, coloca a palavra na FIFO (se ela estiver cheia, a palavra é descartada, por isso o software deve consultar o status antes de enviar).

Comandos de controle (`CTRL`, campo `ir[9:6]`):

Código | Comando | Função
:---: | :--- | :---
1 | `FILA_ON` | Ativa o modo fila: a FIFO apenas acumula instruções
2 | `FILA_OFF` | Desativa o modo fila: a FIFO volta a ser esvaziada em sequência
3 | `PASSO` | Executa uma única instrução da fila (com o modo fila ativo)
4 | `RESET_ISA` | Reinicia apenas o núcleo da ISA (FIFO, IR, GPRs e FSM)
5 | `RESET_TOTAL` | Reinicia a ISA e os registradores gráficos
6 | `VER_QTD` | `pio_status` passa a mostrar a quantidade de instruções na FIFO
7 | `VER_STATUS` | `pio_status` volta ao formato normal

O modo fila e o passo a passo foram criados para depuração: é possível carregar várias instruções e executá-las uma a uma, observando o efeito de cada uma na tela e nos LEDs.

### Núcleo da ISA (isa_core)

O `isa_core` agrupa a FIFO, o registrador de instrução, o banco de registradores, a ULA e a unidade de controle. A FIFO possui saída registrada, então o IR é carregado no ciclo seguinte ao `pop`. O banco de registradores possui 16 registradores de 16 bits, com `R0` fixo em zero, duas portas de leitura (`Rs` e `Rt`) e uma de escrita (`Rd`). A ULA de 16 bits realiza `ADD`, `SUB`, `AND`, `OR` e `MOV`.

Os registradores de propósito geral permitem que o movimento seja feito por **deslocamento relativo**: o programa guarda a velocidade em um registrador (por exemplo `R1 = 2`) e as instruções `MOV_BG`, `SPR_MOV` e `PLY_MOV` somam o valor dos registradores à posição atual do objeto.

### Unidade de controle

A unidade de controle é uma máquina de estados multiciclo:

```mermaid
stateDiagram-v2
    [*] --> IDLE
    IDLE --> FETCH: FIFO não vazia e não halt e (modo fila desligado ou PASSO)
    FETCH --> DECODE: pop da FIFO
    DECODE --> EXECUTE: IR carregado
    EXECUTE --> EXECUTE: micro-passos (seq) / espera VSYNC / espera troca
    EXECUTE --> WB: instrução concluída
    EXECUTE --> HALT: HALT
    WB --> IDLE: done (pulso)
    HALT --> HALT: só sai com RESET_ISA / RESET_TOTAL
```

- **IDLE:** aguarda instrução na FIFO;
- **FETCH:** retira a instrução da FIFO (`fifo_pop`);
- **DECODE:** o IR é carregado e o contador de micro-passos é zerado;
- **EXECUTE:** gera os sinais para o banco gráfico, memórias de vídeo, GPRs e ULA. Instruções que precisam escrever vários registradores gráficos (por exemplo `SPR_POS`, que seleciona o sprite e escreve X e Y) usam um contador interno `seq`, gastando um ciclo por escrita;
- **WB:** fim da instrução, gera o pulso `done`;
- **HALT:** trava o núcleo até um reset por software.

Instruções de sincronização ficam em EXECUTE até a condição ser atendida:
- `WAIT_VS` espera a próxima borda de VSYNC;
- `SWAP_FB` e `SWAP_BG` só terminam quando o buffer visível realmente trocou. Isso garante que as instruções seguintes nunca alterem o quadro que está prestes a ser apresentado.

### Unidade de controle de quadro (frame buffer duplo)

Diferente da primeira etapa, onde os motores enviavam a cor diretamente ao VGA, nesta etapa foi adicionado um **frame buffer duplo** de 2 × 320 × 240 bytes. O compositor escreve continuamente o quadro no buffer escondido (*back*), enquanto o VGA lê o buffer visível (*front*). O fluxo de uma troca é:

1. `SWAP_FB` pede a troca (`swap_fb_request`);
2. na próxima VSYNC os atributos novos são copiados e a troca fica "armada";
3. durante esse quadro a cena nova é composta inteira no buffer escondido;
4. na VSYNC seguinte os buffers são trocados e a instrução termina.

Essa decisão foi tomada para que uma cena nunca seja exibida pela metade, mesmo que o ARM demore para enviar todas as instruções de um quadro.

### Memórias de vídeo

As memórias continuam sendo blocos RAM dual-port gerados pelo Quartus (`altsyncram`), inicializados por arquivos `.mif`, mas agora possuem **porta de escrita ligada à ISA**:
- Duas RAMs de tilemap (A e B) de 2048 × 8 bits (`tilemap_a.mif`, `tilemap_b.mif`), com troca na VSYNC por `SWAP_BG`;
- RAM de padrões de tiles com 16384 × 8 bits (256 tiles de 8 × 8) (`padroes_tiles.mif`);
- RAM de padrões de sprites com 8192 × 8 bits (32 padrões de 16 × 16) (`padroes_sprites.mif`).

A instrução `SET_TILE` escreve uma posição do tilemap no buffer escondido, no visível ou em ambos, e `WR_RAM` escreve um byte qualquer em uma das quatro memórias. Com isso, a limitação da primeira etapa (memórias fixas, sem escrita em tempo de execução) foi resolvida.

### Motores gráficos

Os motores do Problema 1 foram reaproveitados como unidades funcionais, com pequenas alterações:
- **Motor de background:** pipeline de 3 estágios, tilemap 40 × 30, tiles 8 × 8 e scroll com *wrapping* por subtrações condicionais de 320/240;
- **Motor de sprites:** 32 sprites de 16 × 16 avaliados em paralelo, com espelhamento horizontal e vertical. A escolha entre sprites no mesmo pixel é feita por uma **árvore de comparação** de prioridade (em caso de empate vence o sprite de maior índice). O índice de cor `0` é transparente;
- **Rasterizador:** 4 slots de polígonos, com 6 formas (retângulo, quadrado, triângulo retângulo, isósceles com ápice para cima ou para baixo e escaleno), definidas por origem (X, Y) e tamanho. A geometria de cada slot é pré-calculada uma vez por ciclo e o teste de inclusão usa funções de aresta com aritmética inteira, em um pipeline de 3 estágios.

### Compositor e regra de prioridade

O compositor combina as três camadas com transparência pelo índice `0`. A prioridade entre sprites e polígonos agora é **configurável** pela instrução `SET_PRI`:
- `SET_PRI 1` (padrão): sprite > polígono > background;
- `SET_PRI 0`: polígono > sprite > background.

### Saída VGA

O `vga_driver` é usado apenas como gerador de timing (HSYNC, VSYNC e coordenadas). A cor é lida do frame buffer e convertida de RGB332 para os 8 bits por canal do DAC. Cor, HSYNC, VSYNC e BLANK são registrados juntos, com o mesmo atraso, e o `VGA_CLK` é o clock de pixel invertido, colocando a borda de amostragem do DAC no meio do pixel.

### Justificativa das principais decisões

As decisões centrais foram orientadas por três critérios:
- desacoplar o software dos detalhes internos de cada motor, deixando a ISA como única interface;
- manter a saída de vídeo estável e sem tearing, independentemente do ritmo do software;
- preparar a arquitetura para o driver em Assembly ARM e para o jogo em C das próximas etapas.

A busca passiva por PIO, a FIFO de comandos, as cópias de atributos na VSYNC, o frame buffer duplo e as instruções de troca que só terminam após a troca efetiva refletem esse equilíbrio entre simplicidade de hardware, previsibilidade para o software e estabilidade do vídeo.

</details>
