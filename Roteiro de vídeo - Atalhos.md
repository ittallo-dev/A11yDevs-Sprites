# Roteiro de vídeo: Atalhos casuais de uso no Emacs e Emacspeak

## 1. Abertura

Olá caro ouvintes, sou aluno da engenharia da computação e integrante do projeto A11yDevs, nesse projeto o nosso foco é desenvolver ferramentas e materiais focados nas áreas de programação e exatas.

Nesse vídeo eu vou mostrar alguns atalhos casuais e muito úteis para usar o **Emacs junto com o Emacspeak**, principalmente para quem quer navegar por arquivos, editar textos, salvar alterações, abrir diretórios e usar os recursos de leitura por voz.

A ideia aqui não é mostrar todos os comandos possíveis do Emacs, porque aí a gente teria que invocar uma entidade antiga do terminal. O foco é apresentar os atalhos mais práticos para o uso diário.

Antes de começar, uma observação importante:

Quando eu falar **C**, estou falando da tecla **Control**.
Quando eu falar **M**, estou falando da tecla **Alt esquerda**.
E quando eu referenciar alguma letra maiúscula, como **R**, **A** ou **C**, normalmente isso significa usar **Shift junto com a letra**, quando essa citação mais explicita não ocorrer, como **d**, **x** ou **g**, significa que essas letras em questão são usadas em minúsculo sem a tecla **Shift**.

Além disso, quando eu falar comandos do tipo **M-x**, geralmente você digita o comando e confirma com **Enter**.

---

## 2. Abrindo e criando arquivos

Vamos começar pelo básico: abrir ou criar arquivos.

O atalho principal é:

**C-x C-f**

Esse comando serve para abrir arquivos e pastas dentro do Emacs. Ele também pode ser usado para criar um arquivo novo.

Por exemplo: se eu pressiono **C-x C-f**, o Emacs abre o minibuffer pedindo o caminho ou o nome do arquivo.

Se eu digitar o nome de um arquivo que já existe, ele abre esse arquivo.
Se eu digitar um nome novo, como `teste.txt`, o Emacs cria esse arquivo quando eu salvar.

Esse é um dos comandos mais importantes para o uso diário, porque basicamente tudo começa aqui: abrir, criar ou acessar algum arquivo.

---

## 3. Salvando e fechando

Depois de editar um arquivo, você precisa salvar.

O comando para salvar é:

**C-x C-s**

Esse atalho salva as alterações recentes no arquivo aberto.

Agora, para fechar completamente o Emacs ou o Emacspeak, usamos:

**C-x C-c**

Esse comando encerra o programa.

Então, só para reforçar:

**C-x C-s** salva.
**C-x C-c** fecha.

Ou seja: primeiro salva, depois fecha. Parece óbvio, mas o caos digital começa exatamente quando alguém inverte essa ordem. Tragédia em dois atos.

---

## 4. Cancelando comandos com segurança

Um comando extremamente útil é:

**C-g**

Esse atalho serve para cancelar ações.

Por exemplo, se você apertou **C-x C-f** sem querer e o Emacs está esperando você digitar um arquivo, basta apertar **C-g** para sair daquele campo.

Ele também pode cancelar seleções, comandos incompletos ou operações que ficaram esperando uma resposta.

Pense no **C-g** como o botão de “me tira daqui” do Emacs.

Sempre que você se perder em algum comando, tente **C-g**.

---

## 5. Trabalhando com janelas e buffers

Agora vamos falar sobre janelas e buffers.

No Emacs, um buffer é como uma área onde um arquivo, diretório ou conteúdo está aberto.

Para dividir a tela horizontalmente, usamos:

**C-x 2**

Para dividir verticalmente:

**C-x 3**

Para fechar a janela atual:

**C-x 0**

E para manter apenas a janela atual, fechando as outras:

**C-x 1**

Esse último é muito útil quando a tela ficou cheia de divisões e você quer limpar tudo sem fechar o arquivo principal.

Para alternar entre janelas, usamos:

**C-x o**

Esse comando move o cursor de uma janela para outra.

Também existe o comando:

**C-x Left**
ou
**C-x Right**

