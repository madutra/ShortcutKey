# ShortcutKey

App gratuito e de código aberto para macOS que fica na barra de menu e permite:

- **Encerrar apps de verdade** ao fechar a última janela (botão vermelho ou ⌘W)
- **Mudar o que os botões vermelho, amarelo e verde fazem** (encerrar, ocultar, minimizar, maximizar sem tela cheia…)
- **Deslizar entre apps com 3 dedos**: igual à troca de apps em tela cheia do macOS, mas com qualquer app aberto (funciona também com o Organizador Visual)
- **Alternador de apps e janelas estilo AltTab** pelo teclado (⌥⇥), com miniaturas, ícones ou títulos
- **Gestos no trackpad**: arrastar com 3 ou 4 dedos (cima/baixo/esquerda/direita) e tocar com 3, 4 ou 5 dedos
- **Atalhos de teclado globais** e remapeamento de combinações (já vem com ⌥⌘L para bloquear a tela)
- **Remapear teclas** (como as teclas extras de teclados japoneses), com importação das "Simple Modifications" do Karabiner-Elements
- **Botões do mouse**: qualquer botão extra pode abrir o Mission Control, mostrar a Mesa, rodar um atalho etc.
- **DPI do mouse** em mouses Logitech com HID++ (ex.: G502), sem precisar do software da Logitech
- **Notch interativo** (ilha dinâmica): passe o mouse no notch para ver o Spotify, o calendário do dia, a bateria,
  uma prateleira de arquivos com AirDrop e Compartilhar, e o Wi-Fi/Bluetooth. Mostra também notificações
  (WhatsApp, Mensagens…), ligações com botões de atender e recusar, e quando um modo de foco liga ou desliga.
  Mostra o que toca em qualquer app (inclusive YouTube no navegador), tem espelho da câmera e controla
  volume e brilho com a mesma ilha de vidro. O notch não aparece em prints nem no compartilhamento de tela
- **Atalhos pausados em apps de acesso remoto** (Windows App, AnyDesk, TeamViewer, máquinas virtuais…): as teclas vão direto para a conexão
- **Print com ⌘⇧S**: congela a tela durante a seleção, copia na hora para a área de transferência e mostra uma miniatura no canto; clique nela para abrir na Pré-Visualização

Ações disponíveis para gestos e atalhos: Mostrar a Mesa, Mission Control, App Exposé, trocar de mesa (Space),
fechar/minimizar/maximizar/centralizar janela, metade esquerda/direita, tela cheia, encerrar/ocultar app,
clique do meio, trocar de aba, voltar/avançar, bloquear a tela e qualquer atalho de teclado personalizado.

## Instalação

1. Baixe o `ShortcutKey-<versão>.dmg` em **[Releases](../../releases)**.
2. Abra o `.dmg` e arraste o **ShortcutKey** para **Aplicativos**.
3. Abra o ShortcutKey. Na primeira vez o macOS avisa que o app é de um "desenvolvedor não identificado"
   (ele é gratuito e não tem a assinatura paga da Apple):
   vá em **Ajustes do Sistema › Privacidade e Segurança**, role até o fim e clique em **Abrir Mesmo Assim**.
4. A tela de boas-vindas mostra as permissões: libere **Acessibilidade** (obrigatória) e
   **Gravação de Tela** (para miniaturas no alternador e para o print). Pronto.
   Para mudar o DPI do mouse, o app pede também **Monitoramento de Entrada**.

Funciona no macOS 14 (Sonoma) ou mais recente, em Macs Apple Silicon e Intel.

## Compilar a partir do código

```bash
./build.sh
cp -R build/ShortcutKey.app /Applications/
open /Applications/ShortcutKey.app
```

Na primeira vez, permita o ShortcutKey em **Ajustes do Sistema › Privacidade e Segurança › Acessibilidade**.

### Gerar um release

```bash
./scripts/release.sh   # cria dist/ShortcutKey-<versão>.dmg e .zip (Apple Silicon + Intel)
```

Suba os dois arquivos em uma nova Release no GitHub. Assine sempre com o mesmo certificado
(`ShortcutKey Dev`): assim quem atualizar não precisa liberar as permissões de novo.

### Não perder as permissões a cada compilação

Sem certificado, cada compilação gera uma assinatura nova e o macOS esquece as permissões
(o `build.sh` apaga as entradas antigas para ele pedir de novo). Para evitar isso, crie uma vez um
certificado local:

1. Abra **Acesso às Chaves** (Keychain Access).
2. Menu **Acesso às Chaves › Assistente de Certificado › Criar um Certificado…**
3. Nome: `ShortcutKey Dev` · Tipo de identidade: **Auto-assinado raiz** · Tipo de certificado: **Assinatura de Código**.
4. Clique em **Criar**.

