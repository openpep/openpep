# Inter para o PDF da receita

Subconjuntos latinos da Inter (SIL OFL 1.1, ver `../OFL.txt`), gerados a partir de `../inter-{400,500,600,700}.ttf`
com fontTools 4.60.1. O `pdf-lib` embute estes arquivos inteiros: o subconjunto do `@pdf-lib/fontkit` em tempo de
execução perdia glifos desta fonte.

```
pyftsubset inter-$w.ttf --unicodes="U+0020-007E,U+00A0-00FF,U+2013-2014,U+2018-2019,U+201C-201D,U+2022,U+2026,U+00B7" \
  --layout-features='' --no-hinting --desubroutinize --output-file=pdf/inter-$w-latin.ttf
```

O conteúdo da receita só aceita esses caracteres (`api/receita-doc.mjs`).
