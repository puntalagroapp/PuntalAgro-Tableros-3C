Actuá como un ingeniero de software senior especializado en migración de aplicaciones web legacy/locales a arquitectura 3 capas.

Contexto del proyecto
=====================

Tenemos una aplicación llamada “Puntal Agro Tableros”.

La versión actual es una aplicación web standalone desarrollada en HTML + CSS + JavaScript puro. Los tableros funcionan localmente y persisten datos en localStorage.

El repositorio público de este proyecto es:

https://github.com/puntalagroapp/PuntalAgro-Tableros-3C

El repositorio publico del cliente es:

https://github.com/Puntal-Agro/Herramientas-Puntal-Agro

La aplicación contiene varios HTML/tableros, entre ellos:

- index.html
- login.html
- administracion.html
- usuarios.html
- maestros.html
- tablero_agro.html
- tablero_evolucion.html
- tablero_hacienda.html
- tablero_insumos_ot.html
- tablero_labores.html
- tablero_uso_suelo.html
- ProgramaSiembra.html
- Fitosanitarios.html
- pa-core.js

Objetivo general
================

Migrar la aplicación desde un modelo standalone con localStorage a un modelo web de 3 capas:

1. Frontend
   - HTML/CSS/JavaScript.
   - Debe conservar el diseño visual actual.
   - Debe respetar los estilos, layout, navegación, nombres de pantallas y experiencia del cliente.
   - Debe reemplazar accesos a localStorage por llamadas a la API.
   - Debe adaptarse al comportamiento asincrónico de la API.
   - Debe mostrar correctamente estados de carga, errores y datos persistidos.

2. Backend API
   - Node.js + Express.
   - Debe exponer endpoints REST claros.
   - Debe contener reglas de negocio.
   - Debe validar permisos, usuario, empresa, campo y herramienta.
   - Debe validar duplicados y datos obligatorios.
   - Debe manejar operaciones transaccionales cuando corresponda.

3. Base de datos
   - PostgreSQL.
   - Debe reemplazar localStorage como fuente definitiva de datos.
   - Debe soportar multiusuario.
   - Debe soportar empresas/clientes/campos/lotes/permisos.
   - Debe permitir auditoría futura.

Condiciones importantes
=======================

NO usar caché como fuente funcional de persistencia.

NO implementar sincronización cache local ↔ backend.

NO asumir que localStorage seguirá siendo fuente de verdad.

NO diseñar un modelo donde el frontend escriba en cache y “luego sincronice”.

Toda lectura y escritura de datos persistentes debe ir vía API.

El frontend puede mantener variables en memoria únicamente para renderizar la pantalla actual, pero la persistencia definitiva siempre debe ser PostgreSQL vía API.

La aplicación standalone todavía está en evolución.
El cliente puede seguir agregando nuevos tableros HTML o modificando los existentes.
Por eso la migración debe ser progresiva y ordenada, pero la arquitectura objetivo debe ser 100% 3 capas.

Criterios de migración
======================

Para cada HTML/tablero:

1. Identificar todos los usos de:
   - localStorage.getItem
   - localStorage.setItem
   - localStorage.removeItem
   - JSON.parse(localStorage...)
   - JSON.stringify(...)
   - estructuras root persistidas completas
   - arrays internos usados como tablas maestras u operativas

2. Identificar qué datos son:
   - maestros globales
   - maestros por empresa
   - datos operativos
   - configuraciones
   - datos calculados
   - datos de sesión
   - permisos

3. Crear o ajustar endpoints REST para esos datos.

4. Crear o ajustar tablas PostgreSQL.

5. Reescribir el JavaScript del HTML para:
   - cargar datos con llamadas asincrónicas a la API
   - esperar respuestas antes de renderizar
   - mostrar estado “cargando”
   - mostrar errores
   - refrescar vistas luego de crear/editar/borrar
   - no depender de localStorage

