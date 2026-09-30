# ShortcutKey

App gratuito e de código aberto para macOS que fica na barra de menu e permite:

- **Encerrar apps de verdade** ao fechar a última janela (botão vermelho ou ⌘W)
- **Mudar o que os botões vermelho, amarelo e verde fazem** (encerrar, ocultar, minimizar, maximizar sem tela cheia…)
- **Alternar entre apps estilo Windows**: arraste com 3 dedos para os lados, escolha o app e solte os dedos
- **Gestos no trackpad**: arrastar com 3 ou 4 dedos (cima/baixo/esquerda/direita) e tocar com 3, 4 ou 5 dedos
- **Atalhos de teclado globais** e remapeamento de combinações
- **Print com ⌘⇧S**: congela a tela durante a seleção, copia na hora para a área de transferência e mostra uma miniatura no canto; clique nela para abrir na Pré-Visualização

Ações disponíveis para gestos e atalhos: Mostrar a Mesa, Mission Control, App Exposé, trocar de mesa (Space),
fechar/minimizar/maximizar/centralizar janela, metade esquerda/direita, tela cheia, encerrar/ocultar app,
clique do meio, trocar de aba, voltar/avançar e qualquer atalho de teclado personalizado.

## Instalação

1. Baixe o `ShortcutKey-<versão>.dmg` em **[Releases](../../releases)**.
2. Abra o `.dmg` e arraste o **ShortcutKey** para **Aplicativos**.
3. Abra o ShortcutKey. Na primeira vez o macOS avisa que o app é de um "desenvolvedor não identificado"
   (ele é gratuito e não tem a assinatura paga da Apple):
   vá em **Ajustes do Sistema › Privacidade e Segurança**, role até o fim e clique em **Abrir Mesmo Assim**.
4. A tela de boas-vindas mostra as permissões: libere **Acessibilidade** (obrigatória) e
   **Gravação de Tela** (para miniaturas no alternador e para o print). Pronto.

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
| `Switcher.swift`, `SwitcherView.swift` | Alternador de apps/janelas (estilo AltTab) |
| `scripts/make-icon.swift` | Desenha o ícone (Daruma original) e gera `Resources/AppIcon.icns` |

## Licença

MIT
