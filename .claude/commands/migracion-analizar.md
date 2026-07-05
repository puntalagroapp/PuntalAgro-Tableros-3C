---
description: "Fase 1 de migración: preserva el HTML original, crea la rama y genera el diagnóstico completo. Uso: /migracion-analizar NombreTablero [ruta/al/archivo.html]"
---

Actuá como un ingeniero de software senior especializado en migración de aplicaciones web standalone a arquitectura 3 capas.

## Contexto del proyecto

- Stack: Frontend HTML/JS ES5 → API Node.js/Express (server.js) → PostgreSQL 16
- El frontend usa `pa-core.js` y `js/api.js` como capa de acceso
- Los datos se persisten vía API, no via localStorage
- localStorage solo se usa para: token de sesión (`pa_sesion_activa`) y preferencias visuales no críticas
- Toda la lógica de negocio y permisos está en el backend

**Tablero a analizar:** $ARGUMENTS

Si $ARGUMENTS no incluye ruta al archivo, buscá en `frontend/` el HTML que coincida con el nombre indicado o que sea claramente nuevo (no listado aún en los endpoints de server.js).

---

## PASO 0 — Verificar entorno

1. Confirmar que existen `backend/server.js`, `frontend/`, `database/init.sql`.
2. Localizar el archivo HTML standalone a migrar. Si no lo encontrás, informar y detenerse.

---

## PASO 0.5 — Detectar si es primera migración o actualización

El cliente va a mandar mejoras sobre tableros que ya migramos antes — esto va a pasar seguido, no es un caso raro. Antes de preservar nada, determinar en qué escenario estamos:

1. Verificar si `frontend/NombreTablero.html` ya existe.
   - **No existe** → MODO = `primera_migracion`. Continuar directo con PASO 1, sin más chequeos.
   - **Existe** → buscar señales de integración ya migrada dentro de ese archivo: `PA.esModoApi`, `apiGet(`, `apiPost(`, `<script src="js/api.js">`, `var CTX`.
     - **Ninguna señal** → el archivo está en `frontend/` pero nunca se migró (caso raro). Tratar como `primera_migracion`, pero avisarlo explícitamente en el diagnóstico como algo a confirmar con el usuario antes de seguir.
     - **Hay señales** → MODO = `actualizacion`.

2. Si MODO = `actualizacion`:
   - Buscar todas las carpetas `client-src/*/NombreTablero.html` ya existentes (puede haber más de una si ya hubo actualizaciones previas). Tomar la de fecha más reciente **anterior a hoy** como `BASELINE_ANTERIOR` — el standalone del cliente tal como estaba la última vez que se migró.
   - Si no se encuentra ninguna → no hay con qué diffear. Detenerse e informar la situación (puede ser que este tablero se haya migrado antes de que existiera este skill, o que se haya perdido el client-src) y pedir confirmación de cómo seguir en vez de asumir un camino — por ejemplo, si usar el `frontend/NombreTablero.html` migrado actual como aproximación de baseline (con las limitaciones que eso implica, porque ya tiene mezclada la integración).
   - Correr un diff de texto real entre `BASELINE_ANTERIOR` y el HTML nuevo recibido ($ARGUMENTS) — no una comparación superficial ni "a ojo". Esto da la lista exacta de qué cambió el cliente en su diseño original: HTML agregado/quitado, funciones JS nuevas o modificadas, CSS, claves o campos nuevos.
   - Este diff reemplaza al análisis completo desde cero en los pasos siguientes (ver nota en PASO 5).

Informar el MODO detectado (y, si aplica, qué `BASELINE_ANTERIOR` se usó) antes de seguir con el resto de los pasos.

---

## PASO 1 — Preservar el original

1. Obtener la fecha actual (YYYY-MM-DD).
2. Crear `client-src/YYYY-MM-DD/` con la fecha real.
3. Copiar el HTML standalone (y cualquier asset que lo acompañe) a esa carpeta **sin modificar nada**.
4. Verificar que la copia es idéntica al original.

Esta carpeta es evidencia de entrada y nunca debe modificarse. En MODO `actualizacion`, esta nueva carpeta queda disponible como `BASELINE_ANTERIOR` la próxima vez que el cliente mande otra mejora sobre este mismo tablero.

---

## PASO 2 — Partir desde producción

```bash
git checkout main
git pull origin main
```

Confirmar que el pull fue exitoso antes de seguir.

---

## PASO 3 — Crear la rama de migración

```bash
git checkout -b feature/migracion-NOMBRE-YYYY-MM-DD
```

Donde NOMBRE es el nombre del tablero en kebab-case y YYYY-MM-DD es la fecha real.
Informar la rama creada.

---

## PASO 4 — Analizar la versión productiva existente

Antes de tocar cualquier código, leer y documentar:

**4a. `frontend/pa-core.js`**
- ¿Qué expone el objeto `PA`? (funciones públicas, `PA.demo.*`, `PA.esModoApi()`, `PA.loadContext()`, etc.)
- ¿Qué datos demo hay precargados?

**4b. `frontend/js/api.js`**
- ¿Qué funciones expone? (`apiGet`, `apiPost`, `apiPut`, `apiDelete`, firmas, etc.)

**4c. `backend/server.js`** — listar TODOS los endpoints:
- Método + ruta + descripción breve
- Qué validaciones hace cada uno (auth, empresaId, etc.)

**4d. `database/init.sql` y `database/migrations/`**
- Listar todas las tablas con columnas clave y FK
- Anotar secuencias, índices únicos relevantes

