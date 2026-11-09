# Parabéns!

Site estático de comemoração: um "Parabéns!" e o GIF dos gatinhos dançando.
Página única em `dist/`, sem build e sem chamadas externas.

## Colocar no ar (Amazon Linux 2023)

Na instância nova (portas 22 e 80 abertas), com o `setup-parabens.sh`:

```bash
sudo bash setup-parabens.sh
```

Ele instala tudo (Nginx, atualizações automáticas, usuário e serviço do app) e publica este repositório.
Para atualizar depois: `sudo appctl deploy`.

## Sem o script

Copie a pasta `dist/` para a raiz de qualquer servidor web (por exemplo `/usr/share/nginx/html`).

## Créditos

Fonte Bricolage Grotesque, licença SIL OFL 1.1 (`dist/assets/bricolage.OFL.txt`).
