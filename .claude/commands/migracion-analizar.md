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

## PASO 1 — Preservar el original

1. Obtener la fecha actual (YYYY-MM-DD).
2. Crear `client-src/YYYY-MM-DD/` con la fecha real.
3. Copiar el HTML standalone (y cualquier asset que lo acompañe) a esa carpeta **sin modificar nada**.
4. Verificar que la copia es idéntica al original.

Esta carpeta es evidencia de entrada y nunca debe modificarse.

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

Leer el HTML standalone completo y documentar:

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

Para CADA clave de localStorage y CADA entidad detectada, asignar:

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

Presentar el diagnóstico en este formato:

---
### Diagnóstico de migración: [Nombre Tablero]

**Archivo analizado:** `frontend/NombreTablero.html`
**Rama creada:** `feature/migracion-nombre-YYYY-MM-DD`
**Original preservado en:** `client-src/YYYY-MM-DD/`

#### Claves localStorage detectadas
[tabla: clave | estructura | estrategia | motivo]

#### Entidades reutilizables (estrategias A/B)
[lista]

#### Entidades a crear o modificar (estrategia C)
[propuesta de DDL y endpoint para cada una]

#### Patrón de boot recomendado
[pseudocódigo del flujo de inicialización asincrónico]

#### Riesgos y decisiones pendientes
[lista de dudas que requieren confirmación antes de implementar]

---

**NO implementar nada todavía.** Este diagnóstico debe revisarse antes de ejecutar `/migracion-implementar $ARGUMENTS`.
