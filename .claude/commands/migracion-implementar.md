---
description: "Fase 2 de migración: implementa los cambios en frontend, backend y BD, commitea y genera el reporte final. Ejecutar después de revisar /migracion-analizar. Uso: /migracion-implementar NombreTablero"
---

Actuá como un ingeniero de software senior especializado en migración de aplicaciones web standalone a arquitectura 3 capas.

## Contexto del proyecto

- Stack: Frontend HTML/JS ES5 → API Node.js/Express (server.js) → PostgreSQL 16
- ES5 obligatorio en frontend: var, function, callbacks XHR — sin let/const/arrow functions/fetch/Promise
- El frontend usa `pa-core.js` y `js/api.js` como capa de acceso
- Los datos se persisten vía API; localStorage solo para token de sesión y preferencias visuales
- Toda la lógica de negocio y permisos está en el backend, nunca en el frontend

**Tablero a implementar:** $ARGUMENTS

---

## PASO 0 — Verificar contexto

1. Confirmar que estamos en la rama `feature/migracion-*` correcta (NO en main). Si estamos en main, detenerse.
2. Leer el diagnóstico generado por `/migracion-analizar` (o pedirlo si no está a mano) y confirmar el **Modo**: `primera_migracion` o `actualizacion`.
3. Leer el HTML original en `client-src/` como referencia inmutable. **Si Modo = actualización**, leer también el `BASELINE_ANTERIOR` que indicó el diagnóstico, para tener el diff claro entre lo viejo y lo nuevo del cliente.
4. Leer el HTML de trabajo en `frontend/` — en modo actualización, este archivo YA tiene la integración (boot/CTX/apiGet); es la base sobre la que se parchea, no se reemplaza.
5. Leer `frontend/js/api.js` (funciones disponibles: apiGet, apiPost, apiPut, apiDelete).
6. Leer `frontend/pa-core.js` (funciones PA, PA.esModoApi, PA.loadContext, PA.demo.*).
7. Leer `backend/server.js` (endpoints existentes, función obtenerSesion, patrones usados).
8. Leer `database/init.sql` y `database/migrations/` (esquema actual).

**Si Modo = actualización:** el objetivo de PASO 7 en adelante no es re-migrar el tablero, es **aplicar sobre `frontend/NombreTablero.html` (el ya migrado) únicamente los cambios que el diagnóstico marcó como nuevos/modificados** respecto al `BASELINE_ANTERIOR`. Todo lo que ya estaba integrado (boot, CTX, llamadas a la API existentes) se mantiene intacto salvo que el propio diff lo afecte directamente.

---

## PASO 7 — Modificar el HTML del tablero

### Reglas absolutas — NO violar ninguna:
- **No cambiar diseño visual**: ni HTML estructural, ni CSS, ni layout, ni colores, ni textos visibles al usuario
- **No reescribir el tablero** desde cero
- **No usar frameworks** (React, Vue, Angular, etc.)
- **Mantener ES5**: var, function, XMLHttpRequest, callbacks — sin let/const/arrow functions/fetch/class
- **No duplicar** lógica que ya existe en pa-core.js o api.js
- **En Modo actualización: parchear, no reemplazar.** El archivo del cliente ($ARGUMENTS) es su diseño standalone, sin integración — nunca copiarlo tal cual sobre `frontend/NombreTablero.html`. Tomar como base el `frontend/NombreTablero.html` ya migrado y aplicarle ahí, a mano, cada cambio que el diagnóstico marcó como nuevo/modificado (una función nueva, un campo agregado a un formulario, un ajuste de CSS, etc.), conservando todo el boot/CTX/apiGet/apiPost existente que el diff no toca.

### Agregar imports necesarios (si no están)

Al inicio del `<body>` o en el `<head>`, antes del script del tablero:
```html
<script src="pa-core.js"></script>
<script src="js/api.js"></script>
```

