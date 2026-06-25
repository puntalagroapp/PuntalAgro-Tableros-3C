# Contexto del proyecto — PuntalAgro Tableros 3C

Proyecto "Puntal Agro Tableros" migrado de localStorage standalone a arquitectura 3 capas:
Frontend HTML/JS (ES5) → Backend Node.js/Express → PostgreSQL.

**Por qué:** Migración progresiva. No rediseñar UI. Todo vía API REST. Sin localStorage como persistencia.

**Cómo aplicar:** Preservar diseño visual. ES5 (var/function, XHR callbacks, sin arrow functions, sin fetch/async/await). Bearer token en header Authorization.

## Estructura del repo

```
PuntalAgro-Tableros-3C/
├── frontend/          ← HTML migrados a API
│   ├── js/api.js      ← helper ES5: apiGet/apiPost/apiPut/apiDelete (XHR + Bearer)
│   ├── login.html     ✅ migrado
│   ├── index.html     ✅ migrado
│   ├── administracion.html  ✅ migrado
│   ├── usuarios.html        ✅ migrado
│   └── maestros.html        ✅ migrado
├── backend/
│   ├── server.js      ← API Express completa
│   └── Dockerfile     ✅ creado
└── database/init.sql  ← schema PostgreSQL con seeds
```

## Estado actual (rama main, último commit: 20e2b0e)

### Páginas migradas — patrón aplicado en todas:
- `<script src="js/api.js">` en lugar de `pa-core.js`
- Arrays en memoria solo para renderizar pantalla actual (no persistencia)
- Cada CRUD llama a la API y recarga desde servidor antes de re-renderizar
- IIFE de init: verifica localStorage `pa_sesion_activa`, llama `/api/context`, verifica rol, luego carga datos

### Validaciones implementadas

**Backend (server.js):**
- Helper `uniqueViolation(err)` que mapea error 23505 de PostgreSQL a mensajes en español
- Todos los POST/PUT de clientes, empresas, campos, usuarios, maestros devuelven HTTP 409 con mensaje claro
- Validación manual de duplicados en insumos (pre-existente, complementada por índice único)

**Base de datos (init.sql) — índices únicos agregados:**
- `uq_clientes_nombre` — nombre único (case-insensitive)
- `uq_empresas_rs_cliente` — razón social única por cliente
- `uq_campos_nombre_empresa` — nombre único por empresa
- `uq_labores_nombre` — nombre único (global)
- `uq_especies_nombre` — nombre único (global)
- `uq_modos_accion_sistema_codigo` — código único por sistema HRAC/IRAC/FRAC
- `uq_terceros_nombre_empresa` — nombre único por empresa (JSONB)
- `uq_choferes_nombre_empresa` — nombre único por empresa (JSONB)
- `uq_depositos_nombre_empresa` — nombre único por empresa (JSONB)
- `uq_tipos_actividad_nombre_empresa` — nombre único por empresa (JSONB)
- `ux_insumos_empresa_nombre_tipo` — pre-existente

### Comportamiento usuarios.html
- Dropdown de empresas filtra por el cliente del usuario seleccionado
- Pre-selecciona la primera empresa donde ya tiene permiso

## Pendientes identificados (NO implementados aún)

### Frontend — validaciones faltantes (informado al cliente para que las implemente)

**Patrón anti-pestañeo (body invisible hasta confirmar permisos):**
- En CSS: `body { visibility: hidden }`
- Revelar con `document.body.style.visibility = ''` después de verificar rol en `/api/context`
- Páginas afectadas: index.html, administracion.html, usuarios.html, maestros.html
- En index.html: revelar al final de `aplicarCtx()`
- En administracion.html: revelar después del check de rol, antes de `recargarTodo()`
- En usuarios.html: revelar después del check de rol, antes de mostrar `alcance`
- En maestros.html: revelar dentro del callback de `/api/campos`, antes de `seleccionarCat('terceros')`

**Validaciones de formulario pendientes:**
- Email: validar formato con regex antes de enviar (administracion.html, usuarios.html)
- CUIT: validar formato argentino (XX-XXXXXXXX-X) si se completa
- Hectáreas: validar > 0 si se completa
- DNI (choferes): validar numérico 7-8 dígitos si se completa
- Precio de referencia (labores): validar >= 0
- NPK fertilizantes: validar 0-100
- Email duplicado en usuarios: chequear en `_usuarios` en memoria antes de llamar API

**maxlength:** La DB usa TEXT sin límites → los valores son decisión del cliente.
Sugeridos: nombres 100, email 254, teléfono 20, CUIT 13, dirección 200, siglas 10, DNI 8, códigos 20, descripciones 200.

### Páginas aún NO migradas (en orden):
1. tablero_insumos_ot.html
2. tablero_uso_suelo.html
3. ProgramaSiembra.html
4. Fitosanitarios.html
5. tablero_agro.html, tablero_evolucion.html, tablero_hacienda.html, tablero_labores.html

## Patrones clave del código

**api.js — callback siempre `function(err, data)`:**
- `err` = `{status, error}` o null
- `data` = objeto JSON de la respuesta

**IDs generados en frontend:**
```javascript
function uid(){ return 'x_' + Date.now().toString(36) + Math.random().toString(36).substr(2,5); }
```

**Colecciones por empresa** (requieren `empresaId` en body/query):
terceros, choferes, depositos, insumos, tipos_actividad (cultivos/usos)

**Colecciones globales** (no requieren empresaId):
labores, especies, unidades, modos_accion, tipos_proveedor

**Contexto de sesión:**
- Token: `JSON.parse(localStorage.getItem('pa_sesion_activa')).token`
- Bearer header enviado automáticamente por api.js
- `/api/context?empresaId=` devuelve `{usuario, empresaActivaId, empresasDisponibles, permiso}`
- `permiso.herramientas = []` significa acceso total (no restringido)

**Roles:**
- `admin_general` — acceso total, gestiona clientes y empresas
- `admin_cliente` — gestiona su propio cliente y sus empresas
- `usuario` — solo accede a herramientas según permisos asignados

## Infraestructura

- docker-compose: PostgreSQL 16 + Node.js backend en puerto 8080
- `init.sql` se ejecuta automáticamente en volumen nuevo
- `.env.example` documenta las variables requeridas
- **Para producción:** los índices únicos nuevos deben aplicarse con `CREATE UNIQUE INDEX IF NOT EXISTS` o migración manual si la DB ya existe
