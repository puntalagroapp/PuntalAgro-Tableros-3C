---
description: "Auditoría de solo lectura: compara el repo del cliente (carpeta local o URL de git) contra los tableros ya migrados y reporta cuáles tienen cambios pendientes de reflejar. No modifica nada. Uso: /migracion-revisar-cambios ruta/o/URL/del-repo-del-cliente [rama]"
---

Actuá como un ingeniero de software senior especializado en migración de aplicaciones web standalone a arquitectura 3 capas.

## Contexto del proyecto

- Stack: Frontend HTML/JS ES5 → API Node.js/Express (server.js) → PostgreSQL 16
- El cliente mantiene su propio repo standalone y, cuando mejora algo, entrega el repo completo (no archivos sueltos)
- Este proyecto va migrando esos tableros de a uno a arquitectura 3 capas; cada migración deja una copia del HTML original en `client-src/YYYY-MM-DD/`

**Repo del cliente a revisar:** $ARGUMENTS

Este skill es **de solo lectura sobre el proyecto**: no crea ramas, no preserva nada en `client-src/`, no modifica ningún archivo del proyecto. Es un triage rápido para decidir sobre qué tableros vale la pena correr `/migracion-analizar` después.

### ⚠️ Invariante que no se puede romper

**El único baseline válido para comparar es la carpeta `client-src/*/` más reciente para cada tablero — nunca un clon temporal de una corrida anterior de este mismo skill.**

Este skill se puede correr muchas veces sobre el mismo tablero sin que eso genere ningún efecto acumulativo: cada corrida clona fresco (si es una URL), compara contra `client-src/` (que solo cambia cuando de verdad se corre `/migracion-analizar`), y descarta el clon al terminar. Si mañana el cliente todavía no mandó cambios reales, correr este skill 10 veces seguidas tiene que dar exactamente el mismo resultado que correrlo una vez. Nunca guardar, cachear, ni reutilizar un clon de una corrida anterior como referencia — ni de este skill ni de ninguna otra.

---

## PASO 0 — Obtener el repo del cliente

1. Determinar si $ARGUMENTS es una URL de git (empieza con `git@`, `http://`, `https://`, o termina en `.git`) o una carpeta local.
2. **Si es una carpeta local:** usarla directamente, sin copiar ni clonar nada. Continuar con PASO 1.
3. **Si es una URL:**
   - Clonar en modo superficial a una carpeta temporal nueva y con nombre único por corrida (ej. usando el directorio de scratchpad de la sesión + timestamp), para no pisar ni mezclar con clones de corridas anteriores:
     ```bash
     git clone --depth 1 [-b RAMA] <URL> /ruta/scratchpad/repo-cliente-<timestamp>
     ```
   - Si se pasó un segundo argumento (rama), usarlo con `-b`; si no, se clona la rama por defecto del repo.
   - Si el clone falla (repo privado sin credenciales configuradas, URL mal escrita, etc.), mostrar el error tal cual lo da git y detenerse — no reintentar con otro protocolo ni asumir credenciales.
   - Usar esa carpeta temporal como si fuera la carpeta local del PASO 1 en adelante.
   - Al final del reporte (PASO 4), aclarar que esa carpeta es temporal y descartable — **no** es un baseline ni debe tratarse como tal en corridas futuras.

---

## PASO 1 — Verificar entorno

1. Confirmar que la carpeta a revisar (local u obtenida en PASO 0) existe.
2. Listar todos los `.html` dentro de esa carpeta, recursivamente (el repo del cliente puede tener subcarpetas).

---

## PASO 2 — Identificar qué tableros de este proyecto ya están migrados

Para cada archivo en `frontend/*.html`, buscar señales de integración ya migrada (mismo criterio que el PASO 0.5 de `/migracion-analizar`): `PA.esModoApi`, `apiGet(`, `apiPost(`, `<script src="js/api.js">`, `var CTX`.

Armar la lista de "tableros migrados" (nombre de archivo → sí/no tiene integración).

---

## PASO 3 — Cruzar los archivos del cliente contra esa lista

Para cada `.html` encontrado en el repo del cliente (comparar por nombre de archivo, sin importar en qué subcarpeta esté, case-insensitive):

- **El nombre matchea un tablero migrado:**
  1. Buscar todas las carpetas `client-src/*/<mismo-nombre>.html`. Tomar la de fecha más reciente como `BASELINE`.
  2. Si no hay ninguna → estado = `Sin baseline en client-src` (no se puede diffear de forma confiable; hay que resolverlo a mano, ver PASO 4).
  3. Si hay `BASELINE` → correr un diff de texto real (`diff -u`, no "a ojo") entre `BASELINE` y el archivo del repo del cliente.
     - Diff vacío (0 líneas de diferencia) → estado = `Sin cambios`.
     - Diff no vacío → estado = `Cambios detectados`. Resumir en una línea: cuántas líneas +/-, y de qué tipo parecen (CSS/estilos, HTML/estructura, función JS nueva o modificada, clave de localStorage nueva, u otra cosa) — sin entrar en el detalle línea por línea, eso lo hace `/migracion-analizar` después.

- **El nombre NO matchea ningún tablero migrado:** estado = `No migrado todavía` (informativo — puede ser un tablero nuevo que nunca se migró, o un archivo que no es un tablero. No es el foco de este skill, pero vale reportarlo).

---

## PASO 4 — Reporte

Presentar una tabla y un resumen, sin tocar nada más:

---
### Auditoría de cambios: repo del cliente vs. tableros migrados

| Tablero | Estado | Detalle |
|---|---|---|
| tablero_uso_suelo.html | Cambios detectados | +40/-12 líneas — nueva función `xxx`, aparenta nueva clave de localStorage `yyy` |
| tablero_labores.html | Sin cambios | — |
| tablero_agro.html | No migrado todavía | — |
| tablero_x.html | Sin baseline en client-src | Resolver a mano antes de continuar (ver nota abajo) |

**Resumen:** N tableros con cambios · M sin cambios · K no migrados todavía · J sin baseline para comparar.

**Próximo paso sugerido:** para cada uno marcado "Cambios detectados", correr:
```
/migracion-analizar NombreTablero ruta/al/repo-del-cliente/NombreTablero.html
```
Eso va a detectar solo el modo `actualizacion` (ya tiene el `BASELINE_ANTERIOR` correcto) y generar el diagnóstico completo del delta.

**Nota sobre "Sin baseline en client-src":** significa que este tablero se migró antes de que existiera este flujo, o que se perdió la copia. Antes de tratarlo como actualización normal, confirmar con el usuario cómo proceder (por ejemplo, usar el `frontend/NombreTablero.html` migrado actual como aproximación de baseline).

**(Si el repo vino de una URL) Carpeta temporal usada:** `/ruta/scratchpad/repo-cliente-<timestamp>`. Es descartable — se puede borrar apenas termine este triage. **No es un baseline**: la próxima vez que se corra este skill (o `/migracion-analizar`) sobre este mismo tablero, el punto de comparación sigue siendo `client-src/`, nunca esta carpeta ni ninguna otra clonada en una corrida anterior.

---

**No se modifica nada en este paso.** Este reporte es insumo para decidir en qué tableros correr `/migracion-analizar` a continuación.