### Variable de contexto global

Al inicio del script del tablero, declarar:
```javascript
var CTX = null; // se puebla en boot()
```

### Patrón de boot asincrónico

Reemplazar cualquier inicialización sincrónica por:
```javascript
function boot() {
  var sesion = null;
  try { sesion = JSON.parse(localStorage.getItem('pa_sesion_activa') || 'null'); } catch(e) {}
  if (!sesion || !sesion.token) { location.href = 'login.html'; return; }

  PA.loadContext(function(ctx) {
    if (!ctx) { localStorage.removeItem('pa_sesion_activa'); location.href = 'login.html'; return; }
    CTX = ctx;
    cargarDatos(function() {
      renderizarTodo();
    });
  });
}
document.addEventListener('DOMContentLoaded', boot);
// Eliminar cualquier window.onload que hiciera lo mismo
```

### Patrón de carga desde API (reemplaza localStorage.getItem)

```javascript
function cargarDatos(callback) {
  if (!_esModoApi()) {
    // Modo demo: usar datos de pa-core.js
    DATOS = PA.demo.listarXxx(CTX.empresaActivaId);
    if (callback) callback();
    return;
  }
  apiGet('/api/mi-endpoint?empresaId=' + encodeURIComponent(CTX.empresaActivaId), function(err, resp) {
    if (err) { console.error('Error cargando datos:', err); if (callback) callback(); return; }
    DATOS = resp || [];
    if (callback) callback();
  });
}

function _esModoApi() {
  return typeof PA !== 'undefined' && PA.esModoApi && PA.esModoApi();
}
```

### Patrón de guardado (reemplaza localStorage.setItem)

```javascript
function guardarDatos(payload, callback) {
  if (!_esModoApi()) {
    // Modo demo: operación local en memoria
    if (callback) callback(null);
    return;
  }
  apiPost('/api/mi-endpoint', { empresaId: CTX.empresaActivaId, datos: payload }, function(err, resp) {
    if (err) { mostrarError(err); return; }
    if (callback) callback(resp);
  });
}
```

### Patrón de actualización (PUT)

```javascript
apiPut('/api/mi-endpoint/' + encodeURIComponent(id) + '?empresaId=' + encodeURIComponent(CTX.empresaActivaId),
  { empresaId: CTX.empresaActivaId, datos: payload },
  function(err) {
    if (err) { mostrarError(err); return; }
    recargarYRenderizar();
  }
);
```

### Patrón de eliminación (DELETE)

```javascript
apiDelete('/api/mi-endpoint/' + encodeURIComponent(id) + '?empresaId=' + encodeURIComponent(CTX.empresaActivaId),
  function(err) {
    if (err) { mostrarError(err); return; }
    recargarYRenderizar();
  }
);
```

### Patrón de cambio de empresa

Si el tablero reacciona al selector de empresa de la barra de navegación:
```javascript
function onCambioEmpresa() {
  PA.loadContext(function(ctx) {
    CTX = ctx;
    cargarDatos(function() { renderizarTodo(); });
  });
}
// Exponer si la barra lo necesita:
window.PA_onCambioEmpresa = onCambioEmpresa;
```

### Estado visual temporal — mantener en JS

Cualquier estado que no sea datos de negocio (filtro activo, tab seleccionado, fila expandida) debe seguir siendo una variable JavaScript local. **No llamar a la API para esto.**

### No asumir éxito antes de la respuesta

```javascript
// MAL: guardar en array local antes de recibir respuesta del backend
DATOS.push(nuevo);
renderizar();
apiPost(...);

// BIEN: esperar confirmación del backend
apiPost('/api/endpoint', payload, function(err, resp) {
  if (err) { mostrarError(err); return; }
  DATOS.push(resp); // usar lo que devuelve el backend
  renderizar();
});
```

### Si la API devuelve error, mostrar al usuario