6. Conservar el diseño visual del HTML.
   No rediseñar pantallas.
   No cambiar colores, estilos, nombres de botones ni disposición salvo que sea estrictamente necesario para manejar carga/errores.

7. Validar en backend:
   - usuario autenticado
   - empresa activa
   - permisos sobre herramienta
   - permisos sobre campo/lote cuando aplique
   - campos obligatorios
   - duplicados
   - integridad referencial

Regla clave sobre asincronía
============================

La versión standalone lee localStorage en forma sincrónica.

Ejemplo legacy:

const insumos = JSON.parse(localStorage.getItem('pa_insumos') || '[]');
renderInsumos(insumos);

En la versión 3 capas debe pasar a un flujo asincrónico:

async function cargarInsumos() {
  mostrarCargando();
  try {
    const insumos = await apiGet('/api/maestros/insumos?empresaId=' + empresaId);
    renderInsumos(insumos);
  } catch (error) {
    mostrarError(error);
  }
}

Si por compatibilidad del código existente se mantiene JavaScript ES5, usar callbacks o XMLHttpRequest.
Si se moderniza el JavaScript, usar fetch + async/await.
Pero en todos los casos el frontend debe adaptarse al delay real de la API.

Arquitectura esperada
=====================

Frontend:

frontend/
  index.html
  login.html
  administracion.html
  usuarios.html
  maestros.html
  tablero_*.html
  ProgramaSiembra.html
  Fitosanitarios.html
  js/
    api.js
    auth.js
    context.js
    maestros-api.js
    utils.js

Backend:

backend/
  src/
    app.js
    db/
      pool.js
    routes/
    controllers/
    services/
    repositories/
    middlewares/
  package.json

Database:

database/
  schema.sql
  seed.sql
  migrations/

Entidades base a contemplar
===========================

Administración y seguridad:

- usuarios
- sesiones
- clientes
- empresas
- campos
- lotes
- roles
- permisos
- herramientas
- usuarios_empresas
- permisos_herramientas
- permisos_campos

Maestros globales:

- unidades
- especies
- labores
- modos_accion
- tipos_proveedor
- campañas

Maestros por empresa:

- terceros
- proveedores
- clientes comerciales
- choferes
- depositos
- insumos
- tipos_actividad
- cultivos/usos
- lotes
- actividades

Operativos:

- stock
- movimientos_stock
- ordenes_trabajo
- ordenes_trabajo_lotes
- ordenes_trabajo_insumos
- consumos_lote
- programacion_siembra
- requerimientos_fitosanitarios
- recetas_fitosanitarias
- recetas_insumos
- planes_uso_suelo

Tableros de decisión / series:

- precios_granos
- precios_hacienda
- tipos_cambio
- variables_contexto
- series_valores
- tarifas_labores
- tarifas_fletes

Primera prioridad
=================

La primera prioridad es migrar correctamente:

1. login.html
2. index.html
3. administracion.html
4. usuarios.html
5. maestros.html

Luego avanzar por tableros operativos:

6. tablero_insumos_ot.html
7. tablero_uso_suelo.html
8. ProgramaSiembra.html
9. Fitosanitarios.html

Luego tableros de análisis:

10. tablero_agro.html
11. tablero_evolucion.html
12. tablero_hacienda.html
13. tablero_labores.html

Maestros.html
=============

El HTML maestros.html implementa ABMs para tablas maestras usadas por toda la app.

Debe migrarse completo a API/PostgreSQL.

Maestros detectados:

- terceros
- choferes
- depositos
- labores
- tipos_actividad / cultivos / usos
- especies
- unidades
- insumos
- modos_accion
- tipos_proveedor

Cada ABM debe:

- listar desde API
- crear vía API
- editar vía API
- borrar vía API
- refrescar la tabla luego de cada operación
- mostrar errores de backend
- impedir duplicados cuando corresponda

Caso específico: Insumos
========================

En la versión traducida anterior se detectaron bugs:

