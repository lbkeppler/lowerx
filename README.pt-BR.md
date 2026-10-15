<p align="center">
  <img src="docs/images/icon.png" width="128" alt="Ícone do LowerX">
</p>

<h1 align="center">LowerX</h1>

<p align="center">
  <a href="README.md">English</a> · <b>Português</b> · <a href="README.es.md">Español</a>
</p>

<p align="center">
  Controle não oficial do <b>HyperX Cloud Stinger 2 Wireless</b> para macOS.<br>
  O NGENUITY só existe para Windows; o LowerX faz o mesmo papel no Mac.
</p>

<p align="center">
  <img src="docs/images/audio.png" width="820" alt="Janela principal do LowerX, aba Áudio">
</p>

## O que faz

- **Bateria, carga e estado do headset**, com o percentual na barra de menus.
- **Microfone**: mostra se está mutado (haste levantada) em tempo real.
- **Sidetone**: liga/desliga e escolhe entre os níveis **Padrão** (−25 dB, de fábrica) e **Otimizado** (−12 dB).
- **Desligamento automático**: nunca, 10, 20 ou 30 minutos.
- **Equalizador de 10 bandas** com os presets oficiais do NGENUITY (Mais graves, Menos graves, Mais agudos, Menos agudos, Voz, Jogos, Equilibrado) e um modo personalizado: arraste os pontos do gráfico.
- **Espacial**: músicas e vídeos em estéreo soam como alto-falantes à sua frente (HRTF da Apple).
- **Saída 7.1**: uma saída de som virtual com 8 canais. Jogos e filmes em 7.1 têm cada canal posicionado em 3D no fone.
- **Certificado no Discord**: o Discord passa a reconhecer o headset, como faz com o NGENUITY no Windows.
- **Outros aparelhos HyperX**: reconhece 56 modelos (159 IDs USB) e mostra a foto de cada um. Controles para eles ainda não existem.

<p align="center">
  <img src="docs/images/headset.png" width="560" alt="Aba Headset">
  <img src="docs/images/panel.png" width="250" alt="Painel da barra de menus">
</p>

## Aparelhos suportados