Reutilizar cualquier mecanismo de error que ya tenga el tablero (toast, banner, alert), o agregar uno mínimo:
```javascript
function mostrarError(err) {
  var msg = (err && err.error) ? err.error : 'Error al comunicarse con el servidor';
  alert(msg); // reemplazar con el mecanismo visual del tablero si existe
}
```

---

## PASO 8 — Reutilizar pa-core.js y api.js

- Si `PA.demo.listarXxx()` ya existe para estos datos → usarlo en modo demo.
- Si se necesita agregar datos demo a `pa-core.js` → agregar siguiendo el patrón existente del archivo.
- No inventar funciones propias para llamar al backend si `apiGet/apiPost/apiPut/apiDelete` ya cubren el caso.
- Si se necesita una función pública nueva en `PA` → agregar al objeto `PA` en `pa-core.js` usando el mismo estilo.

---

## PASO 9 — Backend: agregar o modificar endpoints en server.js

Solo si el análisis indicó estrategia B o C para algún dato.

**Plantilla de endpoint GET (listar):**
```javascript
app.get('/api/mi-recurso', async function(req, res) {
  try {
    var sesion = await obtenerSesion(req);
    if (!sesion) return res.status(401).json({ error: 'No autenticado' });
    var empresaId = req.query.empresaId;
    if (!empresaId) return res.status(400).json({ error: 'empresaId requerido' });
    var r = await pool.query(
      'SELECT id, datos FROM mi_tabla WHERE empresa_id = $1 ORDER BY ...',
      [empresaId]
    );
    res.json(r.rows.map(function(row) {
      return Object.assign({ id: row.id, empresaId: empresaId }, row.datos);
    }));
  } catch (err) {
    console.error('/api/mi-recurso GET error:', err);
    res.status(500).json({ error: 'Error interno del servidor' });
  }
});
```

**Plantilla de endpoint POST (crear):**
```javascript
app.post('/api/mi-recurso', async function(req, res) {
  try {
    var sesion = await obtenerSesion(req);
    if (!sesion) return res.status(401).json({ error: 'No autenticado' });
    var empresaId = (req.body || {}).empresaId;
    if (!empresaId) return res.status(400).json({ error: 'empresaId requerido' });
    // validar campos obligatorios del body
    var datos = req.body.datos || {};
    if (!datos.nombre) return res.status(400).json({ error: 'nombre requerido' });
    var id = req.body.id || ('rec_' + Date.now());
    // verificar duplicados si aplica
    var existe = await pool.query(
      'SELECT 1 FROM mi_tabla WHERE id = $1 AND empresa_id = $2',
      [id, empresaId]
    );
    if (existe.rows.length) return res.status(409).json({ error: 'Ya existe un registro con ese id' });
    await pool.query(
      'INSERT INTO mi_tabla (id, empresa_id, datos) VALUES ($1, $2, $3)',
      [id, empresaId, JSON.stringify(datos)]
    );
    res.status(201).json({ id: id, empresaId: empresaId, ...datos });
  } catch (err) {
    console.error('/api/mi-recurso POST error:', err);
    res.status(500).json({ error: 'Error interno del servidor' });
  }
});
```

**Reglas para todos los endpoints:**
- Autenticación con `obtenerSesion(req)` — siempre primero
- `empresaId` siempre requerido para datos de empresa
- Queries parametrizadas ($1, $2...) — nunca concatenar datos del usuario en SQL
- Errores: `res.status(NNN).json({ error: 'mensaje' })` — nunca exponer `err.message` de Postgres
- Ubicar junto a los demás endpoints del mismo dominio en server.js
- Si el recurso encaja en `/api/maestros/:coleccion`, considerar si puede usar ese endpoint genérico antes de crear uno dedicado

---

## PASO 10 — Base de datos: tablas y migraciones

Solo si el análisis indicó estrategia C.