1. Insumos no borra.
2. Insumos permite duplicados.

Corregirlo correctamente.

Motivos esperados:

- El frontend llama a borrarInsumo(id) sin enviar empresaId.
- El backend DELETE /api/maestros/insumos/:id requiere empresaId para colecciones por empresa.
- El alta de insumo no valida duplicados.
- El backend tampoco debe permitir duplicados.

Implementar solución:

Frontend:
- Al borrar insumo, enviar id + empresaId.
- Esperar respuesta de API.
- Si la API falla, mostrar error y no asumir éxito.
- Luego de borrar, recargar lista desde API.

Backend:
- DELETE de insumos debe validar empresaId.
- Debe borrar el registro correcto por id + empresa_id.
- POST/PUT de insumos debe validar duplicados por empresa.
- Criterio sugerido de unicidad:
  empresa_id + lower(nombre) + tipo
- Si existe duplicado, devolver HTTP 409.

Ejemplo de error:

{
  "error": "Ya existe un insumo con ese nombre y tipo para esta empresa"
}

Endpoints esperados
===================

Autenticación:

POST /api/auth/login
POST /api/auth/logout
GET  /api/context?empresaId=

Administración:

GET    /api/clientes
POST   /api/clientes
PUT    /api/clientes/:id
DELETE /api/clientes/:id

GET    /api/empresas
POST   /api/empresas
PUT    /api/empresas/:id
DELETE /api/empresas/:id

GET    /api/campos?empresaId=
POST   /api/campos
PUT    /api/campos/:id
DELETE /api/campos/:id

Usuarios y permisos:

GET    /api/usuarios
POST   /api/usuarios
PUT    /api/usuarios/:id
DELETE /api/usuarios/:id

GET    /api/permisos
POST   /api/permisos
DELETE /api/permisos/:usuarioId/:empresaId

GET    /api/herramientas
POST   /api/herramientas
PUT    /api/herramientas/:id
DELETE /api/herramientas/:id

Maestros:

GET    /api/maestros/:coleccion
POST   /api/maestros/:coleccion
PUT    /api/maestros/:coleccion/:id
DELETE /api/maestros/:coleccion/:id

Colecciones mínimas:

- terceros
- choferes
- depositos
- insumos
- tipos-actividad
- labores
- especies
- unidades
- modos-accion
- tipos-proveedor
- lotes
- actividades
- campanias

Reglas para colecciones por empresa:

- terceros
- choferes
- depositos
- insumos
- tipos-actividad
- lotes
- actividades

Estas deben requerir empresaId y validar permisos.

Reglas para colecciones globales:

- labores
- especies
- unidades
- modos-accion
- tipos-proveedor
- campanias

Estas pueden no requerir empresaId, pero deben validar rol de usuario para escritura.

Criterios de API
================

Todas las respuestas deben ser JSON.

Errores:

400: datos incompletos
401: no autenticado
403: sin permiso
404: no encontrado
409: duplicado/conflicto
500: error servidor

Formato:

{
  "error": "mensaje claro"
}

No devolver errores HTML.

No ocultar errores.

El frontend debe mostrar errores.

Criterios de base de datos
==========================

Usar PostgreSQL.

Evitar guardar todo como blob JSON si la entidad ya está clara.

Se permite JSONB solo como transición para tableros complejos aún no estabilizados, pero los maestros y entidades comunes deben ser relacionales.

Para maestros actuales se prefiere:

- tablas relacionales
- claves primarias claras
- foreign keys donde corresponda
- índices únicos donde corresponda
- campos activo / created_at / updated_at

Ejemplo para insumos:

insumos
- id
- empresa_id
- nombre
- tipo
- unidad_id
- modo_accion_id
- banda_tox
- eiq
- concentracion
- conc_unidad
- nutrientes JSONB opcional o columnas n/p/k/s
- activo
- created_at
- updated_at

Índice único sugerido:

