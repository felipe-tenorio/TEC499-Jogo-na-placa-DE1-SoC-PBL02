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
  - A arquitetura deve conter, no mínimo: unidade de busca, **registrador de instrução (IR)**, **unidade de controle**, **banco de registradores**, **ULA**, **datapath** e **registrador de status**;
  - Os motores de **background**, **sprites** e **polígonos** do Problema 1 devem ser tratados como **unidades funcionais** do coprocessador;
  - Toda operação deve ocorrer como consequência da execução de uma instrução da ISA;
  - O **compositor**, a **unidade de controle de quadro** e o **controlador VGA** devem operar continuamente, independentemente da execução das instruções;
  - Mecanismo de **sincronização com o VGA**;
  - Comunicação do tipo **valid / busy / done**;
  - Escolha entre busca **ativa** (memória de instruções interna) ou **passiva** (fila de comandos vinda do ARM via MMIO);
  - Pelo menos um programa escrito no **Assembly da ISA** criada pela equipe;
  - Testbench para cada módulo principal e um testbench de integração do coprocessador;
  - Relatório de síntese, utilização de recursos, frequência máxima e análise de timing.
</details>

<details>
<summary><h2>Requisitos funcionais e Não funcionais</h2></summary>

### Requisitos funcionais

Requisito | Situação | Onde está
:--- | :---: | :---
ISA de 32 bits documentada (opcode de 6 bits + campos) | Atendido | `control_unit.v`, seção [ISA](#isa---instruction-set-architecture)
Unidade de busca (passiva, por fila de comandos) | Atendido | `pio_cmd_iface.v`, `fifo_cmd.v`
Registrador de instrução (IR) | Atendido | `isa_core.v`
Unidade de controle (FSM multiciclo) | Atendido | `control_unit.v`
Banco de registradores de propósito geral (16 × 16 bits) | Atendido | `gpr_bank.v`
ULA (ADD, SUB, AND, OR, MOV) | Atendido | `alu.v`
Registrador de status lido pelo ARM | Atendido | `pio_cmd_iface.v` (`pio_status`)
Motores de background, sprites e polígonos como unidades funcionais | Atendido | `motor_background.v`, `motor_sprites.v`, `rasterizador_multi.v`
Unidade de controle de quadro (frame buffer duplo + troca na VSYNC) | Atendido | `frame_buffer_duplo.v`, `coprocessor_core.v`
Compositor e controlador VGA em operação contínua | Atendido | `compositor.v`, `vga_driver.v`
Escrita das memórias de vídeo em tempo de execução (tilemap e padrões) | Atendido | instruções `SET_TILE` e `WR_RAM`
Sincronização com o VGA (`WAIT_VS`, trocas de buffer na VSYNC) | Atendido | `control_unit.v`, `coprocessor_core.v`
Sinais busy / done / estado da fila | Atendido | `pio_status`, LEDs
Modo de execução passo a passo (depuração) | Atendido | comandos `CTRL FILA_ON / PASSO`

</details>