A partir daí o `build.sh` usa esse certificado automaticamente. Libere as permissões uma última vez e pronto.

Se algo não funcionar, veja o log em `~/Library/Logs/ShortcutKey.log`.

## Gestos do trackpad

Se o macOS já usa o mesmo gesto (ex.: arrastar com 4 dedos para trocar de mesa ou abrir o Mission Control),
os dois acontecem juntos. Desative o gesto do sistema em **Ajustes › Trackpad › Mais Gestos**.

A leitura dos dedos usa o framework privado `MultitouchSupport` (o mesmo usado por MiddleClick e Jitouch).
Por isso o app não pode ir para a Mac App Store, e uma atualização futura do macOS pode exigir ajustes.

## Mouse e teclado

- Botões que o mouse trata por dentro (no G502: DPI + / − e o shift) só chegam ao Mac com
  **Mouse › Perfis da memória do mouse** desligado. Depois disso, use **Detectar outro botão** e aperte o botão.
- O DPI escolhido fica guardado e é reaplicado quando o mouse é reconectado ou o Mac acorda.
- O remapeamento de teclas usa o recurso do próprio macOS (`hidutil`), sem driver. Ele vale enquanto o
  ShortcutKey estiver aberto. Se usar o Karabiner-Elements ao mesmo tempo, ele pode impedir o acesso ao mouse.

## Notch

- Funciona nos Macs com notch. Em telas sem notch, ligue **Notch › Mostrar uma ilha no topo da tela**.
- Na primeira vez, o macOS pede permissão para: controlar o Spotify (botões de tocar/pausar), ler o Calendário,
  usar o Bluetooth e a Localização (só para mostrar o nome da rede Wi-Fi; a localização não é usada).
- O "Tocando Agora" (o que toca em qualquer app, com capa) vem do framework privado `MediaRemote`. Desde o
  macOS 15.4 ele só responde a processos da Apple, então a ponte `Helpers/MediaRemoteBridge.c` roda dentro do
  `/usr/bin/perl` do sistema, o mesmo método de outros apps de notch. Se uma atualização do macOS fechar esse
  caminho, o notch volta a mostrar só o Spotify e o Música.
- As teclas de volume e brilho aparecem no notch; com "Esconder o aviso do macOS", o próprio ShortcutKey muda
  o nível (o brilho de monitores externos continua com o macOS).
- As notificações e ligações são lidas dos banners do macOS pela Acessibilidade. O modo de foco é detectado pelo
  ícone do Foco na barra de menu (Ajustes › Central de Controle › Foco › "Mostrar quando Ativo").

## Dicas

- Segure **⌥ Option** ao clicar em um botão da janela para usar o comportamento padrão do macOS.
- Adicione apps em **Janelas › Exceções** para que eles nunca sejam afetados (o Finder já vem na lista).
- Encerrar um app funciona como ⌘Q: se houver algo não salvo, o app pergunta antes de fechar.

## Estrutura

| Arquivo | O que faz |
|---|---|
| `Sources/MultitouchBridge` | Ponte em C para o trackpad (MultitouchSupport) e para o Dock |
| `GestureEngine.swift` | Reconhece toques e arrastes a partir da posição dos dedos |
| `EventTap.swift` | Intercepta cliques nos botões da janela e atalhos de teclado |
| `Actions.swift` | Executa as ações (janelas, apps, Mission Control, teclas) |
| `Accessibility.swift` | Utilitários da API de Acessibilidade |
| `Settings.swift` | Modelos e armazenamento das configurações |
| `SettingsView.swift` | Tela de configurações (SwiftUI) |
| `MouseDPI.swift`, `MouseSettingsView.swift` | DPI (HID++ da Logitech) e botões do mouse |
| `Notch.swift`, `NotchView.swift`, `NotchPages.swift` | Notch interativo: janela, abas e animações |
| `NowPlaying.swift`, `NotchCalendar.swift`, `Connectivity.swift` | Música, calendário, Wi-Fi/Bluetooth do notch |
| `CameraMirror.swift`, `SystemLevels.swift` | Espelho da câmera; volume e brilho pelas teclas |
| `Helpers/MediaRemoteBridge.c` | Ponte do "Tocando Agora" do macOS (qualquer app, com capa) |
| `NotificationWatcher.swift` | Notificações, ligações e modo de foco na ilha do notch |
| `KeyRemapper.swift` | Remapeamento de teclas e importação do Karabiner-Elements |
| `AppSwipe.swift` | Deslizar entre apps com o trackpad (animação e fotos dos apps) |
| `Switcher.swift`, `SwitcherView.swift` | Alternador de apps/janelas pelo teclado (estilo AltTab) |
| `scripts/make-icon.swift` | Desenha o ícone (Daruma original) e gera `Resources/AppIcon.icns` |

## Licença

MIT
