# Regras do repositório

`main.json` protege a branch `main`:

- mudanças só por pull request, com 1 aprovação de quem tem acesso de escrita;
- a aprovação precisa ser de um dono do código (`.github/CODEOWNERS`);
- um push novo no PR invalida aprovações anteriores, e o último push precisa ser aprovado por outra pessoa;
- todas as conversas do review precisam estar resolvidas;
- sem force push e sem apagar a branch;
- administradores do repositório podem passar por cima das regras.

No plano gratuito do GitHub, isso só funciona com o repositório público. Para aplicar:

```sh
gh api -X POST repos/lbkeppler/lowerx/rulesets --input .github/rulesets/main.json
```