**4e. HTMLs ya migrados** (ej: `tablero_uso_suelo.html`)
- ¿Qué patrón usa para el boot asincrónico?
- ¿Cómo maneja `PA.esModoApi()` para bifurcar demo/API?
- ¿Cómo llama a `cargarDesdeApi()` y `guardarApi()`?
- ¿Cómo maneja el cambio de empresa?

El objetivo es **no duplicar nada**. Si algo ya existe, se reutiliza.

---

## PASO 5 — Analizar el HTML standalone a migrar

**Si MODO = `actualizacion`:** no hace falta repetir este análisis completo — ya se hizo la vez pasada y esas decisiones siguen valiendo para todo lo que no cambió. Concentrarse exclusivamente en el diff calculado en el PASO 0.5: para cada cambio (HTML/función/clave nueva o modificada), completar las secciones 5a-5h **solo para eso**, comparando contra cómo está resuelto hoy en `frontend/NombreTablero.html`. Todo lo que el diff no toca ya tiene su estrategia decidida — no se re-analiza ni se re-propone.

**Si MODO = `primera_migracion`:** leer el HTML standalone completo y documentar:

**5a. Claves de localStorage** — tabla exhaustiva:

| Clave | Estructura del valor | Dónde se lee | Dónde se escribe | Dónde se borra | Dimensión (global/empresa/campaña/campo) |
|---|---|---|---|---|---|

**5b. Estructuras de datos**
Para cada clave de localStorage, documentar la estructura JSON real:
- Tipo: array, objeto, string, número
- Campos internos y sus tipos
- Si tiene id, cómo se genera (Math.random, uid(), secuencial, etc.)

**5c. Maestros (catálogos)**
¿Hay listas de tipos, categorías, o configuraciones que el usuario mantiene?

**5d. Datos operativos**
¿Qué registros crea/edita/borra el usuario?

**5e. Datos calculados**
¿Hay totales, promedios, sumas derivadas de otros datos? → Marcar como estrategia D (recalcular, no persistir).

**5f. Estado visual temporal**
¿Hay estado que solo existe mientras la página está abierta? (tab activo, filtro seleccionado, modal abierto, etc.) → Marcar como estrategia E (memoria JS, no API).

**5g. Formularios y operaciones CRUD**
¿Qué formularios existen? ¿Qué funciones crean/editan/borran?

**5h. Dependencias con otros tableros**
¿Lee datos que otro tablero genera (ej: insumos, lotes, campañas)?
¿Escribe datos que otro tablero lee?

---

## PASO 6 — Estrategia de migración por dato

**Si MODO = `actualizacion`:** esto aplica solo a las claves/entidades nuevas o modificadas que salieron del diff del PASO 0.5. Las que ya existían y no cambiaron mantienen la estrategia y el endpoint/tabla que ya se usan en `frontend/NombreTablero.html` — no se vuelven a decidir.

Para CADA clave de localStorage y CADA entidad detectada (nueva o, en `primera_migracion`, todas), asignar:

- **A — Reutilizar**: Ya existe endpoint/tabla equivalente → indicar cuál.
- **B — Extender**: Existe parcialmente → indicar qué agregar y dónde.
- **C — Crear**: No existe → proponer diseño de tabla y endpoint.
- **D — Derivado**: Es cálculo → recalcular en frontend, no llamar a API.
- **E — Temporal**: Estado visual → mantener en variable JS.

Para las estrategias **C**, proponer:
- Nombre de tabla (coherente con las existentes: snake_case, plural)
- Columnas con tipos y constraints
- Si encaja en `/api/maestros/:coleccion` o necesita endpoint dedicado
- FK necesarias
- Índices únicos que apliquen

Para las estrategias **A y B**, identificar exactamente:
- El endpoint a usar o extender
- La tabla a usar o modificar

---

## SALIDA ESPERADA

Presentar el diagnóstico en este formato. La sección **Cambios detectados** solo aparece en MODO `actualizacion`; las demás aplican a ambos modos, pero en `actualizacion` quedan acotadas a lo nuevo/modificado.

---
### Diagnóstico de migración: [Nombre Tablero]

**Modo:** `primera_migracion` | `actualizacion`
**Archivo analizado:** `frontend/NombreTablero.html`
**Rama creada:** `feature/migracion-nombre-YYYY-MM-DD`
**Original preservado en:** `client-src/YYYY-MM-DD/`
**(Si actualización) Baseline anterior usado para el diff:** `client-src/YYYY-MM-DD-anterior/NombreTablero.html`

#### (Solo en actualización) Cambios detectados respecto a la versión anterior
[resumen del diff: qué agregó/cambió/quitó el cliente en su HTML standalone — UI, funciones, claves de localStorage, CSS]

#### Claves localStorage detectadas
[tabla: clave | estructura | estrategia | motivo — en actualización, solo las nuevas/modificadas]

#### Entidades reutilizables (estrategias A/B)
[lista — en actualización, incluye explícitamente lo que YA estaba resuelto de la migración anterior y sigue igual]

#### Entidades a crear o modificar (estrategia C)
[propuesta de DDL y endpoint para cada una — solo lo nuevo]

#### Patrón de boot recomendado
[pseudocódigo del flujo de inicialización asincrónico — en actualización, solo si el diff lo afecta; si no, "sin cambios respecto al boot() actual"]

#### Riesgos y decisiones pendientes
[lista de dudas que requieren confirmación antes de implementar]

---

**NO implementar nada todavía.** Este diagnóstico debe revisarse antes de ejecutar `/migracion-implementar $ARGUMENTS`.