| Aparelho | Situação |
|---|---|
| HyperX Cloud Stinger 2 Wireless | ✅ Completo |
| Outros 55 modelos HyperX (headsets, teclados, mouses, microfones, mousepads) | 🔍 Detectados com nome e foto, ainda sem controles. [Contribuições são bem-vindas!](#contribuindo) |

## Requisitos

- macOS 14.2 ou mais recente.
- HyperX Cloud Stinger 2 Wireless (receptor USB `03F0:0D93`).
- Xcode (ou as Command Line Tools) para compilar.

## Compilar e instalar

```sh
./build-app.sh          # compila e instala em /Applications/LowerX.app
```

O app é assinado ad-hoc. Na primeira vez que o equalizador ou o espacial for usado, o macOS pede a permissão de **gravação de áudio do sistema**. A **Saída 7.1** é instalada pelo próprio app (pede a senha de administrador).

Para a Saída 7.1 tocar depois de reiniciar o Mac, ative **Abrir no login** em Ajustes.

<p align="center">
  <img src="docs/images/settings.png" width="560" alt="Ajustes">
</p>

## Como funciona

### Protocolo do headset

O controle foi reconstruído a partir do `NGenuity2Helper.exe` (parte do instalador do NGENUITY 2.38) e conferido no aparelho. Tudo passa por reports HID de 20 bytes na coleção vendor `0xFF90`/`0x0303`, no formato `06 FF BB <cmd> <valor>`:

| cmd | função | resposta |
|---|---|---|
| `01` | status | `r[4]` = 1 ou 4: headset ligado; 3: desligado |
| `02` | bateria | `r[7]` = % |
| `03` | carga | 1 carregando · 2 completa · 3 erro |
| `05` | microfone | 1 = mutado |
| `06` / `21` | ler / ligar sidetone | |
| `07` / `22` | ler / definir desligamento automático (min) | |
| `0B` / `23` | ler / definir nível do sidetone (dB com sinal) | |
| `20` | evento espontâneo da haste do microfone | 1 = mutado |

Os comandos de escrita ecoam `cmd valor 01` para todos os programas conectados. O nível do sidetone só é aplicado quando o sidetone é ligado, por isso o app desliga e religa ao trocar o nível.

> ⚠️ O nível do sidetone é um ganho em dB com sinal: valores positivos amplificam muito (`0x20` = +32 dB é ensurdecedor). O app só envia os dois níveis testados.

### Equalizador e espacial

No Windows, EQ e espacial são o DTS Headphone:X, um efeito de áudio do sistema; nada disso roda no headset. No Mac:

1. Um **process tap** do Core Audio (macOS 14.2+) captura o áudio que os apps mandam para o headset e silencia o original.
2. Um aggregate device privado junta o tap e o headset; o IOProc dele processa e toca o resultado.
3. Cadeia: origem → espacial (`AUSpatialMixer`, HRTF) → EQ (10 biquads por canal, pré-ganho anti-clipping) → headset.

Se o app fechar, o tap some e o som volta ao normal.

No espacial, o que é igual nos dois canais vai só para um alto-falante virtual central. Tocar o mesmo sinal em dois alto-falantes virtuais cria buracos no espectro (−15 dB em 2 kHz) e deixa tudo abafado.

### Saída 7.1

`Driver/LowerX71.c` é um driver AudioServerPlugIn próprio: uma saída de 8 canais (L R C LFE Ls Rs Rls Rrs) que só fornece o relógio e descarta o áudio. O app captura essa saída com o mesmo tap e posiciona cada canal: frentes a ±30°, centro a 0°, laterais a ±90° e traseiras a ±150°. Quando um app manda só estéreo para ela, o espacial decide como tocar.

### Discord

O app chama o RPC local do Discord (`127.0.0.1:6463–6472`) com `SET_CERTIFIED_DEVICES` e o `client_id` da HyperX, usando o UID Core Audio do headset, igual ao NGENUITY.

## Estrutura

```
Sources/LowerX/
  StingerProtocol.swift   comandos e respostas do headset
  HIDTransport.swift      IOHIDManager
  HeadsetModel.swift      estado e fila de comandos (120 ms entre envios)
  SystemAudioEQ.swift     tap + aggregate device + cadeia de efeitos
  SpatialRenderer.swift   upmix e AUSpatialMixer
  Equalizer.swift         presets e filtros
  AudioEffects.swift      quando ligar o pipeline, Saída 7.1, permissões
  DiscordCertifier.swift  certificação no Discord
  USBDeviceWatcher.swift  outros aparelhos HyperX (IOKit, sem permissão de entrada)
  DeviceCatalog.swift     gerado de tools/
  MainWindow.swift, LowerXApp.swift, Theme.swift, EqualizerGraph.swift   interface
Driver/                   saída virtual 7.1
tools/                    scripts para regenerar catálogo, imagens e ícone
```

### Ferramentas

| script | o que gera |
|---|---|
| `tools/extract_catalog.py` + `tools/gen_catalog_swift.py` | `DeviceCatalog.swift`, a partir do `NGenuity2Helper.exe` decompilado com `ilspycmd` |
| `tools/prepare_device_images.py` | `Assets/Devices`, uma imagem por modelo, a partir de `Assets/Devices` do pacote do NGENUITY |
| `tools/make_icon.swift` | `Assets/AppIcon.icns` |

## Contribuindo

Melhorias são muito bem-vindas, e pull requests também! 🙌

Algumas ideias:

- **Outros aparelhos HyperX.** Os protocolos estão no NGENUITY: decompile o `NGenuity2Helper.exe` com o `ilspycmd`; as classes de cada aparelho ficam em `NGenuity2.Devices.*`. Se você tem o aparelho, implemente, teste e mande um PR. Comece pelas leituras (bateria, estado) antes dos comandos de escrita.
- **EQ, Espacial e Saída 7.1 em qualquer fone**, não só no Stinger 2.
- **Tradução da interface**, que hoje está em português.
- **Bugs e sugestões**: abra uma issue.

Ao mandar um PR, conte o que testou e em qual aparelho e versão do macOS. Não inclua arquivos do instalador nem código decompilado do NGENUITY.

> ⚠️ Cuidado ao testar comandos de escrita: ganhos podem estar em dB (o sidetone em +32 dB foi ensurdecedor). Comece com valores baixos e o fone longe do ouvido.

## Créditos

- Imagens dos produtos: **HyperX**, dos materiais de imprensa de cada produto.
- Fonte [Saira](https://github.com/Omnibus-Type/Saira), licença SIL Open Font License (`Assets/Fonts/OFL.txt`).
- HyperX, NGENUITY e Cloud Stinger são marcas da HP Inc. O LowerX é um projeto independente, sem afiliação com a HyperX ou a HP.