UNIQUE (empresa_id, lower(nombre), tipo)

Si PostgreSQL no permite directamente ese índice como constraint estándar, crear unique index:

CREATE UNIQUE INDEX ux_insumos_empresa_nombre_tipo
ON insumos (empresa_id, lower(nombre), tipo);

Criterios de frontend
=====================

No usar localStorage para datos de negocio.

Permitido en localStorage únicamente:

- token de sesión
- empresa activa si resulta necesario
- preferencias visuales no críticas

No guardar en localStorage:

- usuarios
- permisos
- empresas
- campos
- lotes
- insumos
- stock
- movimientos
- órdenes de trabajo
- maestros
- planes
- recetas
- programaciones
- tableros de negocio

El frontend debe tener funciones claras:

apiGet(path)
apiPost(path, data)
apiPut(path, data)
apiDelete(path)

Deben agregar Authorization Bearer token.

Ejemplo:

async function apiDelete(path) {
  const res = await fetch(API_BASE_URL + path, {
    method: 'DELETE',
    headers: authHeaders()
  });
  const data = await res.json().catch(() => null);
  if (!res.ok) {
    throw new Error(data && data.error ? data.error : 'Error de API');
  }
  return data;
}

El HTML no debe asumir que una operación fue exitosa antes de recibir respuesta.

Ejemplo correcto:

async function eliminarIns() {
  if (!editIns) return;
  if (!confirm('¿Eliminar este insumo?')) return;

  try {
    await apiDelete('/api/maestros/insumos/' + encodeURIComponent(editIns) + '?empresaId=' + encodeURIComponent(empresaId));
    cerrarModalIns();
    await cargarInsumos();
  } catch (error) {
    document.getElementById('msg-ins').textContent = error.message;
  }
}

Modo de trabajo solicitado
==========================

Trabajar archivo por archivo.

Para cada cambio entregar:

1. Diagnóstico breve.
2. Archivos modificados.
3. Código final completo del archivo o patch claro.
4. Endpoints agregados/modificados.
5. Cambios SQL necesarios.
6. Pruebas manuales sugeridas.

No hacer refactors visuales innecesarios.

No cambiar el diseño del cliente.

No eliminar funcionalidades existentes.

No convertir todo a framework.

Mantener HTML/CSS/JS puro salvo que se indique lo contrario.

No romper compatibilidad entre tableros.

Tener en cuenta que el cliente puede seguir agregando HTMLs standalone.
La arquitectura debe permitir incorporar nuevos tableros siguiendo este patrón:

1. Relevar localStorage usado por el tablero.
2. Identificar entidades.
3. Crear endpoints y tablas si faltan.
4. Reemplazar persistencia local por API.
5. Adaptar renderizado asincrónico.
6. Validar con datos reales.

Primer trabajo concreto
=======================

Tomá como primer objetivo corregir y completar la migración de maestros.html, pa-core.js y server.js.

En particular:

- Revisar todos los ABMs de maestros.html.
- Detectar accesos persistentes heredados.
- Verificar que todos los ABMs creen, editen, borren y listen vía API.
- Corregir Insumos:
  - no borra
  - permite duplicados
- Revisar si otros maestros tienen el mismo problema de borrado por no enviar empresaId.
- Asegurar que el backend valide duplicados en maestros críticos.
- Asegurar que los errores del backend sean visibles en frontend.
- Eliminar cualquier dependencia funcional de cache/localStorage para datos maestros.

Resultado esperado
==================

Una versión 3 capas real donde:

- maestros.html conserva su diseño
- los datos vienen de PostgreSQL vía API
- altas/modificaciones/bajas se hacen vía API
- no se usa localStorage como fuente de datos
- Insumos borra correctamente
- Insumos no permite duplicados
- el frontend maneja correctamente el delay de la API
- el backend valida permisos y datos
- el proyecto queda preparado para migrar el resto de tableros con el mismo patrón