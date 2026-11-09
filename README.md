# Parabéns, seu site está no ar! 🎉

Site estático de comemoração para quem acabou de colocar o primeiro site no ar em um servidor (instância EC2).
Uma página só, sem build, sem dependências e sem chamadas externas: a fonte e o GIF vêm do próprio servidor.

## O que a página mostra

- Mensagem de parabéns com o GIF dos gatinhos dançando.
- Endereço, status e tempo de resposta **reais** da visita (lidos do navegador, não são fixos).
- Botão "Copiar o endereço" para compartilhar o site.
- Personalização pela URL: `http://SEU-IP/?nome=Maria` vira "Parabéns, Maria!".
- Quem ativa "reduzir movimento" no sistema vê uma imagem parada no lugar do GIF.

## Colocar no ar (Amazon Linux 2023)

Com o `setup-al2023.sh` numa instância nova (portas 22 e 80 abertas):

```bash
sudo REPO_URL=https://github.com/pablinrlq/parabens-servidor-no-ar.git APP_TYPE=static bash setup-al2023.sh
```

O script instala o Nginx, aponta a raiz para `dist/` e publica o site. Para atualizar depois:

```bash
sudo appctl deploy
```

## Sem o script (qualquer servidor com Nginx)

Copie a pasta `dist/` para a raiz do site (por exemplo `/usr/share/nginx/html`) e pronto.

## Estrutura

```
dist/
├── index.html        # a página inteira (HTML, CSS e JS)
└── assets/           # GIF, imagem parada e fonte (nomes com hash para cache longo)
```

## Créditos

Fonte [Bricolage Grotesque](https://github.com/ateliertriay/bricolage) sob licença SIL OFL 1.1 (`dist/assets/bricolage.OFL.txt`).