Esses atalhos ajudam a transitar entre janelas ou buffers, dependendo da configuração.

Então, em resumo:

**C-x 2** divide horizontalmente.
**C-x 3** divide verticalmente.
**C-x 0** fecha a janela atual.
**C-x 1** mantém só a janela atual.
**C-x o** alterna entre janelas.

É como organizar uma mesa de trabalho, só que sem café derramado e com mais parênteses existenciais.

---

## 6. Copiar, colar, recortar e desfazer

Agora vamos para edição de texto.

Os atalhos principais são:

**M-w** para copiar.
**C-y** para colar.
**C-w** para recortar ou apagar o texto selecionado.
**C-/** para desfazer.

Então, o fluxo básico é:

Você seleciona um trecho.
Usa **M-w** para copiar.
Usa **C-y** para colar.
Ou usa **C-w** para cortar/remover.

Se fizer algo errado, usa:

**C-/**

Esse comando desfaz a última ação.

É o famoso “voltar no tempo”, só que infelizmente apenas dentro do Emacs. No resto da vida, seguimos sem patch de correção.

---

## 7. Selecionando textos e linhas

Para selecionar textos, existem algumas formas.

Uma delas é usar:

**M-A**

Esse comando pode ser usado para selecionar uma ou mais linhas em arquivos de texto.

Outra forma é usar:

**C-Space C-Space**
e depois mover com as setas:

**Left**, **Right**, **Up** ou **Down**

Esse método serve para selecionar trechos em diferentes tipos de arquivo.

Depois de selecionar, você pode copiar com:

**M-w**

Ou apagar/cortar com:

**C-w**

E caso queira cancelar a seleção, pode usar:

**C-g**

Então, o processo fica assim:

Ativa a seleção.
Move o cursor até onde quer selecionar.
Copia, recorta ou cancela.

---

## 8. Navegação por linhas e palavras com Emacspeak

Agora entramos em uma parte muito importante para quem usa o Emacspeak: navegação com leitura.

Para mover linha por linha, usamos:

**C-p** para ir para a linha anterior.
**C-n** para ir para a próxima linha.

Além de mover o cursor, o Emacspeak também lê a linha para onde você foi.

Isso é muito útil para revisar texto, código ou qualquer conteúdo aberto no buffer.

Para navegar por palavras, usamos:

**M-f** para avançar uma palavra.
**M-b** para voltar uma palavra.

O Emacspeak também lê a palavra em que o cursor chega.

Então:

**C-p** e **C-n** são ótimos para navegar por linhas.
**M-f** e **M-b** são ótimos para navegar por palavras.

Esses atalhos tornam a navegação muito mais fluida, principalmente quando você está revisando código, textos ou arquivos de configuração.

---

## 9. Comandos de leitura do Emacspeak

Agora vamos aos comandos específicos de leitura do Emacspeak.

Para ler a linha atual:

**C-e l**

Para ler a palavra atual:

**C-e w**

Para ler o parágrafo onde o cursor está:

**C-e h**

Para ler o buffer inteiro a partir da posição do cursor:

**C-e b**

Para informar o tipo de buffer e o arquivo aberto:

**C-e t**

E para reiniciar ou parar o leitor do Emacspeak:

**C-e C-s**

Esses comandos são muito importantes porque permitem controlar exatamente o que será lido.

Por exemplo:

Se eu quero ouvir só a linha atual, uso **C-e l**.
Se quero ouvir a palavra onde estou, uso **C-e w**.
Se quero revisar um parágrafo inteiro, uso **C-e h**.
Se quero escutar o restante do conteúdo, uso **C-e b**.
E se quero saber em que buffer ou arquivo estou, uso **C-e t**.

Esse conjunto deixa o uso do Emacspeak muito mais prático e menos dependente de ficar navegando no escuro, que é basicamente o esporte oficial de qualquer sistema mal configurado.

---

## 10. Diretórios, arquivos e Dired

Agora vamos falar sobre diretórios e gerenciamento de arquivos.

O comando:

**M-x dired**

abre o modo Dired, que permite navegar pelas pastas e arquivos do sistema dentro do Emacs.

Também podemos usar:

**C-x C-d**

para listar arquivos e pastas presentes em um diretório.

Dentro do Dired, existem comandos úteis.

Para renomear um arquivo ou pasta, usamos:

**R**

Esse comando também pode ser usado para mover arquivos. Basta informar o novo caminho junto com o novo nome ou destino.

Para copiar um arquivo para outro local dentro do Dired, usamos:

**C**

Para criar uma pasta dentro do diretório atual, usamos:

**C-+**

Também existe o comando:

**M-x make-directory**

Ele serve para criar uma pasta dentro do sistema do Emacs ou dentro de outra pasta já criada.

Para deletar arquivos no Dired, usamos:

**d**

Esse comando marca o arquivo para exclusão.

Depois, usamos:

**x**

E confirmamos com:

**yes**

Então, o processo para deletar é:

Entrar no diretório.
Marcar o arquivo com **d**.
Executar com **x**.
Confirmar com **yes**.

O Dired é basicamente um gerenciador de arquivos dentro do Emacs. Porque, aparentemente, abrir o explorador de arquivos seria simples demais para uma ferramenta que também quer ser um universo paralelo.

---

## 11. Procurar e saltar para linhas

Para procurar palavras, números ou nomes dentro do buffer, usamos:

**C-s**

Depois, digitamos aquilo que queremos encontrar.

O Emacs procura e move o cursor automaticamente para o resultado.

Por exemplo:

Se eu quero achar a palavra `configuração`, pressiono **C-s** e digito `configuração`.

Outro comando útil é:

**M-g g**

Esse comando permite saltar diretamente para uma linha específica.

Depois de usar o atalho, você digita o número da linha e confirma.

Por exemplo:

**M-g g 50**

Isso leva o cursor para a linha 50.

Esses dois comandos são muito úteis para navegar em arquivos grandes, principalmente scripts, códigos e documentos longos.

---

## 12. Avaliando código Emacs Lisp

Para quem mexe com arquivos `.el`, que são arquivos Emacs Lisp, existe o comando:

**M-x eval-region**

Esse comando avalia, ou “compila”, uma região selecionada de código.

Na prática, você seleciona um bloco de código `.el`, executa **M-x eval-region**, pressiona Enter e o Emacs aplica aquela alteração.

Isso é útil quando você está modificando configurações ou testando funções sem precisar reiniciar tudo.

É como trocar uma peça do motor com o carro andando. Funciona, mas convém saber o que está fazendo para não transformar o Emacs em uma criatura mitológica berrando erro.

---

## 13. Recapitulação rápida

Então, recapitulando os atalhos principais:

Para abrir ou criar arquivo:

**C-x C-f**

Para salvar:

**C-x C-s**

Para fechar o Emacs:

**C-x C-c**

Para cancelar comandos:

**C-g**

Para dividir janelas:

**C-x 2** e **C-x 3**

Para fechar janelas:

**C-x 0** ou **C-x 1**

Para alternar entre janelas:

**C-x o**

Para copiar, colar e cortar:

**M-w**, **C-y** e **C-w**

Para desfazer:

**C-/**

Para navegar por linhas:

**C-p** e **C-n**

Para navegar por palavras:

**M-f** e **M-b**

Para leitura com Emacspeak:

**C-e l**, **C-e w**, **C-e h**, **C-e b**, **C-e t** e **C-e C-s**

Para acessar diretórios:

**M-x dired**

Para buscar no buffer:

**C-s**

Para ir até uma linha específica:

**M-g g**

---

## 14. Encerramento

E esse foi um guia direto com atalhos casuais para usar o Emacs e o Emacspeak no dia a dia.

A ideia é começar com esses comandos, praticar aos poucos e ganhar fluidez. No começo parece muita coisa, mas depois os atalhos começam a entrar na memória muscular e as coisas passam a fluir de forma natural tal como andar.

O Emacs pode parecer intimidador no início, mas com esses comandos básicos você já consegue abrir arquivos, editar textos, navegar por buffers, gerenciar diretórios e usar os principais recursos de leitura do Emacspeak.

Agradeço pela atenção e até logo mais.