**Convenciones obligatorias:**
- Nombres en snake_case, plural
- IDs: TEXT (generados en frontend con `uid()` o equivalente)
- Entidades por empresa: PK compuesta `(id, empresa_id)`
- JSONB solo si la estructura es genuinamente variable; columnas separadas si la estructura es fija
- FK apropiadas con ON DELETE coherente con el dominio (CASCADE para dependencias directas, RESTRICT si hay riesgo de borrado accidental, SET NULL si la referencia es opcional)
- `empresa_id TEXT NOT NULL REFERENCES empresas(id) ON DELETE CASCADE`
- Índice de performance: `CREATE INDEX idx_<tabla>_empresa ON <tabla>(empresa_id);`
- UNIQUE si aplica: `CREATE UNIQUE INDEX uq_<tabla>_nombre_empresa ON <tabla>(empresa_id, lower(datos->>'nombre'));`

**Agregar en `database/init.sql`** (en la sección correcta según la naturaleza de la tabla).

**Crear `database/migrations/NNN_nombre.sql`** para bases existentes:
```sql
-- Migración NNN: descripción
CREATE TABLE mi_tabla (
    id           TEXT NOT NULL,
    empresa_id   TEXT NOT NULL REFERENCES empresas(id) ON DELETE CASCADE,
    datos        JSONB NOT NULL DEFAULT '{}',
    PRIMARY KEY (id, empresa_id)
);
CREATE INDEX idx_mi_tabla_empresa ON mi_tabla(empresa_id);
CREATE UNIQUE INDEX uq_mi_tabla_nombre ON mi_tabla(empresa_id, lower(datos->>'nombre'));
```

**Aplicar la migración contra la base en ejecución:**
```bash
docker exec -i pa_postgres_db psql -U postgres -d puntalagro_tableros_3C \
  < database/migrations/NNN_nombre.sql
```

---

## PASO 11 — Docker: determinar qué reiniciar

Evaluar según los cambios realizados:

| Qué cambió | Comando necesario |
|---|---|
| Solo HTML/CSS/JS en `frontend/` | Ninguno (volumen montado, cambios inmediatos) |
| `backend/server.js` (sin deps nuevas) | `docker compose restart api_server` |
| `backend/server.js` + nueva dep npm | `docker compose up --build -d api_server` |
| Solo migración SQL (sin schema rebuild) | Solo aplicar el .sql (ya hecho en paso 10) |

---

## PASO 12 — Git: commit y push

```bash
git status
git add frontend/NombreTablero.html
# agregar backend/server.js si cambió
# agregar database/ si cambió
# agregar pa-core.js si cambió
git commit -m "Migra NombreTablero a arquitectura 3 capas"
git push origin feature/migracion-nombre-YYYY-MM-DD
```

**No hacer merge a main.** Queda en rama para revisión en Pull Request.

---

## SALIDA FINAL — Reporte completo

Generar el reporte con estos 14 puntos:

1. **Diagnóstico del HTML recibido** — resumen de qué hacía el tablero
2. **Claves localStorage detectadas** — tabla: clave | estructura | estrategia aplicada
3. **Mapeo localStorage → API/BD** — tabla: clave original | endpoint nuevo | método
4. **Entidades reutilizadas** — tablas y endpoints existentes que se usaron sin cambios
5. **Entidades nuevas** — tablas y funciones pa-core.js creadas
6. **Endpoints reutilizados** — lista con método + ruta
7. **Endpoints nuevos** — lista con método + ruta + descripción
8. **Tablas reutilizadas** — lista
9. **Tablas nuevas o modificadas** — con DDL resumido
10. **Archivos modificados** — lista completa
11. **Rama Git creada** — nombre exacto
12. **Comandos Docker recomendados** — con contexto de por qué
13. **Pruebas manuales para validar** — checklist del golden path + edge cases
14. **Riesgos o decisiones pendientes** — lo que quedó sin resolver o que requiere validación del cliente
