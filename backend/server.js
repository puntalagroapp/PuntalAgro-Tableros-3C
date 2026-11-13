/* =============================================================================
   server.js — API backend Puntal Agro (Node.js + Express + PostgreSQL)
   =============================================================================
   Endpoints:
     GET  /api/init                         Todos los datos del usuario actual
     GET  /api/context?empresaId=           Contexto y permisos para una empresa
     POST /api/auth/login                   Iniciar sesión (email)
     POST /api/auth/logout                  Cerrar sesión

     POST   /api/maestros/:coleccion        Crear registro
     PUT    /api/maestros/:coleccion/:id    Actualizar registro
     DELETE /api/maestros/:coleccion/:id    Eliminar registro
   ============================================================================= */

const express = require('express');
const path    = require('path');
const fs      = require('fs');
const cors    = require('cors');
const crypto  = require('crypto');
const multer  = require('multer');
const { Pool } = require('pg');

function hashearPassword(password) {
  return new Promise(function(resolve, reject) {
    var salt = crypto.randomBytes(16).toString('hex');
    crypto.scrypt(password, salt, 64, function(err, key) {
      if (err) return reject(err);
      resolve(salt + ':' + key.toString('hex'));
    });
  });
}

function verificarPassword(password, hash) {
  return new Promise(function(resolve, reject) {
    var parts = hash.split(':');
    crypto.scrypt(password, parts[0], 64, function(err, key) {
      if (err) return reject(err);
      resolve(key.toString('hex') === parts[1]);
    });
  });
}

// ── CORS ────────────────────────────────────────────────────────────────────
// Orígenes permitidos vienen de la variable de entorno ALLOWED_ORIGINS
// (lista separada por comas). Si no está definida se permite todo (dev fallback).
const _allowedOrigins = (process.env.ALLOWED_ORIGINS || '')
  .split(',').map(s => s.trim()).filter(Boolean);

const app = express();
app.use(cors({
  origin: function (origin, callback) {
    if (!origin) return callback(null, true); // same-origin / curl / Postman
    if (!_allowedOrigins.length) return callback(null, true); // sin restricción si no está configurado
    if (_allowedOrigins.indexOf(origin) !== -1) return callback(null, true);
    callback(null, false); // rechazar silenciosamente
  }
}));
// La carga desde Excel manda la campaña entera de una vez (OT, movimientos) y el
// mapa de un campo (KML) trae miles de vértices: esas rutas aceptan más que el resto.
const jsonChico = express.json({ limit: '2mb' });
const jsonGrande = express.json({ limit: '40mb' });
app.use((req, res, next) => ((req.path.indexOf('/api/carga-excel/') === 0 || req.path === '/api/lotes-geo') ? jsonGrande : jsonChico)(req, res, next));

// ── RATE LIMITING (en memoria, login) ───────────────────────────────────────
const _loginRateMap = new Map();
const RATE_WINDOW_MS = 15 * 60 * 1000; // 15 minutos
const RATE_MAX = 10;                    // intentos por ventana por IP

function loginRateLimitExcedido(ip) {
  const ahora = Date.now();
  let e = _loginRateMap.get(ip);
  if (!e || ahora > e.resetAt) {
    e = { count: 0, resetAt: ahora + RATE_WINDOW_MS };
    _loginRateMap.set(ip, e);
  }
  e.count++;
  return e.count > RATE_MAX;
}

// Sirve el frontend de forma estática
app.use(express.static(path.join(__dirname, '../frontend')));

// ── Tableros de decisión propios: fallback si todavía no se publicó ────────
// El cliente publica cada tablero (Comercial Agrícola, Evolución de
// Variables, etc.) subiendo su index.html por SFTP a una carpeta fija
// (frontend/tableros-decision/<carpeta>/). Si esa carpeta no tiene
// index.html todavía (recién creada, o una transferencia que quedó a medias)
// express.static no encuentra nada y, sin esto, Express devolvería un 404
// crudo sin estilo. Solo se llega hasta acá cuando el archivo NO existe: si
// existe, express.static ya lo sirvió arriba y esta ruta nunca corre.
app.get(/^\/tableros-decision\/([a-z0-9-]+)\/?$/, (req, res) => {
  res.status(404).send(
    '<!DOCTYPE html><html lang="es"><head><meta charset="UTF-8">' +
    '<title>Tablero no disponible · Puntal Agro</title>' +
    '<style>' +
    'body{margin:0;font-family:"DM Sans",sans-serif;background:#F0F2F5;color:#0F1923;' +
    'min-height:100vh;display:flex;align-items:center;justify-content:center}' +
    '.card{background:#fff;border:1px solid #E4E8EE;border-radius:12px;padding:32px 36px;' +
    'max-width:420px;text-align:center;box-shadow:0 1px 3px rgba(15,25,35,.04)}' +
    'h1{font-size:17px;margin:0 0 8px}' +
    'p{font-size:13px;color:#7A8899;line-height:1.5;margin:0 0 20px}' +
    'a{font-size:12px;font-weight:600;color:#4A6533;text-decoration:none}' +
    'a:hover{color:#C8642D}' +
    '</style></head><body>' +
    '<div class="card">' +
    '<h1>Este tablero todavía no fue publicado</h1>' +
    '<p>El contenido de este tablero de decisión está pendiente de carga. Volvé a intentarlo más tarde.</p>' +
    '<a href="/index.html#dec">← Volver a Tableros de Decisión</a>' +
    '</div></body></html>'
  );
});

const pool = new Pool({ connectionString: process.env.DATABASE_URL });

// ── PDFs de herramientas externas (subidos por admin_general) ──────────────
const HERRAMIENTAS_UPLOADS_DIR = path.join(__dirname, '../frontend/uploads/herramientas');
fs.mkdirSync(HERRAMIENTAS_UPLOADS_DIR, { recursive: true });

const uploadPdfHerramienta = multer({
  storage: multer.diskStorage({
    destination: function (req, file, cb) { cb(null, HERRAMIENTAS_UPLOADS_DIR); },
    filename: function (req, file, cb) { cb(null, req.params.id + '_' + Date.now() + '.pdf'); }
  }),
  fileFilter: function (req, file, cb) {
    if (file.mimetype !== 'application/pdf') return cb(new Error('Solo se aceptan archivos PDF'));
    cb(null, true);
  },
  limits: { fileSize: 15 * 1024 * 1024 } // 15MB
}).single('pdf');

// Borra un archivo previamente subido a HERRAMIENTAS_UPLOADS_DIR a partir de la
// url guardada en la fila (nunca fuera de esa carpeta: path.basename() descarta
// cualquier intento de traversal en el valor guardado).
function borrarPdfHerramientaSiPropio(urlAnterior) {
  if (!urlAnterior || urlAnterior.indexOf('uploads/herramientas/') !== 0) return;
  const archivo = path.basename(urlAnterior);
  fs.unlink(path.join(HERRAMIENTAS_UPLOADS_DIR, archivo), function () {});
}

// ── Archivos de herramientas internas (tipo='interna', "Herramientas Puntal") ──
// A diferencia de HERRAMIENTAS_UPLOADS_DIR (externas: públicas, serán servidas
// tal cual por express.static), esta carpeta vive FUERA de frontend/ a
// propósito: nadie puede descargarla pisando la URL a mano. Solo se llega al
// archivo real vía /api/herramientas/:id/archivo-url + /archivo, que chequean
// sesión y el permiso herramientas_internas antes de entregar nada.
const HERRAMIENTAS_INTERNAS_DIR = path.join(__dirname, '../uploads-internos/herramientas');
fs.mkdirSync(HERRAMIENTAS_INTERNAS_DIR, { recursive: true });

const EXT_INTERNA_POR_MIME = {
  'application/pdf': '.pdf',
  'application/msword': '.doc',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document': '.docx',
  'application/vnd.ms-excel': '.xls',
  'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet': '.xlsx',
};

const uploadArchivoInterno = multer({
  storage: multer.diskStorage({
    // mkdirSync de nuevo acá (no solo al arrancar el server): esta carpeta vive
    // en un volumen Docker aparte (uploads-internos/) que puede llegar vacío
    // en un deploy nuevo, así que se re-crea sola si hace falta en vez de
    // fallar con ENOENT en el primer archivo que alguien suba.
    destination: function (req, file, cb) {
      fs.mkdirSync(HERRAMIENTAS_INTERNAS_DIR, { recursive: true });
      cb(null, HERRAMIENTAS_INTERNAS_DIR);
    },
    filename: function (req, file, cb) {
      const ext = EXT_INTERNA_POR_MIME[file.mimetype] || path.extname(file.originalname || '').slice(0, 10);
      cb(null, req.params.id + '_' + Date.now() + ext);
    }
  }),
  fileFilter: function (req, file, cb) {
    if (!EXT_INTERNA_POR_MIME[file.mimetype]) return cb(new Error('Formato no admitido (PDF, Word o Excel)'));
    cb(null, true);
  },
  limits: { fileSize: 15 * 1024 * 1024 } // 15MB
}).single('archivo');

function borrarArchivoInternoSiPropio(urlAnterior) {
  if (!urlAnterior || urlAnterior.indexOf('interno:') !== 0) return;
  const archivo = path.basename(urlAnterior.slice('interno:'.length));
  fs.unlink(path.join(HERRAMIENTAS_INTERNAS_DIR, archivo), function () {});
}

// Tokens de un solo uso para abrir un archivo interno desde un <a>/window.open
// (no puede llevar el header Authorization). Vida corta y de un solo uso: se
// piden recién al hacer clic, ya habiendo pasado el chequeo de permiso.
const _tokensArchivoInterno = new Map(); // token -> { herramientaId, expira }
function mintTokenArchivoInterno(herramientaId) {
  const token = crypto.randomBytes(24).toString('hex');
  _tokensArchivoInterno.set(token, { herramientaId: herramientaId, expira: Date.now() + 30000 });
  return token;
}
function consumirTokenArchivoInterno(token, herramientaId) {
  const entry = _tokensArchivoInterno.get(token);
  _tokensArchivoInterno.delete(token);
  return !!entry && entry.herramientaId === herramientaId && entry.expira > Date.now();
}

const UNIQUE_ERROR_MESSAGES = {
  'uq_clientes_nombre':                'Ya existe un cliente con ese nombre',
  'uq_clientes_cuit':                  'Ya existe un cliente con ese CUIT',
  'uq_empresas_rs_cliente':            'Ya existe una empresa con esa razón social para este cliente',
  'uq_empresas_cuit':                  'Ya existe una empresa con ese CUIT',
  'uq_campos_nombre_empresa':          'Ya existe un campo con ese nombre en esta empresa',
  'uq_labores_nombre':                 'Ya existe una labor con ese nombre',
  'uq_especies_nombre':                'Ya existe una especie con ese nombre',
  'uq_modos_accion_sistema_codigo':    'Ya existe un modo de acción con ese código en este sistema',
  'uq_terceros_nombre_empresa':        'Ya existe un proveedor/cliente con ese nombre en esta empresa',
  'uq_choferes_nombre_empresa':        'Ya existe un chofer con ese nombre en esta empresa',
  'uq_depositos_nombre_empresa':       'Ya existe un depósito con ese nombre en esta empresa',
  'uq_tipos_actividad_nombre_empresa': 'Ya existe un cultivo/uso con ese nombre en esta empresa',
  'ux_insumos_empresa_nombre_tipo':    'Ya existe un insumo con ese nombre y tipo para esta empresa',
  'uq_usuarios_email':                 'El email ya está registrado por otro usuario',
  'uq_unidades_sigla':                 'Ya existe una unidad de medida con esa sigla',
  'uq_tipos_proveedor_nombre':         'Ya existe un tipo de proveedor con ese nombre',
  'uq_lotes_nombre_empresa':           'Ya existe un lote con ese nombre en esta empresa',
  'uq_campanias_nombre':               'Ya existe una campaña con ese nombre',
  'uq_categorias_insumo_codigo':       'Ya existe una categoría de insumo con ese código',
  'uq_usos_actividad_codigo':          'Ya existe un uso con ese código',
  'uq_tenencias_nombre':               'Ya existe una tenencia con ese nombre',
  'uq_formulaciones_descripcion':      'Ya existe una formulación con esa descripción',
  'uq_principios_activos_nombre':      'Ya existe un principio activo con ese nombre',
  'uq_socios_nombre_empresa':          'Ya existe un socio con ese nombre en esta empresa',
  'uq_categorias_hacienda_nombre':     'Ya existe una categoría de hacienda con ese nombre',
  'uq_negocios_ganaderos_nombre':     'Ya existe una unidad de negocio con ese nombre',
  'uq_rodeos_nombre':                 'Ya existe un rodeo con ese nombre',
  'uq_raciones_nombre':               'Ya existe una ración con ese nombre',
};
// datos del insumo + % de materia seca (columna propia, la carga Registro de Pastoreos)
const SQL_INSUMO_DATOS = `CASE WHEN pct_ms IS NULL THEN datos ELSE datos || jsonb_build_object('pctMS', pct_ms) END AS datos`;
function uniqueViolation(err) {
  if (err.code !== '23505') return null;
  return UNIQUE_ERROR_MESSAGES[err.constraint] || 'Ya existe un registro con esos datos';
}

const FK_ERROR_MESSAGES = {
  'empresas_cliente_id_fkey': 'No se puede borrar: el cliente tiene empresas asociadas',
  'usuarios_cliente_id_fkey': 'No se puede borrar: el cliente tiene usuarios asociados',
  'comprobantes_ref_ot_trabajo_empresa_id_fkey': 'No se puede borrar: ya generó movimientos de stock (comprobantes)',
  'ot_destino_lineas_insumo_fk':    'No se puede borrar: el insumo está usado en órdenes de trabajo',
  'ot_plantilla_insumo_fk':         'No se puede borrar: el insumo está usado en órdenes de trabajo',
  'ot_destino_lineas_deposito_fk':  'No se puede borrar: el depósito está usado en órdenes de trabajo',
  'ot_plantilla_deposito_fk':       'No se puede borrar: el depósito está usado en órdenes de trabajo',
  'movimientos_insumo_id_empresa_id_fkey':           'No se puede borrar: el insumo tiene movimientos de stock',
  'movimientos_origen_deposito_id_empresa_id_fkey':  'No se puede borrar: el depósito tiene movimientos de stock',
  'movimientos_destino_deposito_id_empresa_id_fkey': 'No se puede borrar: el depósito tiene movimientos de stock',
  'ot_destinos_campo_fk':           'No se puede borrar: el campo tiene órdenes de trabajo',
  'depositos_campo_fk':             'No se puede borrar: el campo tiene depósitos',
  'depositos_especie_fk':           'No se puede borrar: hay depósitos de granos de esa especie',
};
// Mismo código de error (23503) cuando lo que se guarda apunta a algo que no existe.
const FK_FALTANTE_MESSAGES = {
  'ot_destino_lineas_insumo_fk':   'La OT usa un insumo que ya no existe',
  'ot_plantilla_insumo_fk':        'La OT usa un insumo que ya no existe',
  'ot_destino_lineas_deposito_fk': 'La OT usa un depósito que ya no existe',
  'ot_plantilla_deposito_fk':      'La OT usa un depósito que ya no existe',
  'ot_destinos_campo_fk':          'La OT tiene un lote de un campo que ya no existe',
  'depositos_campo_fk':            'El campo elegido para el depósito ya no existe',
  'depositos_especie_fk':          'La especie elegida para el depósito ya no existe',
};
function fkViolation(err) {
  if (err.code !== '23503') return null;
  if (/is not present in table/.test(err.detail || '')) {
    return FK_FALTANTE_MESSAGES[err.constraint] || 'Hace referencia a un registro que ya no existe';
  }
  return FK_ERROR_MESSAGES[err.constraint] || 'No se puede borrar: tiene registros asociados';
}

// ─────────────────────────────────────────────────────────────────────────────
// HELPER: recupera la sesión del usuario a partir del header Authorization.
// Devuelve null si no hay token válido (el endpoint decide si bloquear o no).
// ─────────────────────────────────────────────────────────────────────────────
async function obtenerSesion(req) {
  const auth = req.headers['authorization'] || '';
  const token = auth.replace(/^Bearer\s+/i, '').trim();
  if (!token) return null;
  try {
    const r = await pool.query(
      `SELECT u.id, u.nombre, u.email, u.rol, u.cliente_id, u.herramientas_internas, u.usuario_interno, s.empresa_id_activa
         FROM sesiones s
         JOIN usuarios u ON u.id = s.usuario_id
        WHERE s.token = $1
          AND (s.expira_en IS NULL OR s.expira_en > NOW())`,
      [token]
    );
    return r.rows[0] || null;
  } catch { return null; }
}

// Devuelve { campoIds, herramientas, nivel } si el usuario tiene acceso a la
// empresa indicada, o null si no tiene acceso o no está autenticado.
// campoIds = [] significa acceso a todos los campos de la empresa.
async function obtenerPermiso(req, empresaId) {
  const sesion = await obtenerSesion(req);
  if (!sesion) return null;

  if (sesion.rol === 'admin_general') {
    return { campoIds: [], herramientas: [], nivel: 'administrar' };
  }

  if (sesion.rol === 'admin_cliente') {
    const emp = await pool.query(
      'SELECT id FROM empresas WHERE id = $1 AND cliente_id = $2 AND activo = true',
      [empresaId, sesion.cliente_id]
    );
    if (!emp.rows.length) return null;
    return { campoIds: [], herramientas: [], nivel: 'administrar' };
  }

  const r = await pool.query(
    'SELECT campo_ids AS "campoIds", herramientas, nivel FROM permisos WHERE usuario_id = $1 AND empresa_id = $2',
    [sesion.id, empresaId]
  );
  return r.rows[0] || null;
}

// Sólo admin_general puede crear/editar/borrar catálogos globales (colecciones con porEmpresa=false).
function esAdminGeneral(sesion) {
  return sesion.rol === 'admin_general';
}

// admin_general/admin_cliente siempre pueden escribir maestros de empresa; un usuario
// común necesita nivel 'cargar' o 'administrar' (nivel 'ver' sólo lee).
function puedeEscribirMaestroEmpresa(sesion, permiso) {
  return sesion.rol === 'admin_general' || sesion.rol === 'admin_cliente' ||
    permiso.nivel === 'administrar' || permiso.nivel === 'cargar';
}

// Nivel del usuario sobre una herramienta (ver < cargar < administrar).
// herramientas=[] significa "todas" solo con nivel 'administrar' (admin_general y
// admin_cliente lo tienen siempre vía obtenerPermiso); con 'ver'/'cargar' la
// herramienta tiene que estar tildada en el permiso.
const NIVEL_RANGO = { ver: 1, cargar: 2, administrar: 3 };
function puedeEnHerramienta(permiso, herramienta, nivelRequerido) {
  if (!permiso) return false;
  if ((NIVEL_RANGO[permiso.nivel] || 0) < (NIVEL_RANGO[nivelRequerido] || 1)) return false;
  if (permiso.nivel === 'administrar') return true;
  return (permiso.herramientas || []).indexOf(herramienta) !== -1;
}

// Depósito general (sin campoId): lo ve cualquiera de la empresa, pero solo lo
// crea/edita/borra nivel 'administrar' (admin_general/admin_cliente siempre
// tienen ese nivel vía obtenerPermiso). Depósito de campo: alcanza 'cargar' +
// que el campo esté dentro de los campoIds del usuario (si tiene restricción).
function depositoAccesibleParaEscritura(permiso, campoId) {
  if (!campoId) return permiso.nivel === 'administrar';
  const campoIds = permiso.campoIds || [];
  if (campoIds.length === 0) return true;
  return campoIds.indexOf(campoId) !== -1;
}

// OT y campos habilitados (mismo criterio que destinoVisible() del tablero):
// un lote sin campo cuenta como visible. Una OT se ve si no tiene lotes o si
// al menos uno es de un campo habilitado; las mixtas viajan enteras porque al
// guardarlas el tablero reenvía todos sus lotes (los ajenos quedan de solo lectura).
function campoHabilitado(permiso, campoId) {
  const campoIds = permiso.campoIds || [];
  return !campoId || campoIds.length === 0 || campoIds.indexOf(campoId) !== -1;
}
function destinosDeTrabajos(trabajos) {
  const out = [];
  for (const t of trabajos || []) for (const d of (t && t.destinos) || []) if (d) out.push(d);
  return out;
}
function otVisibleParaPermiso(permiso, trabajos) {
  if (!(permiso.campoIds || []).length) return true;
  const ds = destinosDeTrabajos(trabajos);
  return !ds.length || ds.some(d => campoHabilitado(permiso, d.campoId));
}
// ids de los lotes de la OT que son de campos NO habilitados (para comparar antes/después)
async function trabajosGuardadosDeOt(db, otId, empresaId) {
  // Solo hace falta id y campo de cada lote (ver destinosAjenos/otVisibleParaPermiso).
  const r = await db.query(
    `SELECT d.id, d.campo_id AS "campoId"
       FROM ot_destinos d JOIN ot_trabajos t ON t.id = d.trabajo_id AND t.empresa_id = d.empresa_id
      WHERE t.ot_id = $1 AND t.empresa_id = $2`, [otId, empresaId]);
  return [{ destinos: r.rows }];
}
function destinosAjenos(permiso, trabajos) {
  return destinosDeTrabajos(trabajos).filter(d => !campoHabilitado(permiso, d.campoId))
    .map(d => String(d.id || '') + '|' + d.campoId).sort();
}

// Movimientos y campos habilitados (mismo criterio que renderMovtos() del tablero):
// un movimiento es "ajeno" si toca algún depósito y ninguno de sus depósitos es
// de un campo habilitado. Un depósito sin campo (general) lo ve cualquiera.
// Devuelve null si el usuario no tiene restricción de campos.
async function depositosAjenos(db, permiso, empresaId) {
  const campoIds = permiso.campoIds || [];
  if (!campoIds.length) return null;
  const r = await db.query(
    `SELECT id FROM depositos
      WHERE empresa_id = $1 AND campo_id IS NOT NULL
        AND NOT (campo_id = ANY($2::text[]))`,
    [empresaId, campoIds]);
  return new Set(r.rows.map(x => x.id));
}
function lineaAjena(ajenos, origenId, destinoId) {
  if (!ajenos || (!origenId && !destinoId)) return false;
  const visO = origenId && !ajenos.has(origenId), visD = destinoId && !ajenos.has(destinoId);
  return !visO && !visD;
}
const MSG_COMP_AJENO = 'El comprobante tiene movimientos de depósitos de campos que tu usuario no tiene habilitados';
async function comprobanteTieneAjenos(db, ajenos, compId, empresaId) {
  if (!ajenos) return false;
  const r = await db.query(
    `SELECT origen_deposito_id AS o, destino_deposito_id AS d FROM movimientos WHERE comprobante_id=$1 AND empresa_id=$2`,
    [compId, empresaId]);
  return r.rows.some(x => lineaAjena(ajenos, x.o, x.d));
}

// ─────────────────────────────────────────────────────────────────────────────
// LOCKING PESIMISTA DE REGISTROS
// Evita que dos usuarios de la MISMA empresa pisen el mismo registro editando
// a la vez. 'tabla' es un identificador lógico (nombre de colección, o
// namespace tipo 'plan_uso_suelo:lote' para sub-recursos dentro de un blob).
// Un lock vence solo por timeout (no hay heartbeat); se acepta ese trade-off.
// ─────────────────────────────────────────────────────────────────────────────
const LOCK_TIMEOUT_MINUTES = 10;

// Devuelve { usuarioId, usuarioNombre } si el registro está bloqueado por OTRO
// usuario de forma vigente, o null si está libre / vencido / es el dueño.
async function verificarLockPropio(tabla, id, sesion) {
  const r = await pool.query(
    `SELECT rl.usuario_id AS "usuarioId", u.nombre AS "usuarioNombre"
       FROM registro_locks rl JOIN usuarios u ON u.id = rl.usuario_id
      WHERE rl.tabla = $1 AND rl.registro_id = $2
        AND rl.bloqueado_en > NOW() - ($3 || ' minutes')::interval`,
    [tabla, id, String(LOCK_TIMEOUT_MINUTES)]
  );
  if (!r.rows.length) return null;
  if (r.rows[0].usuarioId === sesion.id) return null;
  return r.rows[0];
}

// ─────────────────────────────────────────────────────────────────────────────
// TABLA: sesiones  (agregamos columna empresa_id_activa si no existe)
// Se ejecuta al arrancar para asegurar la columna de empresa activa.
// ─────────────────────────────────────────────────────────────────────────────
pool.query(`
  ALTER TABLE sesiones
    ADD COLUMN IF NOT EXISTS empresa_id_activa TEXT
`).catch(() => {});

// ─────────────────────────────────────────────────────────────────────────────
// COLECCIONES MAESTRAS
// Define qué tablas acepta el endpoint genérico /api/maestros/:coleccion.
// porEmpresa = true  → los registros llevan empresa_id; se filtra al leer.
// ─────────────────────────────────────────────────────────────────────────────
// Depósitos: columnas propias (migración 022). Se arma el mismo objeto que
// antes guardaba datos JSONB, que es lo que esperan pa-core y los tableros.
const SQL_DEPOSITO_DATOS = `jsonb_build_object('id',id,'empresaId',empresa_id,'campoId',campo_id,'nombre',nombre,
                                               'clase',clase,'especieId',especie_id,'activo',activo)`;
// Clase de depósito: solo 'insumos' o 'granos'. Si no viene (o viene vacía) es
// 'insumos', como hace la pantalla; cualquier otro valor es un error (null).
function claseDeposito(v) {
  if (v === undefined || v === null || v === '') return 'insumos';
  return v === 'insumos' || v === 'granos' ? v : null;
}
const ERR_CLASE_DEPOSITO = 'La clase del depósito tiene que ser "insumos" o "granos"';

// Categoría de un insumo (datos.tipo): tiene que ser un código activo de
// categorias_insumo. En el alta es obligatoria; en la modificación solo se
// valida si viene, porque el PUT hace merge (tablero_insumos_ot manda solo
// los campos operativos, sin tipo). Devuelve el mensaje de error o null.
async function errorTipoInsumo(db, obj, esAlta) {
  if (!esAlta && !Object.prototype.hasOwnProperty.call(obj, 'tipo')) return null;
  if (obj.tipo === undefined || obj.tipo === null || String(obj.tipo).trim() === '') return 'Falta la categoría del insumo';
  const r = await db.query('SELECT 1 FROM categorias_insumo WHERE codigo = $1 AND activo = true', [String(obj.tipo)]);
  return r.rows.length ? null : 'La categoría "' + obj.tipo + '" no existe o no está activa';
}

async function guardarDeposito(db, obj) {
  await db.query(
    `INSERT INTO depositos (id, empresa_id, nombre, clase, campo_id, especie_id, activo)
     VALUES ($1, $2, $3, $4, $5, $6, $7)
     ON CONFLICT (id, empresa_id) DO UPDATE
       SET nombre=$3, clase=$4, campo_id=$5, especie_id=$6, activo=$7`,
    [obj.id, obj.empresaId, String(obj.nombre || '').trim(), claseDeposito(obj.clase) || 'insumos',
     obj.campoId || null, obj.especieId || null, obj.activo !== false]
  );
}

const COLECCIONES = {
  'terceros':          { tabla: 'terceros',          porEmpresa: true  },
  'choferes':          { tabla: 'choferes',          porEmpresa: true  },
  'depositos':         { tabla: 'depositos',         porEmpresa: true  },
  'insumos':           { tabla: 'insumos',           porEmpresa: true  },
  'tipos-actividad':   { tabla: 'tipos_actividad',   porEmpresa: true  },
  'socios':            { tabla: 'socios',            porEmpresa: true  },
  'labores':           { tabla: 'labores',           porEmpresa: false },
  'especies':          { tabla: 'especies',          porEmpresa: false },
  'unidades':          { tabla: 'unidades',          porEmpresa: false },
  'modos-accion':      { tabla: 'modos_accion',      porEmpresa: false },
  'tipos-proveedor':   { tabla: 'tipos_proveedor',   porEmpresa: false },
  'categorias-insumo': { tabla: 'categorias_insumo', porEmpresa: false },
  'usos':              { tabla: 'usos_actividad',    porEmpresa: false },
  'tenencias':         { tabla: 'tenencias',         porEmpresa: false },
  'formulaciones':     { tabla: 'formulaciones',     porEmpresa: false },
  'principios-activos':{ tabla: 'principios_activos',porEmpresa: false },
  'lotes':             { tabla: 'lotes',             porEmpresa: true  },
  'ambientes':         { tabla: 'ambientes',         porEmpresa: true  },
  'actividades':     { tabla: 'actividades',     porEmpresa: true  },
  'campanias':       { tabla: 'campanias',       porEmpresa: false },
  'cultivos-default':{ tabla: 'cultivos_default', porEmpresa: false },
};

// ─────────────────────────────────────────────────────────────────────────────
// GET /api/globales
// Solo listas fijas mantenidas por Puntal: labores, especies, unidades,
// modos_accion, tipos_proveedor + empresas disponibles para el usuario.
// Son datos pequeños que no crecen con el volumen de cada cliente.
// ─────────────────────────────────────────────────────────────────────────────
app.get('/api/globales', async (req, res) => {
  try {
    const sesion = await obtenerSesion(req);
    if (!sesion) return res.status(401).json({ error: 'No autenticado' });

    const [labores, especies, unidades, modosAccion, tiposProveedor, campanias,
           categoriasInsumo, usos, formulaciones, principiosActivos, tenencias] = await Promise.all([
      pool.query('SELECT id, nombre, unidad_labor AS "unidadLabor", precio_ref AS "precioRef", activo FROM labores WHERE activo = true ORDER BY nombre'),
      pool.query('SELECT id, nombre, sigla, activo FROM especies WHERE activo = true ORDER BY nombre'),
      pool.query('SELECT id, sigla, nombre, activo FROM unidades WHERE activo = true ORDER BY sigla'),
      pool.query('SELECT id, sistema, codigo, descripcion, activo FROM modos_accion WHERE activo = true ORDER BY sistema, codigo'),
      pool.query('SELECT id, nombre FROM tipos_proveedor ORDER BY nombre'),
      pool.query('SELECT id, nombre, orden, activa FROM campanias ORDER BY orden'),
      pool.query('SELECT id, codigo, label, base, fito, subcat, activo FROM categorias_insumo WHERE activo = true ORDER BY label'),
      pool.query('SELECT id, codigo, label, color, activo FROM usos_actividad WHERE activo = true ORDER BY label'),
      pool.query('SELECT id, codigo, descripcion, orden, activo FROM formulaciones WHERE activo = true ORDER BY orden'),
      pool.query('SELECT id, nombre, eiq, uso, activo FROM principios_activos WHERE activo = true ORDER BY nombre'),
      pool.query('SELECT id, nombre, activo FROM tenencias WHERE activo = true ORDER BY nombre'),
    ]);

    const payload = {
      labores:            labores.rows,
      especies:           especies.rows,
      unidades:           unidades.rows,
      modosAccion:        modosAccion.rows,
      tiposProveedor:     tiposProveedor.rows,
      campanias:          campanias.rows,
      categoriasInsumo:   categoriasInsumo.rows,
      usos:               usos.rows,
      formulaciones:      formulaciones.rows,
      principiosActivos:  principiosActivos.rows,
      tenencias:          tenencias.rows,
      empresas:       [],
      clientes:       [],
      campos:         [],
      sesion:         null,
    };

    if (!sesion) return res.json(payload);

    const token = (req.headers['authorization'] || '').replace(/^Bearer\s+/i, '').trim();
    payload.sesion = { id: sesion.id, nombre: sesion.nombre, email: sesion.email, rol: sesion.rol, clienteId: sesion.cliente_id || null, token };

    const empresaQuery = sesion.rol === 'admin_general'
      ? pool.query(`SELECT id, cliente_id AS "clienteId", razon_social AS "razonSocial", cuit,
                           condicion_iva AS "condicionIVA", direccion, activo
                      FROM empresas ORDER BY razon_social`)
      : pool.query(
          `SELECT e.id, e.cliente_id AS "clienteId", e.razon_social AS "razonSocial", e.cuit,
                  e.condicion_iva AS "condicionIVA", e.direccion, e.activo
             FROM empresas e JOIN permisos p ON p.empresa_id = e.id
            WHERE p.usuario_id = $1 ORDER BY e.razon_social`,
          [sesion.id]
        );

    const clienteQuery = sesion.rol === 'admin_general'
      ? pool.query(`SELECT id, nombre, email, telefono, nombre_contacto AS "nombreContacto",
                           razon_social AS "razonSocial", cuit, direccion,
                           factura_centralizada AS "facturaCentralizada",
                           activo, fecha_alta AS "fechaAlta"
                      FROM clientes ORDER BY nombre`)
      : pool.query(
          `SELECT DISTINCT c.id, c.nombre, c.email, c.telefono,
                  c.nombre_contacto AS "nombreContacto", c.razon_social AS "razonSocial",
                  c.cuit, c.direccion, c.factura_centralizada AS "facturaCentralizada",
                  c.activo, c.fecha_alta AS "fechaAlta"
             FROM clientes c
             JOIN empresas e ON e.cliente_id = c.id
             JOIN permisos p ON p.empresa_id = e.id
            WHERE p.usuario_id = $1 ORDER BY c.nombre`,
          [sesion.id]
        );

    const camposQuery = sesion.rol === 'admin_general'
      ? pool.query(`SELECT id, empresa_id AS "empresaId", nombre, localidad, partido, provincia,
                           ha_totales AS "haTotales" FROM campos ORDER BY nombre`)
      : pool.query(
          // Para rol 'usuario': filtra por campo_ids del permiso.
          // campo_ids = '{}' (vacío) significa acceso a todos los campos de la empresa.
          `SELECT DISTINCT ca.id, ca.empresa_id AS "empresaId", ca.nombre, ca.localidad,
                  ca.partido, ca.provincia, ca.ha_totales AS "haTotales"
             FROM campos ca
             JOIN permisos p ON p.empresa_id = ca.empresa_id
            WHERE p.usuario_id = $1
              AND (p.campo_ids = '{}' OR ca.id = ANY(p.campo_ids))
            ORDER BY ca.nombre`,
          [sesion.id]
        );

    const [empresaRes, clienteRes, camposRes] = await Promise.all([empresaQuery, clienteQuery, camposQuery]);
    payload.empresas = empresaRes.rows;
    payload.clientes = clienteRes.rows;
    payload.campos   = camposRes.rows;
    res.json(payload);
  } catch (err) {
    console.error('/api/globales error:', err);
    res.status(500).json({ error: 'Error interno del servidor' });
  }
});

// ─────────────────────────────────────────────────────────────────────────────
// GET /api/maestros-empresa/:empresaId
// Maestros propios de una empresa: campos, terceros, choferes, depósitos,
// insumos, tipos de actividad y ambientes. Se llama desde loadContext() después de
// que el usuario seleccionó (o tiene) una empresa activa.
// Solo devuelve datos de la empresa solicitada → volumen acotado.
// ─────────────────────────────────────────────────────────────────────────────
app.get('/api/maestros-empresa/:empresaId', async (req, res) => {
  try {
    const empresaId = req.params.empresaId;
    const permiso = await obtenerPermiso(req, empresaId);
    if (!permiso) return res.status(403).json({ error: 'Sin acceso a esta empresa' });

    // campoIds = [] → acceso total; si tiene elementos, filtra campos, lotes y actividades
    const campoIds = permiso.campoIds || [];
    const filtraCampos = campoIds.length > 0;

    const [campos, terceros, choferes, depositos, insumos, tiposActividad, ambientes, lotes, actividades] = await Promise.all([
      pool.query(
        filtraCampos
          ? 'SELECT id, empresa_id AS "empresaId", nombre, localidad, partido, provincia, ha_totales AS "haTotales" FROM campos WHERE empresa_id = $1 AND id = ANY($2::text[]) ORDER BY nombre'
          : 'SELECT id, empresa_id AS "empresaId", nombre, localidad, partido, provincia, ha_totales AS "haTotales" FROM campos WHERE empresa_id = $1 ORDER BY nombre',
        filtraCampos ? [empresaId, campoIds] : [empresaId]
      ),
      pool.query('SELECT datos FROM terceros        WHERE empresa_id = $1', [empresaId]),
      pool.query('SELECT datos FROM choferes        WHERE empresa_id = $1', [empresaId]),
      pool.query(`SELECT ${SQL_DEPOSITO_DATOS} AS datos FROM depositos WHERE empresa_id = $1`, [empresaId]),
      pool.query(`SELECT ${SQL_INSUMO_DATOS} FROM insumos WHERE empresa_id = $1`, [empresaId]),
      pool.query('SELECT datos FROM tipos_actividad WHERE empresa_id = $1', [empresaId]),
      pool.query('SELECT datos FROM ambientes       WHERE empresa_id = $1', [empresaId]),
      pool.query(
        filtraCampos
          ? `SELECT jsonb_build_object('id',id,'campoId',campo_id,'empresaId',empresa_id,'nombre',nombre,'ha',ha,
                                       'ambiente',ambiente,'explotable',explotable,'activo',activo,'tipoOverride',tipo_override,'geo',geo) AS datos
               FROM lotes WHERE empresa_id = $1 AND campo_id = ANY($2::text[])`
          : `SELECT jsonb_build_object('id',id,'campoId',campo_id,'empresaId',empresa_id,'nombre',nombre,'ha',ha,
                                       'ambiente',ambiente,'explotable',explotable,'activo',activo,'tipoOverride',tipo_override,'geo',geo) AS datos
               FROM lotes WHERE empresa_id = $1`,
        filtraCampos ? [empresaId, campoIds] : [empresaId]
      ),
      pool.query(
        filtraCampos
          ? `SELECT jsonb_build_object('id',a.id,'empresaId',a.empresa_id,'loteId',a.lote_id,'campaniaId',a.campania_id,
                                       'tipoActividadId',a.tipo_actividad_id,'ha',a.ha,'esSegunda',a.es_segunda,'tenenciaId',a.tenencia_id) AS datos
               FROM actividades a
               JOIN lotes l ON l.id = a.lote_id
              WHERE a.empresa_id = $1 AND l.campo_id = ANY($2::text[])`
          : `SELECT jsonb_build_object('id',id,'empresaId',empresa_id,'loteId',lote_id,'campaniaId',campania_id,
                                       'tipoActividadId',tipo_actividad_id,'ha',ha,'esSegunda',es_segunda,'tenenciaId',tenencia_id) AS datos
               FROM actividades WHERE empresa_id = $1`,
        filtraCampos ? [empresaId, campoIds] : [empresaId]
      ),
    ]);

    res.json({
      campos:         campos.rows,
      terceros:       terceros.rows.map(r => r.datos),
      choferes:       choferes.rows.map(r => r.datos),
      depositos:      depositos.rows.map(r => r.datos),
      insumos:        insumos.rows.map(r => r.datos),
      tiposActividad: tiposActividad.rows.map(r => r.datos),
      ambientes:      ambientes.rows.map(r => r.datos),
      lotes:          lotes.rows.map(r => r.datos),
      actividades:    actividades.rows.map(r => r.datos),
    });
  } catch (err) {
    console.error('/api/maestros-empresa error:', err);
    res.status(500).json({ error: 'Error interno del servidor' });
  }
});

// Mantener /api/init por compatibilidad — redirige a /api/globales
app.get('/api/init', (req, res) => res.redirect('/api/globales'));

// ─────────────────────────────────────────────────────────────────────────────
// GET /api/context?empresaId=
// Devuelve el contexto del usuario para la empresa solicitada:
// { usuario, empresaActivaId, empresasDisponibles, permiso }
// ─────────────────────────────────────────────────────────────────────────────
app.get('/api/context', async (req, res) => {
  try {
    const sesion = await obtenerSesion(req);
    if (!sesion) return res.status(401).json({ error: 'No autenticado' });

    // Empresas disponibles para el usuario
    let empresaQuery;
    if (sesion.rol === 'admin_general') {
      empresaQuery = pool.query(
        'SELECT id, razon_social AS "razonSocial" FROM empresas WHERE activo = true ORDER BY razon_social'
      );
    } else if (sesion.rol === 'admin_cliente') {
      empresaQuery = pool.query(
        'SELECT id, razon_social AS "razonSocial" FROM empresas WHERE cliente_id = $1 AND activo = true ORDER BY razon_social',
        [sesion.cliente_id]
      );
    } else {
      empresaQuery = pool.query(
        `SELECT e.id, e.razon_social AS "razonSocial"
           FROM empresas e JOIN permisos p ON p.empresa_id = e.id
          WHERE p.usuario_id = $1 AND e.activo = true ORDER BY e.razon_social`,
        [sesion.id]
      );
    }
    const empresas = await empresaQuery;
    const lista    = empresas.rows;

    // Sin empresaId explícito en el query: proponer la última empresa activa
    // de la sesión (la que se dejó seleccionada en index.html), si sigue
    // siendo una empresa a la que el usuario tiene acceso; si no, la primera.
    const activaValida = sesion.empresa_id_activa && lista.some(function (e) { return e.id === sesion.empresa_id_activa; });
    const empresaId = req.query.empresaId || (activaValida ? sesion.empresa_id_activa : null) || (lista.length ? lista[0].id : null);

    // Para 'usuario' el default es "sin acceso" (nivel null, herramientas=[]):
    // si no hay empresaId (ej. le borraron todos sus permisos) o no hay fila
    // en `permisos` para esa empresa, NO hay que caer en nivel='administrar'
    // — ese default es correcto solo para admin_general/admin_cliente, que
    // siempre administran. Antes se inicializaba en 'administrar' para todos
    // y un 'usuario' sin ninguna empresa terminaba viendo todas las
    // herramientas en el inicio (puedeVer trata nivel='administrar' como
    // acceso total), aunque el selector de empresa quedara vacío.
    let permiso = { campoIds: [], herramientas: [], nivel: sesion.rol === 'usuario' ? null : 'administrar' };
    if (sesion.rol === 'usuario' && empresaId) {
      const pRow = await pool.query(
        'SELECT campo_ids AS "campoIds", herramientas, nivel FROM permisos WHERE usuario_id = $1 AND empresa_id = $2',
        [sesion.id, empresaId]
      );
      if (pRow.rows.length) permiso = pRow.rows[0];
    }

    // Actualizar empresa activa en la sesión
    if (empresaId) {
      await pool.query(
        'UPDATE sesiones SET empresa_id_activa = $1 WHERE token = $2',
        [empresaId, req.headers['authorization'].replace(/^Bearer\s+/i,'').trim()]
      ).catch(() => {});
    }

    res.json({
      usuario: { id: sesion.id, nombre: sesion.nombre, email: sesion.email, rol: sesion.rol, clienteId: sesion.cliente_id || null, herramientasInternas: sesion.herramientas_internas === true, usuarioInterno: sesion.usuario_interno === true },
      empresaActivaId:      empresaId,
      empresasDisponibles:  lista,
      permiso,
    });
  } catch (err) {
    console.error('/api/context error:', err);
    res.status(500).json({ error: 'Error interno del servidor' });
  }
});

// ─────────────────────────────────────────────────────────────────────────────
// POST /api/auth/login   { email, password }
// ─────────────────────────────────────────────────────────────────────────────
app.post('/api/auth/login', async (req, res) => {
  const ip = req.ip || req.socket.remoteAddress;
  if (loginRateLimitExcedido(ip)) {
    return res.status(429).json({ error: 'Demasiados intentos. Esperá 15 minutos.' });
  }

  // Validar API key si está configurada en el entorno
  const apiKey = process.env.API_KEY;
  if (apiKey) {
    const bearer = (req.headers['authorization'] || '').replace(/^Bearer\s+/i, '').trim();
    if (bearer !== apiKey) return res.status(401).json({ error: 'No autorizado' });
  }

  const { email, password } = req.body || {};
  if (!email || typeof email !== 'string' || !password || typeof password !== 'string') {
    return res.status(400).json({ error: 'Falta email o contraseña' });
  }
  if (email.length > 254 || password.length > 200) {
    return res.status(400).json({ error: 'Datos de entrada inválidos' });
  }

  try {
    const userRow = await pool.query(
      'SELECT id, nombre, email, rol, cliente_id AS "clienteId", password_hash FROM usuarios WHERE email = $1 AND activo = true',
      [email.trim().toLowerCase()]
    );
    if (!userRow.rows.length) return res.status(401).json({ error: 'Email o contraseña incorrectos' });

    const usuario = userRow.rows[0];

    if (!usuario.password_hash) {
      return res.status(401).json({ error: 'Contraseña no configurada. Contacte al administrador.' });
    }

    const ok = await verificarPassword(password, usuario.password_hash);
    if (!ok) return res.status(401).json({ error: 'Email o contraseña incorrectos' });

    const token = 'tok_' + crypto.randomBytes(32).toString('hex');
    await pool.query(
      'INSERT INTO sesiones (token, usuario_id, expira_en) VALUES ($1, $2, NOW() + INTERVAL \'24 hours\')',
      [token, usuario.id]
    );

    const { password_hash, ...sesionData } = usuario;
    res.json({ sesion: { ...sesionData, token } });
  } catch (err) {
    console.error('/api/auth/login error:', err);
    res.status(500).json({ error: 'Error interno del servidor' });
  }
});

// POST /api/auth/logout
app.post('/api/auth/logout', async (req, res) => {
  const auth  = req.headers['authorization'] || '';
  const token = auth.replace(/^Bearer\s+/i, '').trim();
  if (token) {
    try {
      const s = await pool.query('SELECT usuario_id FROM sesiones WHERE token = $1', [token]);
      await pool.query('DELETE FROM sesiones WHERE token = $1', [token]);
      // Libera todos los locks de registros que tuviera tomados este usuario.
      if (s.rows.length) {
        await pool.query('DELETE FROM registro_locks WHERE usuario_id = $1', [s.rows[0].usuario_id]);
      }
    } catch (e) {}
  }
  res.json({ status: 'ok' });
});

// ─────────────────────────────────────────────────────────────────────────────
// GET    /api/maestros/:coleccion    Listar registros
// POST   /api/maestros/:coleccion    Crear registro
// PUT    /api/maestros/:coleccion/:id  Actualizar registro
// DELETE /api/maestros/:coleccion/:id  Eliminar registro
//
// Las tablas con porEmpresa=true almacenan el objeto completo en JSONB (datos).
// Las tablas globales (labores, especies, unidades…) tienen columnas propias.
// ─────────────────────────────────────────────────────────────────────────────
app.get('/api/maestros/:coleccion', async (req, res) => {
  const cfg = COLECCIONES[req.params.coleccion];
  if (!cfg) return res.status(404).json({ error: 'Colección desconocida' });

  try {
    const sesion = await obtenerSesion(req);
    if (!sesion) return res.status(401).json({ error: 'No autenticado' });

    if (cfg.porEmpresa) {
      const empresaId = req.query.empresaId;
      if (!empresaId) return res.status(400).json({ error: 'Falta empresaId en query' });

      const permiso = await obtenerPermiso(req, empresaId);
      if (!permiso) return res.status(403).json({ error: 'Sin acceso a esta empresa' });

      const campoIds = permiso.campoIds || [];
      const filtraCampos = campoIds.length > 0;

      let rows;
      if (cfg.tabla === 'lotes') {
        const r = await pool.query(
          filtraCampos
            ? `SELECT jsonb_build_object('id',id,'campoId',campo_id,'empresaId',empresa_id,'nombre',nombre,'ha',ha,
                                         'ambiente',ambiente,'explotable',explotable,'activo',activo,'tipoOverride',tipo_override,'geo',geo) AS datos
                 FROM lotes WHERE empresa_id = $1 AND campo_id = ANY($2::text[]) ORDER BY nombre`
            : `SELECT jsonb_build_object('id',id,'campoId',campo_id,'empresaId',empresa_id,'nombre',nombre,'ha',ha,
                                         'ambiente',ambiente,'explotable',explotable,'activo',activo,'tipoOverride',tipo_override,'geo',geo) AS datos
                 FROM lotes WHERE empresa_id = $1 ORDER BY nombre`,
          filtraCampos ? [empresaId, campoIds] : [empresaId]
        );
        rows = r.rows.map(r => r.datos);
      } else if (cfg.tabla === 'actividades') {
        const r = await pool.query(
          filtraCampos
            ? `SELECT jsonb_build_object('id',a.id,'empresaId',a.empresa_id,'loteId',a.lote_id,'campaniaId',a.campania_id,
                                         'tipoActividadId',a.tipo_actividad_id,'ha',a.ha,'esSegunda',a.es_segunda,'tenenciaId',a.tenencia_id) AS datos
                 FROM actividades a
                 JOIN lotes l ON l.id = a.lote_id
                WHERE a.empresa_id = $1 AND l.campo_id = ANY($2::text[])`
            : `SELECT jsonb_build_object('id',id,'empresaId',empresa_id,'loteId',lote_id,'campaniaId',campania_id,
                                         'tipoActividadId',tipo_actividad_id,'ha',ha,'esSegunda',es_segunda,'tenenciaId',tenencia_id) AS datos
                 FROM actividades WHERE empresa_id = $1`,
          filtraCampos ? [empresaId, campoIds] : [empresaId]
        );
        rows = r.rows.map(r => r.datos);
      } else if (cfg.tabla === 'depositos') {
        // Los depósitos sin campo (generales de la empresa) se ven siempre;
        // los atados a un campo puntual solo si el usuario tiene acceso a ese campo.
        const r = await pool.query(
          filtraCampos
            ? `SELECT ${SQL_DEPOSITO_DATOS} AS datos FROM depositos WHERE empresa_id = $1
                 AND (campo_id IS NULL OR campo_id = ANY($2::text[]))`
            : `SELECT ${SQL_DEPOSITO_DATOS} AS datos FROM depositos WHERE empresa_id = $1`,
          filtraCampos ? [empresaId, campoIds] : [empresaId]
        );
        rows = r.rows.map(r => r.datos);
      } else {
        const r = await pool.query(
          `SELECT ${cfg.tabla === 'insumos' ? SQL_INSUMO_DATOS : 'datos'} FROM ${cfg.tabla} WHERE empresa_id = $1`,
          [empresaId]
        );
        rows = r.rows.map(r => r.datos);
      }
      return res.json(rows);
    }

    // Colecciones globales
    let q;
    if (cfg.tabla === 'labores') {
      q = pool.query('SELECT id, nombre, unidad_labor AS "unidadLabor", precio_ref AS "precioRef", activo FROM labores WHERE activo = true ORDER BY nombre');
    } else if (cfg.tabla === 'especies') {
      q = pool.query('SELECT id, nombre, sigla, activo FROM especies WHERE activo = true ORDER BY nombre');
    } else if (cfg.tabla === 'unidades') {
      q = pool.query('SELECT id, sigla, nombre, activo FROM unidades WHERE activo = true ORDER BY sigla');
    } else if (cfg.tabla === 'modos_accion') {
      q = pool.query('SELECT id, sistema, codigo, descripcion, activo FROM modos_accion WHERE activo = true ORDER BY sistema, codigo');
    } else if (cfg.tabla === 'tipos_proveedor') {
      q = pool.query('SELECT id, nombre FROM tipos_proveedor ORDER BY nombre');
    } else if (cfg.tabla === 'campanias') {
      q = pool.query('SELECT id, nombre, orden, activa FROM campanias ORDER BY orden');
    } else if (cfg.tabla === 'categorias_insumo') {
      q = pool.query('SELECT id, codigo, label, base, fito, subcat, activo FROM categorias_insumo WHERE activo = true ORDER BY label');
    } else if (cfg.tabla === 'usos_actividad') {
      q = pool.query('SELECT id, codigo, label, color, activo FROM usos_actividad WHERE activo = true ORDER BY label');
    } else if (cfg.tabla === 'tenencias') {
      q = pool.query('SELECT id, nombre, activo FROM tenencias WHERE activo = true ORDER BY nombre');
    } else if (cfg.tabla === 'formulaciones') {
      q = pool.query('SELECT id, codigo, descripcion, orden, activo FROM formulaciones WHERE activo = true ORDER BY orden');
    } else if (cfg.tabla === 'principios_activos') {
      q = pool.query('SELECT id, nombre, eiq, uso, activo FROM principios_activos WHERE activo = true ORDER BY nombre');
    } else if (cfg.tabla === 'cultivos_default') {
      q = pool.query(
        `SELECT id, sigla, nombre, es_cultivo AS "esCultivo", actividad,
                especie_id AS "especieId", graminea, default2da, activo
           FROM cultivos_default WHERE activo = true ORDER BY nombre`
      );
    } else {
      return res.status(500).json({ error: 'Tabla global sin query definida' });
    }
    res.json((await q).rows);
  } catch (err) {
    console.error(`GET /api/maestros/${req.params.coleccion}:`, err);
    res.status(500).json({ error: 'Error interno del servidor' });
  }
});

app.post('/api/maestros/:coleccion', async (req, res) => {
  const cfg = COLECCIONES[req.params.coleccion];
  if (!cfg) return res.status(404).json({ error: 'Colección desconocida' });

  try {
    const sesion = await obtenerSesion(req);
    if (!sesion) return res.status(401).json({ error: 'No autenticado' });

    const obj = req.body;
    if (!obj.id) return res.status(400).json({ error: 'Falta id en el registro' });

    if (!cfg.porEmpresa && !esAdminGeneral(sesion)) {
      return res.status(403).json({ error: 'Sin permiso' });
    }

    if (cfg.porEmpresa) {
      if (!obj.empresaId) return res.status(400).json({ error: 'Falta empresaId' });
      const permiso = await obtenerPermiso(req, obj.empresaId);
      if (!permiso) return res.status(403).json({ error: 'Sin acceso a esta empresa' });
      if (!puedeEscribirMaestroEmpresa(sesion, permiso)) return res.status(403).json({ error: 'Sin permiso' });
      if (cfg.tabla === 'depositos' && !depositoAccesibleParaEscritura(permiso, obj.campoId || null)) {
        return res.status(403).json({ error: 'Solo podés cargar depósitos en tus campos habilitados' });
      }
      if (cfg.tabla === 'depositos' && !claseDeposito(obj.clase)) return res.status(400).json({ error: ERR_CLASE_DEPOSITO });
      if (cfg.tabla === 'insumos') {
        const errTipo = await errorTipoInsumo(pool, obj, true);
        if (errTipo) return res.status(400).json({ error: errTipo });
      }
      if (cfg.tabla === 'lotes') {
        await pool.query(
          `INSERT INTO lotes (id, campo_id, empresa_id, nombre, ha, ambiente, explotable, activo, tipo_override)
           VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
           ON CONFLICT (id) DO UPDATE
             SET campo_id=$2, nombre=$4, ha=$5, ambiente=$6, explotable=$7, activo=$8, tipo_override=$9`,
          [obj.id, obj.campoId || null, obj.empresaId, obj.nombre || null, obj.ha != null ? obj.ha : null,
           obj.ambiente || null, obj.explotable != null ? obj.explotable : null, obj.activo !== false, obj.tipoOverride || null]
        );
      } else if (cfg.tabla === 'actividades') {
        await pool.query(
          `INSERT INTO actividades (id, empresa_id, lote_id, campania_id, tipo_actividad_id, ha, es_segunda, tenencia_id)
           VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
           ON CONFLICT (id, empresa_id) DO UPDATE
             SET lote_id=$3, campania_id=$4, tipo_actividad_id=$5, ha=$6, es_segunda=$7, tenencia_id=$8`,
          [obj.id, obj.empresaId, obj.loteId || null, obj.campaniaId || null,
           obj.tipoActividadId || null, obj.ha != null ? obj.ha : null, obj.esSegunda || false, obj.tenenciaId || null]
        );
      } else if (cfg.tabla === 'depositos') {
        await guardarDeposito(pool, obj);
      } else {
        // Validación de duplicados para insumos: empresa + nombre (case-insensitive) + tipo
        if (cfg.tabla === 'insumos') {
          delete obj.pctMS; // vive en la columna insumos.pct_ms
          const dup = await pool.query(
            `SELECT id FROM insumos
              WHERE empresa_id = $1
                AND lower(datos->>'nombre') = lower($2)
                AND datos->>'tipo' = $3
                AND id != $4`,
            [obj.empresaId, obj.nombre || '', obj.tipo || '', obj.id]
          );
          if (dup.rows.length) return res.status(409).json({ error: 'Ya existe un insumo con ese nombre y tipo para esta empresa' });
        }
        await pool.query(
          `INSERT INTO ${cfg.tabla} (id, empresa_id${cfg.tabla === 'choferes' ? ', tercero_id' : ''}, datos)
           VALUES ($1, $2${cfg.tabla === 'choferes' ? ', $3, $4' : ', $3'})
           ON CONFLICT (id, empresa_id) DO UPDATE SET datos = EXCLUDED.datos`,
          cfg.tabla === 'choferes'
            ? [obj.id, obj.empresaId, obj.terceroId || null, obj]
            : [obj.id, obj.empresaId, obj]
        );
      }
    } else {
      await _upsertGlobal(cfg.tabla, obj);
    }
    res.status(201).json(obj);
  } catch (err) {
    console.error(`POST /api/maestros/${req.params.coleccion}:`, err);
    const msg = uniqueViolation(err) || fkViolation(err);
    if (msg) return res.status(409).json({ error: msg });
    res.status(500).json({ error: 'Error interno del servidor' });
  }
});

app.put('/api/maestros/:coleccion/:id', async (req, res) => {
  const cfg = COLECCIONES[req.params.coleccion];
  if (!cfg) return res.status(404).json({ error: 'Colección desconocida' });

  try {
    const sesion = await obtenerSesion(req);
    if (!sesion) return res.status(401).json({ error: 'No autenticado' });

    const obj = { ...req.body, id: req.params.id };

    if (!cfg.porEmpresa && !esAdminGeneral(sesion)) {
      return res.status(403).json({ error: 'Sin permiso' });
    }

    if (cfg.porEmpresa) {
      if (!obj.empresaId) return res.status(400).json({ error: 'Falta empresaId' });
      const permiso = await obtenerPermiso(req, obj.empresaId);
      if (!permiso) return res.status(403).json({ error: 'Sin acceso a esta empresa' });
      if (!puedeEscribirMaestroEmpresa(sesion, permiso)) return res.status(403).json({ error: 'Sin permiso' });
      if (cfg.tabla === 'depositos' && (permiso.campoIds || []).length > 0) {
        const actual = await pool.query(
          `SELECT campo_id AS "campoId" FROM depositos WHERE id = $1 AND empresa_id = $2`,
          [obj.id, obj.empresaId]
        );
        const campoIdActual = actual.rows[0] ? actual.rows[0].campoId : null;
        if (!depositoAccesibleParaEscritura(permiso, campoIdActual) ||
            !depositoAccesibleParaEscritura(permiso, obj.campoId || null)) {
          return res.status(403).json({ error: 'Solo podés modificar depósitos en tus campos habilitados' });
        }
      }
    }
    const bloqueo = await verificarLockPropio(req.params.coleccion, req.params.id, sesion);
    if (bloqueo) return res.status(409).json({ error: 'Lo está editando ' + bloqueo.usuarioNombre });

    if (cfg.tabla === 'depositos' && !claseDeposito(obj.clase)) return res.status(400).json({ error: ERR_CLASE_DEPOSITO });
    if (cfg.tabla === 'insumos') {
      const errTipo = await errorTipoInsumo(pool, obj, false);
      if (errTipo) return res.status(400).json({ error: errTipo });
    }

    if (cfg.porEmpresa) {
      if (cfg.tabla === 'lotes') {
        await pool.query(
          `UPDATE lotes SET campo_id=$2, nombre=$3, ha=$4, ambiente=$5, explotable=$6, activo=$7, tipo_override=$8 WHERE id=$1`,
          [obj.id, obj.campoId || null, obj.nombre || null, obj.ha != null ? obj.ha : null,
           obj.ambiente || null, obj.explotable != null ? obj.explotable : null, obj.activo !== false, obj.tipoOverride || null]
        );
      } else if (cfg.tabla === 'actividades') {
        await pool.query(
          `UPDATE actividades SET lote_id=$3, campania_id=$4, tipo_actividad_id=$5, ha=$6, es_segunda=$7, tenencia_id=$8
            WHERE id=$1 AND empresa_id=$2`,
          [obj.id, obj.empresaId, obj.loteId || null, obj.campaniaId || null,
           obj.tipoActividadId || null, obj.ha != null ? obj.ha : null, obj.esSegunda || false, obj.tenenciaId || null]
        );
      } else if (cfg.tabla === 'depositos') {
        await pool.query(
          `UPDATE depositos SET nombre=$3, clase=$4, campo_id=$5, especie_id=$6, activo=$7
            WHERE id=$1 AND empresa_id=$2`,
          [obj.id, obj.empresaId, String(obj.nombre || '').trim(), claseDeposito(obj.clase),
           obj.campoId || null, obj.especieId || null, obj.activo !== false]
        );
      } else {
        // Validación de duplicados para insumos en actualización
        if (cfg.tabla === 'insumos') {
          delete obj.pctMS; // vive en la columna insumos.pct_ms
          const dup = await pool.query(
            `SELECT id FROM insumos
              WHERE empresa_id = $1
                AND lower(datos->>'nombre') = lower($2)
                AND datos->>'tipo' = $3
                AND id != $4`,
            [obj.empresaId, obj.nombre || '', obj.tipo || '', obj.id]
          );
          if (dup.rows.length) return res.status(409).json({ error: 'Ya existe un insumo con ese nombre y tipo para esta empresa' });
        }
        // insumos: merge en vez de reemplazar — tablero_insumos_ot.html guarda ahí
        // campos operativos (stockMin/precioUnitario/moneda/deposito) que no debe
        // perder cuando se edita la identidad (nombre/tipo/etc.) desde Maestros, y
        // viceversa.
        await pool.query(
          cfg.tabla === 'insumos'
            ? `UPDATE insumos SET datos = datos || $3::jsonb WHERE id = $1 AND empresa_id = $2`
            : `UPDATE ${cfg.tabla} SET datos = $3${cfg.tabla === 'choferes' ? ', tercero_id = $4' : ''}
                WHERE id = $1 AND empresa_id = $2`,
          cfg.tabla === 'choferes'
            ? [obj.id, obj.empresaId, obj, obj.terceroId || null]
            : [obj.id, obj.empresaId, obj]
        );
      }
    } else {
      await _upsertGlobal(cfg.tabla, obj);
    }
    res.json(obj);
  } catch (err) {
    console.error(`PUT /api/maestros/${req.params.coleccion}/${req.params.id}:`, err);
    const msg = uniqueViolation(err) || fkViolation(err);
    if (msg) return res.status(409).json({ error: msg });
    res.status(500).json({ error: 'Error interno del servidor' });
  }
});

app.delete('/api/maestros/:coleccion/:id', async (req, res) => {
  const cfg = COLECCIONES[req.params.coleccion];
  if (!cfg) return res.status(404).json({ error: 'Colección desconocida' });

  try {
    const sesion = await obtenerSesion(req);
    if (!sesion) return res.status(401).json({ error: 'No autenticado' });

    if (!cfg.porEmpresa && !esAdminGeneral(sesion)) {
      return res.status(403).json({ error: 'Sin permiso' });
    }

    const empresaId = req.query.empresaId;
    if (cfg.porEmpresa && !empresaId) return res.status(400).json({ error: 'Falta empresaId en query' });
    if (cfg.porEmpresa) {
      const permiso = await obtenerPermiso(req, empresaId);
      if (!permiso) return res.status(403).json({ error: 'Sin acceso a esta empresa' });
      if (!puedeEscribirMaestroEmpresa(sesion, permiso)) return res.status(403).json({ error: 'Sin permiso' });
      if (cfg.tabla === 'depositos' && (permiso.campoIds || []).length > 0) {
        const actual = await pool.query(
          `SELECT campo_id AS "campoId" FROM depositos WHERE id = $1 AND empresa_id = $2`,
          [req.params.id, empresaId]
        );
        const campoIdActual = actual.rows[0] ? actual.rows[0].campoId : null;
        if (!depositoAccesibleParaEscritura(permiso, campoIdActual)) {
          return res.status(403).json({ error: 'Solo podés borrar depósitos en tus campos habilitados' });
        }
      }
    }
    const bloqueo = await verificarLockPropio(req.params.coleccion, req.params.id, sesion);
    if (bloqueo) return res.status(409).json({ error: 'Lo está editando ' + bloqueo.usuarioNombre });

    if (cfg.tabla === 'lotes') {
      await pool.query('DELETE FROM lotes WHERE id = $1', [req.params.id]);
    } else if (cfg.porEmpresa) {
      await pool.query(`DELETE FROM ${cfg.tabla} WHERE id = $1 AND empresa_id = $2`, [req.params.id, empresaId]);
    } else {
      await _deleteGlobal(cfg.tabla, req.params.id);
    }
    res.json({ status: 'ok' });
  } catch (err) {
    console.error(`DELETE /api/maestros/${req.params.coleccion}/${req.params.id}:`, err);
    const msg = fkViolation(err);
    if (msg) return res.status(409).json({ error: msg });
    res.status(500).json({ error: 'Error interno del servidor' });
  }
});

// ─────────────────────────────────────────────────────────────────────────────
// POST   /api/locks/:tabla/:id   — tomar (o renovar) el lock de un registro
// DELETE /api/locks/:tabla/:id   — liberar el lock (solo el dueño; idempotente)
// ─────────────────────────────────────────────────────────────────────────────
app.post('/api/locks/:tabla/:id', async (req, res) => {
  try {
    const sesion = await obtenerSesion(req);
    if (!sesion) return res.status(401).json({ error: 'No autenticado' });
    const { tabla, id } = req.params;
    const empresaId = (req.body && req.body.empresaId) || null;
    if (empresaId) {
      const permiso = await obtenerPermiso(req, empresaId);
      if (!permiso) return res.status(403).json({ error: 'Sin acceso a esta empresa' });
    }
    const r = await pool.query(
      `INSERT INTO registro_locks (tabla, registro_id, empresa_id, usuario_id, bloqueado_en)
       VALUES ($1, $2, $3, $4, NOW())
       ON CONFLICT (tabla, registro_id) DO UPDATE
         SET usuario_id = $4, empresa_id = $3, bloqueado_en = NOW()
         WHERE registro_locks.usuario_id = $4
            OR registro_locks.bloqueado_en < NOW() - ($5 || ' minutes')::interval
       RETURNING usuario_id`,
      [tabla, id, empresaId, sesion.id, String(LOCK_TIMEOUT_MINUTES)]
    );
    if (r.rows.length) return res.json({ status: 'ok' });
    // No se pudo tomar: está en manos de otro usuario y sigue vigente.
    const info = await pool.query(
      `SELECT u.nombre AS "nombre", rl.bloqueado_en AS "desde"
         FROM registro_locks rl JOIN usuarios u ON u.id = rl.usuario_id
        WHERE rl.tabla = $1 AND rl.registro_id = $2`,
      [tabla, id]
    );
    const b = info.rows[0] || {};
    res.status(409).json({ error: 'Lo está editando ' + (b.nombre || 'otro usuario'), bloqueadoPor: b });
  } catch (err) {
    console.error('/api/locks POST error:', err);
    res.status(500).json({ error: 'Error interno del servidor' });
  }
});

app.delete('/api/locks/:tabla/:id', async (req, res) => {
  try {
    const sesion = await obtenerSesion(req);
    if (!sesion) return res.status(401).json({ error: 'No autenticado' });
    await pool.query(
      'DELETE FROM registro_locks WHERE tabla = $1 AND registro_id = $2 AND usuario_id = $3',
      [req.params.tabla, req.params.id, sesion.id]
    );
    res.json({ status: 'ok' });
  } catch (err) {
    console.error('/api/locks DELETE error:', err);
    res.status(500).json({ error: 'Error interno del servidor' });
  }
});

// ─────────────────────────────────────────────────────────────────────────────
// GET  /api/usuarios         — lista (admin_general: todos; admin_cliente: su cliente)
// POST /api/usuarios         — crear usuario
// PUT  /api/usuarios/:id     — actualizar usuario
// DELETE /api/usuarios/:id   — eliminar usuario + sus permisos en cascada
// ─────────────────────────────────────────────────────────────────────────────
app.get('/api/usuarios', async (req, res) => {
  const sesion = await obtenerSesion(req);
  if (!sesion) return res.status(401).json({ error: 'No autenticado' });
  try {
    if (sesion.rol === 'admin_general') {
      return res.json((await pool.query(
        'SELECT id, nombre, email, rol, cliente_id AS "clienteId", activo, herramientas_internas AS "herramientasInternas", usuario_interno AS "usuarioInterno" FROM usuarios ORDER BY nombre'
      )).rows);
    }
    if (sesion.rol === 'admin_cliente') {
      // Solo 'usuario' de su cliente: ya no gestiona otros admin_cliente (docs/Roles y permisos.txt).
      return res.json((await pool.query(
        `SELECT id, nombre, email, rol, cliente_id AS "clienteId", activo, herramientas_internas AS "herramientasInternas", usuario_interno AS "usuarioInterno"
           FROM usuarios WHERE cliente_id = $1 AND rol = 'usuario' ORDER BY nombre`,
        [sesion.cliente_id]
      )).rows);
    }
    // 'usuario' administrador de empresa: ve TODOS los 'usuario' de su mismo
    // cliente (igual que admin_cliente) — no solo los que ya tienen una fila en
    // permisos, si no un usuario recién creado (sin permiso asignado todavía)
    // no aparecería ni en la lista ni en el selector de "Asignar/editar permiso".
    // Sin ninguna empresa administrada, sin acceso a esta pantalla.
    const empresas = await empresasQueAdministraUsuario(sesion.id);
    if (!empresas.length) return res.status(403).json({ error: 'Sin permiso' });
    const r = await pool.query(
      `SELECT id, nombre, email, rol, cliente_id AS "clienteId", activo, herramientas_internas AS "herramientasInternas", usuario_interno AS "usuarioInterno"
         FROM usuarios WHERE cliente_id = $1 AND rol = 'usuario' ORDER BY nombre`,
      [sesion.cliente_id]
    );
    res.json(r.rows);
  } catch (err) { res.status(500).json({ error: 'Error interno del servidor' }); }
});

app.post('/api/usuarios', async (req, res) => {
  const sesion = await obtenerSesion(req);
  if (!sesion) return res.status(401).json({ error: 'No autenticado' });
  if (sesion.rol === 'usuario' && !(await empresasQueAdministraUsuario(sesion.id)).length) {
    return res.status(403).json({ error: 'Sin permiso' });
  }
  const { id, nombre, password, activo } = req.body || {};
  // Un 'usuario' administrador de empresa solo puede crear más 'usuario'
  // (nunca admin_cliente/admin_general — no delega su propio nivel).
  const rol = sesion.rol === 'usuario' ? 'usuario' : ((req.body || {}).rol || 'usuario');
  const email = (req.body && req.body.email) ? req.body.email.trim().toLowerCase() : req.body.email;
  if (!id || !nombre || !email) return res.status(400).json({ error: 'Faltan campos obligatorios (id, nombre, email)' });
  if (!password) return res.status(400).json({ error: 'La contraseña es obligatoria al crear un usuario' });
  if (!puedeAsignarRol(sesion, rol)) return res.status(403).json({ error: 'No podés crear un usuario con ese rol' });
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(email)) return res.status(400).json({ error: 'El email no tiene un formato válido' });
  // admin_cliente y 'usuario' administrador solo crean usuarios de su propio
  // cliente: se ignora cualquier clienteId que venga en el body y se fuerza el propio.
  const clienteId = (sesion.rol === 'admin_cliente' || sesion.rol === 'usuario')
    ? sesion.cliente_id
    : ((req.body || {}).clienteId || null);
  if (rol !== 'admin_general' && !clienteId) {
    return res.status(400).json({ error: 'Los usuarios con rol usuario o admin_cliente necesitan un cliente asociado' });
  }
  // Herramientas Puntal / Usuario interno: solo admin_general los otorga, igual que al editar.
  // Herramientas Puntal requiere ser Usuario interno: nunca puede quedar en
  // true si usuarioInterno no lo está (se valida acá, no solo en la UI).
  const usuarioInterno = sesion.rol === 'admin_general' && !!(req.body || {}).usuarioInterno;
  const herramientasInternas = sesion.rol === 'admin_general' && !!(req.body || {}).herramientasInternas && usuarioInterno;
  try {
    const hash = password ? await hashearPassword(password) : null;
    await pool.query(
      `INSERT INTO usuarios (id, nombre, email, rol, cliente_id, activo, password_hash, herramientas_internas, usuario_interno)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
       ON CONFLICT (id) DO UPDATE SET nombre=$2, email=$3, rol=$4, cliente_id=$5, activo=$6,
         password_hash = CASE WHEN $7::text IS NULL THEN usuarios.password_hash ELSE $7::text END,
         herramientas_internas=$8, usuario_interno=$9`,
      [id, nombre, email, rol, clienteId, activo !== false, hash, herramientasInternas, usuarioInterno]
    );
    res.status(201).json({ ...req.body, rol, clienteId, email, herramientasInternas, usuarioInterno });
  } catch (err) {
    const msg = uniqueViolation(err);
    if (msg) return res.status(409).json({ error: msg });
    res.status(500).json({ error: 'Error interno del servidor' });
  }
});

// Cualquier usuario logueado, sin importar el rol, cambia SU PROPIA
// contraseña — siempre actúa sobre sesion.id, nunca sobre un :id de la URL,
// así que no hace falta ningún chequeo de permiso adicional (no se puede
// apuntar a otra cuenta). A diferencia del admin reseteándole la contraseña
// a otro usuario, acá SÍ se exige la contraseña actual (es autoservicio, no
// una acción de un admin de confianza) — debe ir antes de /api/usuarios/:id
// en el archivo: si no, Express interpretaría "me" como el :id.
app.put('/api/usuarios/me/password', async (req, res) => {
  try {
    const sesion = await obtenerSesion(req);
    if (!sesion) return res.status(401).json({ error: 'No autenticado' });
    const { passwordActual, password } = req.body || {};
    if (!passwordActual) return res.status(400).json({ error: 'Ingresá tu contraseña actual' });
    if (!password) return res.status(400).json({ error: 'Ingresá la nueva contraseña' });
    const r = await pool.query('SELECT password_hash FROM usuarios WHERE id = $1', [sesion.id]);
    if (!r.rows.length) return res.status(404).json({ error: 'Usuario no encontrado' });
    const ok = await verificarPassword(passwordActual, r.rows[0].password_hash);
    if (!ok) return res.status(400).json({ error: 'La contraseña actual no es correcta' });
    const hash = await hashearPassword(password);
    await pool.query('UPDATE usuarios SET password_hash = $2 WHERE id = $1', [sesion.id, hash]);
    res.json({ status: 'ok' });
  } catch (err) {
    console.error('PUT /api/usuarios/me/password error:', err);
    res.status(500).json({ error: 'Error interno del servidor' });
  }
});

app.put('/api/usuarios/:id', async (req, res) => {
  const sesion = await obtenerSesion(req);
  if (!sesion) return res.status(401).json({ error: 'No autenticado' });
  // Un 'usuario' administrador de empresa SÍ puede tocar su propia cuenta desde
  // este endpoint, pero SOLO para cambiar su contraseña — nombre, email, rol,
  // activo y clienteId quedan forzados a como ya estaban, sin importar el body
  // (ver más abajo). admin_cliente/admin_general no llegan a esta excepción
  // (puedeSobreUsuario sigue rechazando admin_cliente sobre sí mismo;
  // admin_general no la necesita, ya tiene acceso total). Para que cualquier
  // rol pueda cambiar SU PROPIA contraseña sin tocar el resto de su perfil,
  // ver PUT /api/usuarios/me/password — un endpoint aparte, para no mezclar
  // ese caso con este (acá un body "solo password" de admin_general pisaría
  // su rol por el default de abajo).
  const esAutoedicionDeUsuario = req.params.id === sesion.id && sesion.rol === 'usuario';
  if (!esAutoedicionDeUsuario && !(await puedeSobreUsuario(sesion, req.params.id))) {
    return res.status(403).json({ error: 'No podés modificar este usuario' });
  }

  if (esAutoedicionDeUsuario) {
    const { password } = req.body || {};
    if (!password) return res.status(400).json({ error: 'Ingresá la nueva contraseña' });
    const bloqueo = await verificarLockPropio('usuarios', req.params.id, sesion);
    if (bloqueo) return res.status(409).json({ error: 'Lo está editando ' + bloqueo.usuarioNombre });
    try {
      const hash = await hashearPassword(password);
      await pool.query('UPDATE usuarios SET password_hash = $2 WHERE id = $1', [req.params.id, hash]);
      return res.json({ id: req.params.id, status: 'ok' });
    } catch (err) {
      return res.status(500).json({ error: 'Error interno del servidor' });
    }
  }

  const rol = (req.body || {}).rol || 'usuario';
  if (!puedeAsignarRol(sesion, rol)) return res.status(403).json({ error: 'No podés asignar ese rol' });
  const email = (req.body && req.body.email) ? req.body.email.trim().toLowerCase() : req.body.email;
  if (email && !/^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(email)) return res.status(400).json({ error: 'El email no tiene un formato válido' });
  const bloqueo = await verificarLockPropio('usuarios', req.params.id, sesion);
  if (bloqueo) return res.status(409).json({ error: 'Lo está editando ' + bloqueo.usuarioNombre });
  const { nombre, password, activo } = req.body || {};
  // admin_cliente y 'usuario' administrador no pueden reasignar el usuario a otro cliente.
  const clienteId = (sesion.rol === 'admin_cliente' || sesion.rol === 'usuario')
    ? sesion.cliente_id
    : ((req.body || {}).clienteId || null);
  if (rol !== 'admin_general' && !clienteId) {
    return res.status(400).json({ error: 'Los usuarios con rol usuario o admin_cliente necesitan un cliente asociado' });
  }
  // Herramientas Puntal: solo admin_general lo otorga, y solo si el frontend
  // mandó el campo (el formulario lo omite si quien edita no es admin_general
  // o si ni se mostró el control) — si no vino, la fila CASE deja el valor
  // actual sin tocar, en vez de asumir "false" y desactivarlo por accidente.
  const herramientasInternas = (sesion.rol === 'admin_general' && typeof (req.body || {}).herramientasInternas === 'boolean')
    ? req.body.herramientasInternas
    : null;
  const usuarioInterno = (sesion.rol === 'admin_general' && typeof (req.body || {}).usuarioInterno === 'boolean')
    ? req.body.usuarioInterno
    : null;
  try {
    const hash = password ? await hashearPassword(password) : null;
    await pool.query(
      // Herramientas Puntal requiere Usuario interno: el valor final de
      // herramientas_internas se combina con el valor final (nuevo o
      // existente) de usuario_interno, nunca puede quedar en true solo.
      `UPDATE usuarios SET nombre=$2, email=$3, rol=$4, cliente_id=$5, activo=$6,
         password_hash = CASE WHEN $7::text IS NULL THEN password_hash ELSE $7::text END,
         herramientas_internas = (CASE WHEN $8::boolean IS NULL THEN herramientas_internas ELSE $8::boolean END)
                                  AND (CASE WHEN $9::boolean IS NULL THEN usuario_interno ELSE $9::boolean END),
         usuario_interno = CASE WHEN $9::boolean IS NULL THEN usuario_interno ELSE $9::boolean END
       WHERE id=$1`,
      [req.params.id, nombre, email, rol, clienteId, activo !== false, hash, herramientasInternas, usuarioInterno]
    );
    res.json({ ...req.body, id: req.params.id, rol, clienteId, email });
  } catch (err) {
    const msg = uniqueViolation(err);
    if (msg) return res.status(409).json({ error: msg });
    console.error('/api/usuarios PUT error:', err);
    res.status(500).json({ error: 'Error interno del servidor' });
  }
});

app.delete('/api/usuarios/:id', async (req, res) => {
  const sesion = await obtenerSesion(req);
  if (!sesion) return res.status(401).json({ error: 'No autenticado' });
  if (req.params.id === sesion.id) return res.status(403).json({ error: 'No podés borrarte a vos mismo' });
  if (!(await puedeSobreUsuario(sesion, req.params.id))) {
    return res.status(403).json({ error: 'No podés borrar este usuario' });
  }
  const bloqueo = await verificarLockPropio('usuarios', req.params.id, sesion);
  if (bloqueo) return res.status(409).json({ error: 'Lo está editando ' + bloqueo.usuarioNombre });
  try {
    await pool.query('DELETE FROM permisos WHERE usuario_id = $1', [req.params.id]);
    await pool.query('DELETE FROM usuarios WHERE id = $1', [req.params.id]);
    res.json({ status: 'ok' });
  } catch (err) { res.status(500).json({ error: 'Error interno del servidor' }); }
});

// ─────────────────────────────────────────────────────────────────────────────
// GET  /api/permisos                          — lista (filtrado por rol)
// POST /api/permisos                          — upsert permiso {usuarioId, empresaId, …}
// DELETE /api/permisos/:usuarioId/:empresaId  — eliminar permiso
// ─────────────────────────────────────────────────────────────────────────────
app.get('/api/permisos', async (req, res) => {
  const sesion = await obtenerSesion(req);
  if (!sesion) return res.status(401).json({ error: 'No autenticado' });
  try {
    if (sesion.rol === 'admin_general') {
      return res.json((await pool.query(
        'SELECT usuario_id AS "usuarioId", empresa_id AS "empresaId", campo_ids AS "campoIds", herramientas, nivel FROM permisos'
      )).rows);
    }
    if (sesion.rol === 'admin_cliente') {
      return res.json((await pool.query(
        `SELECT p.usuario_id AS "usuarioId", p.empresa_id AS "empresaId", p.campo_ids AS "campoIds", p.herramientas, p.nivel
           FROM permisos p JOIN usuarios u ON u.id = p.usuario_id
          WHERE u.cliente_id = $1`,
        [sesion.cliente_id]
      )).rows);
    }
    // 'usuario' administrador de empresa: solo ve los permisos de las empresas que administra.
    const empresas = await empresasQueAdministraUsuario(sesion.id);
    if (!empresas.length) return res.status(403).json({ error: 'Sin permiso' });
    const r = await pool.query(
      `SELECT usuario_id AS "usuarioId", empresa_id AS "empresaId", campo_ids AS "campoIds", herramientas, nivel
         FROM permisos WHERE empresa_id = ANY($1)`,
      [empresas]
    );
    res.json(r.rows);
  } catch (err) { res.status(500).json({ error: 'Error interno del servidor' }); }
});

app.post('/api/permisos', async (req, res) => {
  const sesion = await obtenerSesion(req);
  if (!sesion) return res.status(401).json({ error: 'No autenticado' });
  const { usuarioId, empresaId, campoIds, herramientas, nivel } = req.body || {};
  if (!usuarioId || !empresaId) return res.status(400).json({ error: 'Faltan usuarioId o empresaId' });

  if (!(await puedeSobreUsuario(sesion, usuarioId))) {
    return res.status(403).json({ error: 'No podés asignar permisos a este usuario' });
  }
  // admin_general y admin_cliente ya tienen acceso pleno por su rol — una fila
  // en `permisos` solo tiene sentido (y efecto) para el rol 'usuario'.
  if ((await rolDeUsuario(usuarioId)) !== 'usuario') {
    return res.status(400).json({ error: 'Este usuario ya administra todo su alcance por su rol; no necesita un permiso por empresa' });
  }
  if (!(await puedeAdministrarEmpresa(sesion, empresaId))) {
    return res.status(403).json({ error: 'No podés asignar permisos sobre esta empresa' });
  }
  const nivelFinal = nivel || 'ver';
  // Un 'usuario' administrador de empresa puede delegar nivel='administrar' a
  // otro 'usuario' de la misma empresa que administra (co-administradores) —
  // puedeAdministrarEmpresa() ya validó arriba que esta empresa es una de las
  // que administra; no hace falta ningún techo adicional de nivel acá.
  // nivel='administrar' implica acceso a TODOS los campos y herramientas de la
  // empresa (docs/Roles y permisos.txt) — se ignoran restricciones parciales.
  const campoIdsFinal = nivelFinal === 'administrar' ? [] : (campoIds || []);
  const herramientasFinal = nivelFinal === 'administrar' ? [] : (herramientas || []);

  const bloqueo = await verificarLockPropio('permisos', usuarioId + '_' + empresaId, sesion);
  if (bloqueo) return res.status(409).json({ error: 'Lo está editando ' + bloqueo.usuarioNombre });
  try {
    await pool.query(
      `INSERT INTO permisos (usuario_id, empresa_id, campo_ids, herramientas, nivel)
       VALUES ($1, $2, $3, $4, $5)
       ON CONFLICT (usuario_id, empresa_id) DO UPDATE
         SET campo_ids=$3, herramientas=$4, nivel=$5`,
      [usuarioId, empresaId, campoIdsFinal, herramientasFinal, nivelFinal]
    );
    res.status(201).json({ usuarioId, empresaId, campoIds: campoIdsFinal, herramientas: herramientasFinal, nivel: nivelFinal });
  } catch (err) { res.status(500).json({ error: 'Error interno del servidor' }); }
});

app.delete('/api/permisos/:usuarioId/:empresaId', async (req, res) => {
  const sesion = await obtenerSesion(req);
  if (!sesion) return res.status(401).json({ error: 'No autenticado' });
  if (!(await puedeSobreUsuario(sesion, req.params.usuarioId))) {
    return res.status(403).json({ error: 'No podés modificar los permisos de este usuario' });
  }
  if (!(await puedeAdministrarEmpresa(sesion, req.params.empresaId))) {
    return res.status(403).json({ error: 'No podés modificar permisos sobre esta empresa' });
  }
  const bloqueo = await verificarLockPropio('permisos', req.params.usuarioId + '_' + req.params.empresaId, sesion);
  if (bloqueo) return res.status(409).json({ error: 'Lo está editando ' + bloqueo.usuarioNombre });
  try {
    await pool.query(
      'DELETE FROM permisos WHERE usuario_id = $1 AND empresa_id = $2',
      [req.params.usuarioId, req.params.empresaId]
    );
    res.json({ status: 'ok' });
  } catch (err) { res.status(500).json({ error: 'Error interno del servidor' }); }
});

// ─────────────────────────────────────────────────────────────────────────────
// Helpers para tablas globales (columnas propias, no JSONB)
// ─────────────────────────────────────────────────────────────────────────────
async function _upsertGlobal(tabla, obj) {
  if (tabla === 'labores') {
    await pool.query(
      `INSERT INTO labores (id, nombre, unidad_labor, precio_ref, activo)
       VALUES ($1, $2, $3, $4, $5)
       ON CONFLICT (id) DO UPDATE SET nombre = $2, unidad_labor = $3, precio_ref = $4, activo = $5`,
      [obj.id, obj.nombre, obj.unidadLabor || null, obj.precioRef || 0, obj.activo !== false]
    );
  } else if (tabla === 'especies') {
    await pool.query(
      `INSERT INTO especies (id, nombre, sigla, activo)
       VALUES ($1, $2, $3, $4)
       ON CONFLICT (id) DO UPDATE SET nombre = $2, sigla = $3, activo = $4`,
      [obj.id, obj.nombre, obj.sigla || null, obj.activo !== false]
    );
  } else if (tabla === 'unidades') {
    await pool.query(
      `INSERT INTO unidades (id, sigla, nombre, activo)
       VALUES ($1, $2, $3, $4)
       ON CONFLICT (id) DO UPDATE SET sigla = $2, nombre = $3, activo = $4`,
      [obj.id, obj.sigla, obj.nombre || null, obj.activo !== false]
    );
  } else if (tabla === 'modos_accion') {
    await pool.query(
      `INSERT INTO modos_accion (id, sistema, codigo, descripcion, activo)
       VALUES ($1, $2, $3, $4, $5)
       ON CONFLICT (id) DO UPDATE SET sistema = $2, codigo = $3, descripcion = $4, activo = $5`,
      [obj.id, obj.sistema, obj.codigo, obj.descripcion || null, obj.activo !== false]
    );
  } else if (tabla === 'tipos_proveedor') {
    await pool.query(
      `INSERT INTO tipos_proveedor (id, nombre)
       VALUES ($1, $2)
       ON CONFLICT (id) DO UPDATE SET nombre = $2`,
      [obj.id, obj.nombre]
    );
  } else if (tabla === 'campanias') {
    await pool.query(
      `INSERT INTO campanias (id, nombre, orden, activa)
       VALUES ($1, $2, $3, $4)
       ON CONFLICT (id) DO UPDATE SET nombre=$2, orden=$3, activa=$4`,
      [obj.id, obj.nombre, obj.orden || 0, obj.activa || false]
    );
  } else if (tabla === 'categorias_insumo') {
    await pool.query(
      `INSERT INTO categorias_insumo (id, codigo, label, base, fito, subcat, activo)
       VALUES ($1, $2, $3, $4, $5, $6, $7)
       ON CONFLICT (id) DO UPDATE SET codigo=$2, label=$3, base=$4, fito=$5, subcat=$6, activo=$7`,
      [obj.id, obj.codigo, obj.label, obj.base || false, obj.fito || false, obj.subcat || false, obj.activo !== false]
    );
  } else if (tabla === 'usos_actividad') {
    await pool.query(
      `INSERT INTO usos_actividad (id, codigo, label, color, activo)
       VALUES ($1, $2, $3, $4, $5)
       ON CONFLICT (id) DO UPDATE SET codigo=$2, label=$3, color=$4, activo=$5`,
      [obj.id, obj.codigo, obj.label, obj.color || null, obj.activo !== false]
    );
  } else if (tabla === 'tenencias') {
    await pool.query(
      `INSERT INTO tenencias (id, nombre, activo)
       VALUES ($1, $2, $3)
       ON CONFLICT (id) DO UPDATE SET nombre=$2, activo=$3`,
      [obj.id, obj.nombre, obj.activo !== false]
    );
  } else if (tabla === 'formulaciones') {
    await pool.query(
      `INSERT INTO formulaciones (id, codigo, descripcion, orden, activo)
       VALUES ($1, $2, $3, $4, $5)
       ON CONFLICT (id) DO UPDATE SET codigo=$2, descripcion=$3, orden=$4, activo=$5`,
      [obj.id, obj.codigo || null, obj.descripcion, obj.orden || 0, obj.activo !== false]
    );
  } else if (tabla === 'principios_activos') {
    await pool.query(
      `INSERT INTO principios_activos (id, nombre, eiq, uso, activo)
       VALUES ($1, $2, $3, $4, $5)
       ON CONFLICT (id) DO UPDATE SET nombre=$2, eiq=$3, uso=$4, activo=$5`,
      [obj.id, obj.nombre, obj.eiq != null ? obj.eiq : null, obj.uso || null, obj.activo !== false]
    );
  } else if (tabla === 'cultivos_default') {
    await pool.query(
      `INSERT INTO cultivos_default (id, sigla, nombre, es_cultivo, actividad, especie_id, graminea, default2da, activo)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
       ON CONFLICT (id) DO UPDATE
         SET sigla=$2, nombre=$3, es_cultivo=$4, actividad=$5, especie_id=$6, graminea=$7, default2da=$8, activo=$9`,
      [obj.id, obj.sigla, obj.nombre, obj.esCultivo !== false, obj.actividad || null,
       obj.especieId || null, obj.graminea == null ? null : !!obj.graminea, !!obj.default2da, obj.activo !== false]
    );
  }
}

async function _deleteGlobal(tabla, id) {
  const tablas = ['labores','especies','unidades','modos_accion','tipos_proveedor','campanias',
                  'categorias_insumo','usos_actividad','tenencias','formulaciones','principios_activos',
                  'cultivos_default'];
  if (tablas.indexOf(tabla) < 0) throw new Error('Tabla no permitida: ' + tabla);
  await pool.query(`DELETE FROM ${tabla} WHERE id = $1`, [id]);
}

// ─────────────────────────────────────────────────────────────────────────────
// CRUD: /api/clientes  /api/empresas  /api/campos
// ─────────────────────────────────────────────────────────────────────────────

function cuitSoloDigitos(s) { return String(s == null ? '' : s).replace(/\D/g, ''); }

// CUIT argentino: 11 dígitos + dígito verificador módulo 11.
function cuitValido(digitos) {
  if (!/^\d{11}$/.test(digitos)) return false;
  const mult = [5, 4, 3, 2, 7, 6, 5, 4, 3, 2];
  let suma = 0;
  for (let i = 0; i < 10; i++) suma += parseInt(digitos.charAt(i), 10) * mult[i];
  let dv = 11 - (suma % 11);
  if (dv === 11) dv = 0; else if (dv === 10) dv = 9;
  return dv === parseInt(digitos.charAt(10), 10);
}

// Valida el CUIT nuevo solo si vino y cambió respecto al guardado — así no se
// bloquea la edición de un registro con un CUIT de seed/legacy inválido.
function errorCuitSiCambio(cuitNuevo, cuitOriginal) {
  if (!cuitNuevo) return null;
  const nuevo = cuitSoloDigitos(cuitNuevo);
  if (cuitOriginal && cuitSoloDigitos(cuitOriginal) === nuevo) return null;
  if (nuevo.length !== 11) return 'El CUIT debe tener 11 dígitos';
  if (!cuitValido(nuevo)) return 'El dígito verificador del CUIT no es válido';
  return null;
}

function emailValido(email) { return /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(email); }

// Devuelve el cliente_id de una empresa (para validar pertenencia).
async function clienteDeEmpresa(empresaId) {
  const r = await pool.query('SELECT cliente_id FROM empresas WHERE id = $1', [empresaId]);
  return r.rows.length ? r.rows[0].cliente_id : null;
}
// Devuelve el cliente_id de un campo (vía su empresa).
async function clienteDeCampo(campoId) {
  const r = await pool.query(
    'SELECT e.cliente_id FROM campos c JOIN empresas e ON e.id = c.empresa_id WHERE c.id = $1',
    [campoId]
  );
  return r.rows.length ? r.rows[0].cliente_id : null;
}

// ─────────────────────────────────────────────────────────────────────────────
// DELEGACIÓN DE PERMISOS (ver docs/Roles y permisos.txt — fuente de verdad)
// - admin_general: sin techo, sobre cualquier cliente/empresa/usuario.
// - admin_cliente: acceso administrar sobre TODAS las empresas de su propio
//   cliente (sin necesidad de una fila propia en `permisos` — ver obtenerPermiso());
//   puede crear/gestionar 'usuario' y 'admin_cliente', nunca 'admin_general';
//   nunca toca un usuario admin_general; no ve ni asigna permisos fuera de su cliente.
// - usuario con nivel='administrar' en una empresa ("administrador de esa
//   Empresa"): puede crear/gestionar MÁS usuarios 'usuario' (nunca admin_cliente
//   ni admin_general) para esa empresa puntual, y solo asignarles nivel ver o
//   cargar (nunca administrar). Un 'usuario' sin ninguna fila nivel='administrar'
//   sigue sin acceso a esta pantalla ni a /api/usuarios ni a /api/permisos.
// ─────────────────────────────────────────────────────────────────────────────

async function clienteDeUsuario(usuarioId) {
  const r = await pool.query('SELECT cliente_id FROM usuarios WHERE id = $1', [usuarioId]);
  return r.rows.length ? r.rows[0].cliente_id : null;
}

async function rolDeUsuario(usuarioId) {
  const r = await pool.query('SELECT rol FROM usuarios WHERE id = $1', [usuarioId]);
  return r.rows.length ? r.rows[0].rol : null;
}

// Empresas donde este usuario (rol 'usuario') tiene nivel='administrar' — lo
// habilita a delegar ver/cargar en esa empresa puntual (docs/Roles y permisos.txt).
async function empresasQueAdministraUsuario(usuarioId) {
  const r = await pool.query(
    `SELECT empresa_id AS "empresaId" FROM permisos WHERE usuario_id = $1 AND nivel = 'administrar'`,
    [usuarioId]
  );
  return r.rows.map(function (row) { return row.empresaId; });
}

// ¿Puede 'sesion' administrar permisos sobre esta empresa puntual?
// admin_general: siempre. admin_cliente: si la empresa es de su cliente.
// usuario: solo si tiene nivel='administrar' en esa empresa específica.
async function puedeAdministrarEmpresa(sesion, empresaId) {
  if (sesion.rol === 'admin_general') return true;
  if (sesion.rol === 'admin_cliente') return (await clienteDeEmpresa(empresaId)) === sesion.cliente_id;
  if (sesion.rol === 'usuario') return (await empresasQueAdministraUsuario(sesion.id)).indexOf(empresaId) >= 0;
  return false;
}

// admin_cliente puede crear/reasignar 'usuario' o 'admin_cliente', nunca 'admin_general'.
// Un 'usuario' administrador de empresa solo puede crear/reasignar 'usuario' (nunca
// admin_cliente/admin_general — no delega su propio nivel de administración).
function puedeAsignarRol(sesion, rolDestino) {
  if (sesion.rol === 'admin_general') return true;
  // admin_cliente solo crea/reasigna 'usuario' — nunca admin_cliente ni admin_general.
  // El único que da de alta un admin_cliente es admin_general (docs/Roles y permisos.txt).
  if (sesion.rol === 'admin_cliente') return rolDestino === 'usuario';
  if (sesion.rol === 'usuario') return rolDestino === 'usuario';
  return false;
}

// ¿Puede este otorgante gestionar (editar/borrar/asignarle permisos a) este usuario?
// admin_cliente: solo usuarios de su propio cliente, y nunca un admin_general.
// usuario administrador de empresa: solo usuarios 'usuario' de su mismo cliente
// (el recorte a "esta empresa puntual" para permisos lo hace puedeAdministrarEmpresa).
async function puedeSobreUsuario(sesion, usuarioId) {
  if (sesion.rol === 'admin_general') return true;
  if (sesion.rol === 'admin_cliente') {
    // admin_cliente solo gestiona 'usuario' de su propio cliente — nunca a otro
    // admin_cliente (ni a admin_general, ya cubierto por no ser 'usuario'), y
    // nunca a sí mismo (evita autoeditarse el rol/permiso; explícito aunque hoy
    // ya es imposible en la práctica porque su propio rol nunca es 'usuario').
    if (usuarioId === sesion.id) return false;
    const rolDestino = await rolDeUsuario(usuarioId);
    if (rolDestino !== 'usuario') return false;
    const clienteDestino = await clienteDeUsuario(usuarioId);
    return clienteDestino === sesion.cliente_id;
  }
  if (sesion.rol === 'usuario') {
    // Un 'usuario' administrador de empresa nunca administra su PROPIA cuenta ni
    // su propio permiso — si pudiera, se autoasignaría/quitaría acceso a mano
    // (el mismo criterio que admin_cliente, que estructuralmente nunca se
    // administra a sí mismo porque su rol nunca es 'usuario').
    if (usuarioId === sesion.id) return false;
    const rolDestino = await rolDeUsuario(usuarioId);
    if (rolDestino !== 'usuario') return false;
    const clienteDestino = await clienteDeUsuario(usuarioId);
    return clienteDestino === sesion.cliente_id;
  }
  return false;
}

app.get('/api/clientes', async (req, res) => {
  const sesion = await obtenerSesion(req);
  if (!sesion) return res.status(401).json({ error: 'No autenticado' });
  if (sesion.rol === 'usuario') return res.status(403).json({ error: 'Sin permiso' });
  try {
    // Acá solo llegan admin_general o admin_cliente ('usuario' está bloqueado
    // arriba). admin_cliente ve su propio cliente completo, sin depender de
    // ninguna fila en `permisos` (no la necesita, ver obtenerPermiso()).
    const q = sesion.rol === 'admin_general'
      ? pool.query(`SELECT id, nombre, email, telefono, nombre_contacto AS "nombreContacto",
                           razon_social AS "razonSocial", cuit, direccion,
                           factura_centralizada AS "facturaCentralizada",
                           activo, fecha_alta AS "fechaAlta" FROM clientes ORDER BY nombre`)
      : pool.query(
          `SELECT id, nombre, email, telefono, nombre_contacto AS "nombreContacto",
                  razon_social AS "razonSocial", cuit, direccion,
                  factura_centralizada AS "facturaCentralizada",
                  activo, fecha_alta AS "fechaAlta"
             FROM clientes WHERE id = $1 ORDER BY nombre`,
          [sesion.cliente_id]
        );
    res.json((await q).rows);
  } catch (err) { res.status(500).json({ error: 'Error interno del servidor' }); }
});

app.post('/api/clientes', async (req, res) => {
  const sesion = await obtenerSesion(req);
  if (!sesion) return res.status(401).json({ error: 'No autenticado' });
  // Solo admin_general puede crear clientes nuevos
  if (sesion.rol !== 'admin_general') return res.status(403).json({ error: 'Sin permiso' });
  const c = req.body;
  if (!c.id || !c.nombre) return res.status(400).json({ error: 'Faltan id o nombre' });
  const errCuit = errorCuitSiCambio(c.cuit, null);
  if (errCuit) return res.status(400).json({ error: errCuit });
  if (c.email && !emailValido(c.email)) return res.status(400).json({ error: 'El email no tiene un formato válido' });
  try {
    await pool.query(
      `INSERT INTO clientes (id, nombre, email, telefono, nombre_contacto, razon_social, cuit,
                             direccion, factura_centralizada, activo, fecha_alta)
       VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)
       ON CONFLICT (id) DO UPDATE
         SET nombre=$2, email=$3, telefono=$4, nombre_contacto=$5, razon_social=$6,
             cuit=$7, direccion=$8, factura_centralizada=$9, activo=$10`,
      [c.id, c.nombre, c.email||null, c.telefono||null, c.nombreContacto||null,
       c.razonSocial||null, c.cuit||null, c.direccion||null,
       c.facturaCentralizada !== false, c.activo !== false,
       c.fechaAlta || new Date().toISOString().slice(0,10)]
    );
    res.status(201).json(c);
  } catch (err) {
    const msg = uniqueViolation(err);
    if (msg) return res.status(409).json({ error: msg });
    res.status(500).json({ error: 'Error interno del servidor' });
  }
});

app.put('/api/clientes/:id', async (req, res) => {
  const sesion = await obtenerSesion(req);
  if (!sesion) return res.status(401).json({ error: 'No autenticado' });
  if (sesion.rol === 'usuario') return res.status(403).json({ error: 'Sin permiso' });
  // admin_cliente solo puede editar su propio cliente
  if (sesion.rol === 'admin_cliente' && sesion.cliente_id !== req.params.id)
    return res.status(403).json({ error: 'Sin permiso sobre este cliente' });
  const bloqueoC = await verificarLockPropio('clientes', req.params.id, sesion);
  if (bloqueoC) return res.status(409).json({ error: 'Lo está editando ' + bloqueoC.usuarioNombre });
  const c = { ...req.body, id: req.params.id };
  if (c.email && !emailValido(c.email)) return res.status(400).json({ error: 'El email no tiene un formato válido' });
  try {
    const actual = await pool.query('SELECT cuit FROM clientes WHERE id = $1', [req.params.id]);
    const errCuit = errorCuitSiCambio(c.cuit, actual.rows[0] ? actual.rows[0].cuit : null);
    if (errCuit) return res.status(400).json({ error: errCuit });
    await pool.query(
      `UPDATE clientes SET nombre=$2, email=$3, telefono=$4, nombre_contacto=$5,
          razon_social=$6, cuit=$7, direccion=$8, factura_centralizada=$9, activo=$10
       WHERE id=$1`,
      [c.id, c.nombre, c.email||null, c.telefono||null, c.nombreContacto||null,
       c.razonSocial||null, c.cuit||null, c.direccion||null,
       c.facturaCentralizada !== false, c.activo !== false]
    );
    res.json(c);
  } catch (err) {
    const msg = uniqueViolation(err);
    if (msg) return res.status(409).json({ error: msg });
    res.status(500).json({ error: 'Error interno del servidor' });
  }
});

app.delete('/api/clientes/:id', async (req, res) => {
  const sesion = await obtenerSesion(req);
  if (!sesion) return res.status(401).json({ error: 'No autenticado' });
  if (sesion.rol !== 'admin_general') return res.status(403).json({ error: 'Sin permiso' });
  const bloqueo = await verificarLockPropio('clientes', req.params.id, sesion);
  if (bloqueo) return res.status(409).json({ error: 'Lo está editando ' + bloqueo.usuarioNombre });
  try {
    await pool.query('DELETE FROM clientes WHERE id=$1', [req.params.id]);
    res.json({ status: 'ok' });
  } catch (err) {
    const msg = fkViolation(err);
    if (msg) return res.status(409).json({ error: msg });
    console.error('DELETE /api/clientes/:id error:', err);
    res.status(500).json({ error: 'Error interno del servidor' });
  }
});

app.get('/api/empresas', async (req, res) => {
  const sesion = await obtenerSesion(req);
  if (!sesion) return res.status(401).json({ error: 'No autenticado' });
  try {
    // admin_general: todas. admin_cliente: todas las de su propio cliente (no
    // depende de ninguna fila en `permisos`). usuario: solo donde tiene permiso.
    const q = sesion.rol === 'admin_general'
      ? pool.query(`SELECT id, cliente_id AS "clienteId", razon_social AS "razonSocial", cuit,
                           condicion_iva AS "condicionIVA", direccion, activo FROM empresas ORDER BY razon_social`)
      : sesion.rol === 'admin_cliente'
      ? pool.query(
          `SELECT id, cliente_id AS "clienteId", razon_social AS "razonSocial", cuit,
                  condicion_iva AS "condicionIVA", direccion, activo
             FROM empresas WHERE cliente_id = $1 ORDER BY razon_social`,
          [sesion.cliente_id]
        )
      : pool.query(
          `SELECT e.id, e.cliente_id AS "clienteId", e.razon_social AS "razonSocial", e.cuit,
                  e.condicion_iva AS "condicionIVA", e.direccion, e.activo
             FROM empresas e JOIN permisos p ON p.empresa_id = e.id
            WHERE p.usuario_id = $1 ORDER BY e.razon_social`,
          [sesion.id]
        );
    res.json((await q).rows);
  } catch (err) { res.status(500).json({ error: 'Error interno del servidor' }); }
});

// Siembra el catálogo default de cultivos/usos del suelo (tabla global
// cultivos_default, editable en Maestros por admin_general) para una empresa
// recién creada — no rompe el alta si falla (empresa igual queda creada).
async function sembrarCultivosDefault(empresaId) {
  const r = await pool.query(
    `SELECT id, sigla, nombre, es_cultivo AS "esCultivo", actividad,
            especie_id AS "especieId", graminea, default2da
       FROM cultivos_default WHERE activo = true`
  );
  for (const c of r.rows) {
    const datos = {
      id: 'ta_' + empresaId + '_' + c.id, empresaId, nombre: c.nombre, sigla: c.sigla,
      esCultivo: c.esCultivo, actividad: c.actividad, especieId: c.especieId,
      graminea: c.graminea, default2da: c.default2da, activo: true,
    };
    await pool.query(
      `INSERT INTO tipos_actividad (id, empresa_id, datos) VALUES ($1, $2, $3::jsonb)
       ON CONFLICT (id, empresa_id) DO NOTHING`,
      [datos.id, empresaId, JSON.stringify(datos)]
    );
  }
}

app.post('/api/empresas', async (req, res) => {
  const sesion = await obtenerSesion(req);
  if (!sesion) return res.status(401).json({ error: 'No autenticado' });
  if (sesion.rol === 'usuario') return res.status(403).json({ error: 'Sin permiso' });
  const e = req.body;
  if (!e.id || !e.razonSocial || !e.clienteId) return res.status(400).json({ error: 'Faltan campos obligatorios' });
  if (sesion.rol === 'admin_cliente' && sesion.cliente_id !== e.clienteId)
    return res.status(403).json({ error: 'Sin permiso sobre ese cliente' });
  const errCuit = errorCuitSiCambio(e.cuit, null);
  if (errCuit) return res.status(400).json({ error: errCuit });
  try {
    await pool.query(
      `INSERT INTO empresas (id, cliente_id, razon_social, cuit, condicion_iva, direccion, activo)
       VALUES ($1,$2,$3,$4,$5,$6,$7)
       ON CONFLICT (id) DO UPDATE
         SET cliente_id=$2, razon_social=$3, cuit=$4, condicion_iva=$5, direccion=$6, activo=$7`,
      [e.id, e.clienteId, e.razonSocial, e.cuit||null, e.condicionIVA||null,
       e.direccion||null, e.activo !== false]
    );
    try {
      await sembrarCultivosDefault(e.id);
    } catch (errSeed) {
      console.error('Error sembrando cultivos default para empresa nueva:', errSeed);
    }
    res.status(201).json(e);
  } catch (err) {
    const msg = uniqueViolation(err);
    if (msg) return res.status(409).json({ error: msg });
    res.status(500).json({ error: 'Error interno del servidor' });
  }
});

app.put('/api/empresas/:id', async (req, res) => {
  const sesion = await obtenerSesion(req);
  if (!sesion) return res.status(401).json({ error: 'No autenticado' });
  if (sesion.rol === 'usuario') return res.status(403).json({ error: 'Sin permiso' });
  const e = { ...req.body, id: req.params.id };
  try {
    if (sesion.rol === 'admin_cliente') {
      const cid = await clienteDeEmpresa(req.params.id);
      if (cid !== sesion.cliente_id) return res.status(403).json({ error: 'Sin permiso sobre esa empresa' });
    }
    const bloqueo = await verificarLockPropio('empresas', req.params.id, sesion);
    if (bloqueo) return res.status(409).json({ error: 'Lo está editando ' + bloqueo.usuarioNombre });
    const actual = await pool.query('SELECT cuit FROM empresas WHERE id = $1', [req.params.id]);
    const errCuit = errorCuitSiCambio(e.cuit, actual.rows[0] ? actual.rows[0].cuit : null);
    if (errCuit) return res.status(400).json({ error: errCuit });
    await pool.query(
      `UPDATE empresas SET razon_social=$2, cuit=$3, condicion_iva=$4, direccion=$5, activo=$6
       WHERE id=$1`,
      [e.id, e.razonSocial, e.cuit||null, e.condicionIVA||null, e.direccion||null, e.activo !== false]
    );
    res.json(e);
  } catch (err) {
    const msg = uniqueViolation(err);
    if (msg) return res.status(409).json({ error: msg });
    res.status(500).json({ error: 'Error interno del servidor' });
  }
});

app.delete('/api/empresas/:id', async (req, res) => {
  const sesion = await obtenerSesion(req);
  if (!sesion) return res.status(401).json({ error: 'No autenticado' });
  if (sesion.rol === 'usuario') return res.status(403).json({ error: 'Sin permiso' });
  try {
    if (sesion.rol === 'admin_cliente') {
      const cid = await clienteDeEmpresa(req.params.id);
      if (cid !== sesion.cliente_id) return res.status(403).json({ error: 'Sin permiso sobre esa empresa' });
    }
    const bloqueo = await verificarLockPropio('empresas', req.params.id, sesion);
    if (bloqueo) return res.status(409).json({ error: 'Lo está editando ' + bloqueo.usuarioNombre });
    await pool.query('DELETE FROM empresas WHERE id=$1', [req.params.id]);
    res.json({ status: 'ok' });
  } catch (err) { res.status(500).json({ error: 'Error interno del servidor' }); }
});

// ─────────────────────────────────────────────────────────────────────────────
// MAPA DE LOTES (KML/KMZ cargado en el Plan de Uso del Suelo)
// Reemplaza el mapa de UN campo entero: los lotes del campo que no vienen en el
// pedido quedan sin mapa. lote.geo = [{id, nombre, ha, ring:[[lat,lng],…]}]; un
// polígono puede estar en varios lotes (mismo id) y un lote tener varios.
// Mismo permiso que editar lotes en el Plan de Uso, más el campo habilitado.
// ─────────────────────────────────────────────────────────────────────────────
function normalizarGeoLote(geo) {
  if (geo == null) return null;
  if (!Array.isArray(geo)) throw new Error('geo inválido');
  const out = [];
  for (const g of geo) {
    if (!g || !Array.isArray(g.ring) || g.ring.length < 3) throw new Error('polígono inválido');
    const ring = g.ring.map(p => {
      const lat = Number(p && p[0]), lng = Number(p && p[1]);
      if (!isFinite(lat) || !isFinite(lng) || Math.abs(lat) > 90 || Math.abs(lng) > 180) throw new Error('coordenada inválida');
      return [lat, lng];
    });
    out.push({ id: String(g.id || '').slice(0, 120), nombre: String(g.nombre || '').slice(0, 200),
               ha: isFinite(Number(g.ha)) ? Number(g.ha) : null, ring });
  }
  return out.length ? out : null;
}

app.put('/api/lotes-geo', async (req, res) => {
  const b = req.body || {};
  const client = await pool.connect();
  try {
    const sesion = await obtenerSesion(req);
    if (!sesion) return res.status(401).json({ error: 'No autenticado' });
    if (!b.empresaId || !b.campoId) return res.status(400).json({ error: 'Falta empresaId o campoId' });
    if (!Array.isArray(b.lotes)) return res.status(400).json({ error: 'Falta la lista de lotes' });
    const permiso = await obtenerPermiso(req, b.empresaId);
    if (!permiso) return res.status(403).json({ error: 'Sin acceso a esta empresa' });
    if (!puedeEscribirMaestroEmpresa(sesion, permiso)) return res.status(403).json({ error: 'Tu usuario es de solo lectura: no puede cargar mapas' });
    const campoIds = permiso.campoIds || [];
    if (campoIds.length && campoIds.indexOf(b.campoId) === -1) return res.status(403).json({ error: 'No tenés habilitado ese campo' });
    const campo = await client.query('SELECT 1 FROM campos WHERE id=$1 AND empresa_id=$2', [b.campoId, b.empresaId]);
    if (!campo.rows.length) return res.status(400).json({ error: 'El campo no es de esta empresa' });

    const lotes = [];
    try {
      for (const l of b.lotes) lotes.push({ id: String(l && l.id || ''), geo: normalizarGeoLote(l && l.geo) });
    } catch (e) {
      return res.status(400).json({ error: 'El mapa tiene un polígono inválido' });
    }

    await client.query('BEGIN');
    await client.query('UPDATE lotes SET geo=NULL WHERE empresa_id=$1 AND campo_id=$2', [b.empresaId, b.campoId]);
    let conMapa = 0;
    for (const l of lotes) {
      if (!l.geo) continue;
      const r = await client.query('UPDATE lotes SET geo=$3 WHERE id=$1 AND empresa_id=$2 AND campo_id=$4',
        [l.id, b.empresaId, JSON.stringify(l.geo), b.campoId]);
      if (r.rowCount !== 1) {
        await client.query('ROLLBACK');
        return res.status(400).json({ error: 'Un lote del mapa no pertenece a ese campo. Recargá la página y probá de nuevo.' });
      }
      conMapa++;
    }
    await client.query('COMMIT');
    res.json({ status: 'ok', lotesConMapa: conMapa });
  } catch (err) {
    try { await client.query('ROLLBACK'); } catch (e) {}
    console.error('PUT /api/lotes-geo error:', err);
    res.status(500).json({ error: 'Error interno del servidor' });
  } finally {
    client.release();
  }
});

app.get('/api/campos', async (req, res) => {
  const sesion = await obtenerSesion(req);
  if (!sesion) return res.status(401).json({ error: 'No autenticado' });
  try {
    const empresaId = req.query.empresaId;
    let q;
    if (empresaId) {
      const permiso = await obtenerPermiso(req, empresaId);
      if (!permiso) return res.status(403).json({ error: 'Sin acceso a esta empresa' });
      const campoIds = permiso.campoIds || [];
      q = campoIds.length > 0
        ? pool.query(
            `SELECT id, empresa_id AS "empresaId", nombre, localidad, partido, provincia,
                    ha_totales AS "haTotales" FROM campos WHERE empresa_id = $1 AND id = ANY($2::text[]) ORDER BY nombre`,
            [empresaId, campoIds]
          )
        : pool.query(
            `SELECT id, empresa_id AS "empresaId", nombre, localidad, partido, provincia,
                    ha_totales AS "haTotales" FROM campos WHERE empresa_id = $1 ORDER BY nombre`,
            [empresaId]
          );
    } else if (sesion.rol === 'admin_general') {
      q = pool.query(`SELECT id, empresa_id AS "empresaId", nombre, localidad, partido, provincia,
                             ha_totales AS "haTotales" FROM campos ORDER BY nombre`);
    } else if (sesion.rol === 'admin_cliente') {
      // Todos los campos de las empresas de su propio cliente, sin depender
      // de ninguna fila en `permisos` (no la necesita).
      q = pool.query(
        `SELECT c.id, c.empresa_id AS "empresaId", c.nombre, c.localidad,
                c.partido, c.provincia, c.ha_totales AS "haTotales"
           FROM campos c
           JOIN empresas e ON e.id = c.empresa_id
          WHERE e.cliente_id = $1 ORDER BY c.nombre`,
        [sesion.cliente_id]
      );
    } else {
      q = pool.query(
        `SELECT DISTINCT c.id, c.empresa_id AS "empresaId", c.nombre, c.localidad,
                c.partido, c.provincia, c.ha_totales AS "haTotales"
           FROM campos c
           JOIN permisos p ON p.empresa_id = c.empresa_id
          WHERE p.usuario_id = $1 ORDER BY c.nombre`,
        [sesion.id]
      );
    }
    res.json((await q).rows);
  } catch (err) { res.status(500).json({ error: 'Error interno del servidor' }); }
});

app.post('/api/campos', async (req, res) => {
  const sesion = await obtenerSesion(req);
  if (!sesion) return res.status(401).json({ error: 'No autenticado' });
  if (sesion.rol === 'usuario') return res.status(403).json({ error: 'Sin permiso' });
  const k = req.body;
  if (!k.id || !k.nombre || !k.empresaId) return res.status(400).json({ error: 'Faltan campos obligatorios' });
  if (k.haTotales != null && Number(k.haTotales) < 0) return res.status(400).json({ error: 'Las hectáreas totales no pueden ser negativas' });
  try {
    if (sesion.rol === 'admin_cliente') {
      const cid = await clienteDeEmpresa(k.empresaId);
      if (cid !== sesion.cliente_id) return res.status(403).json({ error: 'Sin permiso sobre esa empresa' });
    }
    await pool.query(
      `INSERT INTO campos (id, empresa_id, nombre, localidad, partido, provincia, ha_totales)
       VALUES ($1,$2,$3,$4,$5,$6,$7)
       ON CONFLICT (id) DO UPDATE
         SET nombre=$3, localidad=$4, partido=$5, provincia=$6, ha_totales=$7`,
      [k.id, k.empresaId, k.nombre, k.localidad||null, k.partido||null,
       k.provincia||null, k.haTotales != null ? k.haTotales : null]
    );
    res.status(201).json(k);
  } catch (err) {
    const msg = uniqueViolation(err);
    if (msg) return res.status(409).json({ error: msg });
    res.status(500).json({ error: 'Error interno del servidor' });
  }
});

app.put('/api/campos/:id', async (req, res) => {
  const sesion = await obtenerSesion(req);
  if (!sesion) return res.status(401).json({ error: 'No autenticado' });
  if (sesion.rol === 'usuario') return res.status(403).json({ error: 'Sin permiso' });
  const k = { ...req.body, id: req.params.id };
  if (k.haTotales != null && Number(k.haTotales) < 0) return res.status(400).json({ error: 'Las hectáreas totales no pueden ser negativas' });
  try {
    if (sesion.rol === 'admin_cliente') {
      const cid = await clienteDeCampo(req.params.id);
      if (cid !== sesion.cliente_id) return res.status(403).json({ error: 'Sin permiso sobre ese campo' });
    }
    const bloqueo = await verificarLockPropio('campos', req.params.id, sesion);
    if (bloqueo) return res.status(409).json({ error: 'Lo está editando ' + bloqueo.usuarioNombre });
    await pool.query(
      `UPDATE campos SET nombre=$2, localidad=$3, partido=$4, provincia=$5, ha_totales=$6
       WHERE id=$1`,
      [k.id, k.nombre, k.localidad||null, k.partido||null, k.provincia||null, k.haTotales != null ? k.haTotales : null]
    );
    res.json(k);
  } catch (err) {
    const msg = uniqueViolation(err);
    if (msg) return res.status(409).json({ error: msg });
    res.status(500).json({ error: 'Error interno del servidor' });
  }
});

app.delete('/api/campos/:id', async (req, res) => {
  const sesion = await obtenerSesion(req);
  if (!sesion) return res.status(401).json({ error: 'No autenticado' });
  if (sesion.rol === 'usuario') return res.status(403).json({ error: 'Sin permiso' });
  try {
    if (sesion.rol === 'admin_cliente') {
      const cid = await clienteDeCampo(req.params.id);
      if (cid !== sesion.cliente_id) return res.status(403).json({ error: 'Sin permiso sobre ese campo' });
    }
    const bloqueo = await verificarLockPropio('campos', req.params.id, sesion);
    if (bloqueo) return res.status(409).json({ error: 'Lo está editando ' + bloqueo.usuarioNombre });
    await pool.query('DELETE FROM campos WHERE id=$1', [req.params.id]);
    res.json({ status: 'ok' });
  } catch (err) {
    const msg = fkViolation(err);
    if (msg) return res.status(409).json({ error: msg });
    res.status(500).json({ error: 'Error interno del servidor' });
  }
});

// ─────────────────────────────────────────────────────────────────────────────
// cargar_datos.html — Carga masiva desde Excel (Fase 1: Plan de Uso del Suelo).
// Reemplazo TOTAL de lotes y actividades de la empresa (fidelidad al
// comportamiento original del cliente: no es incremental). Solo
// admin_general/admin_cliente, sin chequear nivel de permiso (decisión del
// cliente). Transaccional: si falla cualquier paso, no queda nada a medio
// reemplazar. Queda auditado en cargas_excel.
// ─────────────────────────────────────────────────────────────────────────────
// '25-26', '25/26', '2025/2026', ' 25 / 26 ' -> '25/26'. Lo que no tenga esa
// forma se compara tal cual (minúsculas, sin espacios en los bordes).
function normalizarNombreCampania(s) {
  const t = String(s || '').trim().toLowerCase();
  const m = t.match(/^(?:camp_)?(\d{2}|\d{4})\s*[-\/_ ]?\s*(\d{2}|\d{4})$/);
  return m ? m[1].slice(-2) + '/' + m[2].slice(-2) : t;
}

// ─────────────────────────────────────────────────────────────────────────────
// Carga del Plan de Uso: lotes que dejan de existir.
// La carga borra y recrea todos los lotes de la empresa. Un lote del Excel con
// el mismo campo y nombre que uno existente CONSERVA SU ID, así sus OT y
// pastoreos siguen enganchados. Los lotes existentes que no siguen (renombrados
// o que no están en el plan nuevo) y tienen OT o pastoreos se muestran en la
// Revisión y quien carga decide, caso por caso, qué hacer (decisión del
// cliente, 2026-11-12). Sin decisión para todos, la carga no se hace.
// ─────────────────────────────────────────────────────────────────────────────
function _nomLote(s) { return String(s || '').trim().toLowerCase(); }
function _dedupNombresLotes(lotes) {
  const vistos = {};
  for (const l of lotes) {
    const k = _nomLote(l.nombre);
    if (!k) continue;
    vistos[k] = (vistos[k] || 0) + 1;
    if (vistos[k] > 1) l.nombre = String(l.nombre || '').trim() + ' (' + vistos[k] + ')';
  }
}
async function _resolverLotesPlan(db, empresaId, campos, lotes) {
  const exC = await db.query('SELECT id, lower(trim(nombre)) AS nom FROM campos WHERE empresa_id=$1', [empresaId]);
  const campoPorNom = {};
  for (const r of exC.rows) campoPorNom[r.nom] = r.id;
  const campoIdMap = {};
  for (const c of campos) campoIdMap[c.id] = campoPorNom[_nomLote(c.nombre || c.id)] || c.id;
  const exL = await db.query(
    `SELECT l.id, l.campo_id, l.nombre, c.nombre AS campo
       FROM lotes l LEFT JOIN campos c ON c.id = l.campo_id WHERE l.empresa_id = $1`, [empresaId]);
  const porId = {}, porNom = {};
  for (const r of exL.rows) { porId[r.id] = r; porNom[(r.campo_id || '') + '|' + _nomLote(r.nombre)] = r; }
  const loteIdMap = {}, quedan = new Set();
  for (const l of lotes) if (porId[l.id]) quedan.add(l.id);
  for (const l of lotes) {
    if (porId[l.id]) continue;
    const campoReal = (l.campoId && campoIdMap[l.campoId]) || l.campoId || '';
    const ex = porNom[campoReal + '|' + _nomLote(l.nombre)];
    if (ex && !quedan.has(ex.id)) { loteIdMap[l.id] = ex.id; quedan.add(ex.id); }
  }
  return { campoIdMap, loteIdMap, salen: exL.rows.filter(r => !quedan.has(r.id)) };
}
function _fechaAr(d) {
  if (!d) return '';
  const s = d instanceof Date ? d.toISOString().slice(0, 10) : String(d).slice(0, 10);
  return s.slice(8, 10) + '/' + s.slice(5, 7) + '/' + s.slice(0, 4);
}
// conRegistro: la misma carga trae Labores e Insumos, que reemplaza todas las
// OT; ahí las OT no se preguntan.
async function _casosPlan(db, empresaId, salen, conRegistro) {
  const ids = salen.map(r => r.id);
  const casos = [], info = [];
  if (!ids.length) return { casos, info };
  const nomLote = {};
  for (const r of salen) nomLote[r.id] = (r.campo ? r.campo + ' · ' : '') + r.nombre;

  if (!conRegistro) {
    const cierre = (await db.query('SELECT max(fecha) AS f FROM cierres_stock WHERE empresa_id=$1', [empresaId])).rows[0].f;
    const ds = await db.query(
      `SELECT d.trabajo_id, d.id, d.lote_id, d.estado_lote, d.fecha_aplic_real, o.id AS ot_id, o.num, lb.nombre AS labor,
              (SELECT count(*)::int FROM ot_destinos d2 JOIN ot_trabajos t2 ON t2.id = d2.trabajo_id AND t2.empresa_id = d2.empresa_id
                WHERE t2.ot_id = o.id AND t2.empresa_id = o.empresa_id AND (d2.lote_id IS NULL OR NOT (d2.lote_id = ANY($2::text[])))) AS otros,
              EXISTS (SELECT 1 FROM comprobantes c JOIN ot_trabajos t3 ON t3.id = c.ref_ot_trabajo AND t3.empresa_id = c.empresa_id
                       WHERE t3.ot_id = o.id AND c.empresa_id = o.empresa_id) AS ot_con_consumos,
              (SELECT count(*)::int FROM movimientos m WHERE m.empresa_id = d.empresa_id AND m.ref_destino_id = d.id) AS n_cons,
              (SELECT max(c.fecha) FROM movimientos m JOIN comprobantes c ON c.id = m.comprobante_id AND c.empresa_id = m.empresa_id
                WHERE m.empresa_id = d.empresa_id AND m.ref_destino_id = d.id) AS f_cons
         FROM ot_destinos d
         JOIN ot_trabajos t ON t.id = d.trabajo_id AND t.empresa_id = d.empresa_id
         JOIN ordenes_trabajo o ON o.id = t.ot_id AND o.empresa_id = t.empresa_id
         LEFT JOIN labores lb ON lb.id = t.labor_id
        WHERE d.empresa_id = $1 AND d.lote_id = ANY($2::text[])
        ORDER BY o.num, t.orden, d.orden`, [empresaId, ids]);
    for (const d of ds.rows) {
      const base = { id: 'otd:' + d.trabajo_id + ':' + d.id, loteId: d.lote_id, lote: nomLote[d.lote_id],
                     otId: d.ot_id, trabajoId: d.trabajo_id, destinoId: d.id };
      const desc = 'OT ' + Number(d.num) + (d.labor ? ' · ' + d.labor : '');
      if (d.estado_lote === 'Aplicado' && d.n_cons > 0) {
        const bloqueado = cierre && d.f_cons && new Date(d.f_cons) <= new Date(cierre);
        casos.push(Object.assign(base, {
          tipo: 'ot_aplicado', detalle: desc + ' · aplicada' + (d.fecha_aplic_real ? ' el ' + _fechaAr(d.fecha_aplic_real) : '') + ' · ' + d.n_cons + ' consumo(s) de stock',
          opciones: [
            { v: 'borrar_con_consumos', t: 'Borrar el lote y sus consumos (el stock vuelve atrás)',
              disabled: !!bloqueado, motivo: bloqueado ? 'tiene consumos anteriores al cierre de stock del ' + _fechaAr(cierre) : '' },
            { v: 'borrar_sin_consumos', t: 'Borrar el lote y dejar los consumos (el stock no cambia; el consumo queda sin OT)' },
          ] }));
      } else {
        const sinOtros = d.otros === 0;
        const opciones = [{ v: 'sacar', t: sinOtros ? 'Borrar la OT (no le quedan otros lotes)' : 'Sacar solo este lote de la OT' }];
        if (!sinOtros) opciones.push({ v: 'borrar_ot', t: 'Borrar la OT entera', disabled: d.ot_con_consumos,
          motivo: d.ot_con_consumos ? 'la OT tiene aplicaciones con consumos de stock' : '' });
        casos.push(Object.assign(base, {
          tipo: 'ot_pendiente',
          detalle: desc + (d.estado_lote === 'Aplicado' ? ' · aplicada, sin consumos registrados' : ' · pendiente'),
          opciones }));
      }
    }
  }

  const ps = await db.query(
    `SELECT p.id, p.num, p.lote_id, p.lote_ids, cp.nombre AS campania,
            (SELECT min(m.fecha) FROM pastoreo_movimientos m WHERE m.pastoreo_id = p.id AND m.empresa_id = p.empresa_id) AS inicio
       FROM pastoreos p LEFT JOIN campanias cp ON cp.id = p.campania_id
      WHERE p.empresa_id = $1 AND (p.lote_id = ANY($2::text[]) OR p.lote_ids && $2::text[])
      ORDER BY p.lote_id, p.num`, [empresaId, ids]);
  const saleSet = new Set(ids);
  for (const p of ps.rows) {
    const todos = (p.lote_ids && p.lote_ids.length) ? p.lote_ids : [p.lote_id];
    const quedan = todos.filter(x => !saleSet.has(x));
    const afectados = todos.filter(x => saleSet.has(x));
    const detalle = 'Pastoreo ' + (p.num != null ? 'N.º ' + p.num : '') + (p.campania ? ' · campaña ' + p.campania : '') +
      (p.inicio ? ' · desde el ' + _fechaAr(p.inicio) : '') + (todos.length > 1 ? ' · grupo de ' + todos.length + ' lotes' : '');
    const opciones = quedan.length
      ? [{ v: 'sacar', t: 'Sacar ' + (afectados.length > 1 ? 'estos lotes' : 'este lote') + ' del grupo' }, { v: 'borrar', t: 'Borrar el pastoreo entero' }]
      : [{ v: 'borrar', t: 'Borrar el pastoreo' }];
    casos.push({ id: 'past:' + p.id, tipo: quedan.length ? 'past_grupo' : 'past_solo', pastoreoId: p.id,
      loteId: afectados[0], lote: afectados.map(x => nomLote[x]).join(', '), detalle, opciones, quedan });
  }

  const sup = await db.query('SELECT count(*)::int AS n FROM pastoreo_superficie WHERE empresa_id=$1 AND lote_id = ANY($2::text[])', [empresaId, ids]);
  const rec = await db.query('SELECT count(*)::int AS n FROM pastoreo_recurso WHERE empresa_id=$1 AND lote_id = ANY($2::text[])', [empresaId, ids]);
  if (sup.rows[0].n) info.push('Se borran ' + sup.rows[0].n + ' corrección(es) de superficie ganadera de lotes que no siguen.');
  if (rec.rows[0].n) info.push('Se borran ' + rec.rows[0].n + ' corrección(es) de recurso forrajero de lotes que no siguen.');
  return { casos, info };
}
function _decisionesFaltantes(casos, decisiones) {
  return casos.filter(c => {
    const op = c.opciones.find(o => o.v === (decisiones || {})[c.id]);
    return !op || op.disabled;
  });
}
async function _aplicarDecisionesPlan(db, empresaId, casos, decisiones, salenIds) {
  const dec = c => decisiones[c.id];
  const otsBorrar = new Set(casos.filter(c => c.tipo.indexOf('ot_') === 0 && dec(c) === 'borrar_ot').map(c => c.otId));
  for (const otId of otsBorrar) {
    await db.query('DELETE FROM ordenes_trabajo WHERE id=$1 AND empresa_id=$2', [otId, empresaId]);
  }
  const trabajos = new Set(), ots = new Set();
  for (const c of casos) {
    if (c.tipo.indexOf('ot_') !== 0 || otsBorrar.has(c.otId)) continue;
    if (dec(c) === 'borrar_con_consumos') {
      const m = await db.query('DELETE FROM movimientos WHERE empresa_id=$1 AND ref_destino_id=$2 RETURNING comprobante_id', [empresaId, c.destinoId]);
      const comps = Array.from(new Set(m.rows.map(r => r.comprobante_id)));
      if (comps.length) {
        await db.query(
          `DELETE FROM comprobantes c WHERE c.empresa_id=$1 AND c.id = ANY($2::text[])
              AND NOT EXISTS (SELECT 1 FROM movimientos m WHERE m.comprobante_id = c.id AND m.empresa_id = c.empresa_id)`,
          [empresaId, comps]);
      }
    } else if (dec(c) === 'borrar_sin_consumos') {
      await db.query('UPDATE movimientos SET ref_destino_id = NULL WHERE empresa_id=$1 AND ref_destino_id=$2', [empresaId, c.destinoId]);
    }
    await db.query('DELETE FROM ot_destinos WHERE trabajo_id=$1 AND empresa_id=$2 AND id=$3', [c.trabajoId, empresaId, c.destinoId]);
    trabajos.add(c.trabajoId); ots.add(c.otId);
  }
  // Labores que quedaron sin lotes: se borran (sus consumos, si quedaron, pasan a "sin OT").
  for (const trId of trabajos) {
    const n = await db.query('SELECT 1 FROM ot_destinos WHERE trabajo_id=$1 AND empresa_id=$2 LIMIT 1', [trId, empresaId]);
    if (n.rows.length) continue;
    await db.query('UPDATE comprobantes SET ref_ot_trabajo = NULL, ref_ot_num = NULL WHERE empresa_id=$1 AND ref_ot_trabajo=$2', [empresaId, trId]);
    await db.query('DELETE FROM ot_trabajos WHERE id=$1 AND empresa_id=$2', [trId, empresaId]);
  }
  // OT sin labores: se borran; las demás recalculan el estado (misma regla que el tablero).
  for (const otId of ots) {
    const r = await db.query(
      `SELECT count(DISTINCT t.id)::int AS ntr, count(d.id)::int AS nd,
              count(d.id) FILTER (WHERE d.estado_lote = 'Aplicado')::int AS apl
         FROM ot_trabajos t LEFT JOIN ot_destinos d ON d.trabajo_id = t.id AND d.empresa_id = t.empresa_id
        WHERE t.ot_id=$1 AND t.empresa_id=$2`, [otId, empresaId]);
    const x = r.rows[0];
    if (!x.ntr) { await db.query('DELETE FROM ordenes_trabajo WHERE id=$1 AND empresa_id=$2', [otId, empresaId]); continue; }
    const estado = x.apl === 0 ? 'Pendiente' : x.apl === x.nd ? 'Aplicada' : 'Parcial';
    await db.query(`UPDATE ordenes_trabajo SET estado=$3 WHERE id=$1 AND empresa_id=$2 AND estado <> 'Cancelada'`, [otId, empresaId, estado]);
  }
  for (const c of casos) {
    if (c.tipo.indexOf('past_') !== 0) continue;
    if (dec(c) === 'borrar') {
      await db.query('DELETE FROM pastoreos WHERE id=$1 AND empresa_id=$2', [c.pastoreoId, empresaId]);
    } else {
      const principal = c.quedan[0];
      const campo = (await db.query('SELECT campo_id FROM lotes WHERE id=$1', [principal])).rows[0];
      await db.query(
        `UPDATE pastoreos SET lote_id = CASE WHEN lote_id = ANY($3::text[]) THEN lote_id ELSE $4 END,
                lote_ids = $5, campo_id = CASE WHEN lote_id = ANY($3::text[]) THEN campo_id ELSE $6 END, actualizado = now()
          WHERE id=$1 AND empresa_id=$2`,
        [c.pastoreoId, empresaId, c.quedan, principal, c.quedan.length > 1 ? c.quedan : null, campo ? campo.campo_id : null]);
    }
  }
  await db.query('DELETE FROM pastoreo_superficie WHERE empresa_id=$1 AND lote_id = ANY($2::text[])', [empresaId, salenIds]);
  await db.query('DELETE FROM pastoreo_recurso    WHERE empresa_id=$1 AND lote_id = ANY($2::text[])', [empresaId, salenIds]);
}

// Vista previa para la Revisión: qué lotes con historia no siguen y qué se puede hacer.
app.post('/api/carga-excel/plan/impacto', async (req, res) => {
  try {
    const b = req.body || {};
    const sesion = await obtenerSesion(req);
    if (!sesion) return res.status(401).json({ error: 'No autenticado' });
    if (sesion.rol !== 'admin_general' && sesion.rol !== 'admin_cliente') {
      return res.status(403).json({ error: 'La carga masiva desde Excel la hace un administrador' });
    }
    if (!b.empresaId) return res.status(400).json({ error: 'Falta empresaId' });
    if (!(await obtenerPermiso(req, b.empresaId))) return res.status(403).json({ error: 'Sin acceso a esta empresa' });
    const lotes = (b.lotes || []).map(l => ({ ...l }));
    _dedupNombresLotes(lotes);
    const r = await _resolverLotesPlan(pool, b.empresaId, b.campos || [], lotes);
    const { casos, info } = await _casosPlan(pool, b.empresaId, r.salen, !!b.conRegistro);
    res.json({ casos, info, conservados: Object.keys(r.loteIdMap).length });
  } catch (err) {
    console.error('/api/carga-excel/plan/impacto POST error:', err);
    res.status(500).json({ error: 'Error interno del servidor' });
  }
});

app.post('/api/carga-excel/plan', async (req, res) => {
  const b = req.body || {};
  const empresaId = b.empresaId;
  const client = await pool.connect();
  try {
    const sesion = await obtenerSesion(req);
    if (!sesion) { return res.status(401).json({ error: 'No autenticado' }); }
    if (sesion.rol !== 'admin_general' && sesion.rol !== 'admin_cliente') {
      return res.status(403).json({ error: 'La carga masiva desde Excel la hace un administrador' });
    }
    if (!empresaId) { return res.status(400).json({ error: 'Falta empresaId' }); }
    const permiso = await obtenerPermiso(req, empresaId);
    if (!permiso) { return res.status(403).json({ error: 'Sin acceso a esta empresa' }); }

    const campos = b.campos || [];
    const lotes = b.lotes || [];
    const actividades = b.actividades || [];
    const tiposNuevos = b.tiposNuevos || [];
    const campanias = (b.campanias || []).slice().sort();
    const informe = b.informe || {};

    await client.query('BEGIN');

    // Lotes con OT o pastoreos que no siguen: tiene que haber una decisión para
    // cada caso (las toma quien carga, en la Revisión). Los lotes con el mismo
    // campo + nombre que uno existente conservan su id.
    _dedupNombresLotes(lotes);
    const resol = await _resolverLotesPlan(client, empresaId, campos, lotes);
    const { casos } = await _casosPlan(client, empresaId, resol.salen, !!b.conRegistro);
    const decisiones = b.decisiones || {};
    if (_decisionesFaltantes(casos, decisiones).length) {
      await client.query('ROLLBACK');
      return res.status(409).json({ error: 'Hay lotes con órdenes de trabajo o pastoreos que no siguen en el plan nuevo: decidí qué hacer con cada uno en la Revisión.', casos });
    }
    for (const l of lotes) if (resol.loteIdMap[l.id]) l.id = resol.loteIdMap[l.id];
    for (const a of actividades) if (a.loteId && resol.loteIdMap[a.loteId]) a.loteId = resol.loteIdMap[a.loteId];
    await _aplicarDecisionesPlan(client, empresaId, casos, decisiones, resol.salen.map(r => r.id));

    // Campañas (catálogo global): el Excel las trae como texto ('25-26'). Se
    // reconocen contra las existentes por nombre normalizado (25-26 = 25/26 =
    // 2025/2026) para no duplicar; solo se agregan las que de verdad faltan.
    const campaniaIdMap = {};
    if (campanias.length) {
      const exRes = await client.query('SELECT id, nombre FROM campanias');
      const porNombre = {};
      for (const r of exRes.rows) {
        porNombre[normalizarNombreCampania(r.id)] = porNombre[normalizarNombreCampania(r.id)] || r.id;
        porNombre[normalizarNombreCampania(r.nombre)] = r.id;
      }
      const maxRes = await client.query('SELECT COALESCE(MAX(orden),0) AS m FROM campanias');
      let maxO = Number(maxRes.rows[0].m) || 0;
      for (const cid of campanias) {
        const clave = normalizarNombreCampania(cid);
        if (porNombre[clave]) { campaniaIdMap[cid] = porNombre[clave]; continue; }
        maxO += 1;
        await client.query(
          'INSERT INTO campanias (id, nombre, orden, activa) VALUES ($1,$2,$3,false) ON CONFLICT (id) DO NOTHING',
          [cid, cid, maxO]
        );
        porNombre[clave] = cid;
        campaniaIdMap[cid] = cid;
      }
    }

    // Tipos de actividad nuevos (por empresa): solo agrega, nunca pisa existentes.
    // Se chequea por nombre (no solo por id): la tabla exige nombre único por
    // empresa, y el Excel puede traer un tipo cuyo nombre ya exista con otro
    // id/sigla (o dos tipos nuevos del mismo Excel con el mismo nombre) —
    // insertarlo igual rompería esa restricción. Cuando se saltea uno por
    // nombre repetido, las actividades que iban a usar SU id tienen que usar
    // el id real del tipo existente — si no, queda una referencia rota.
    const tipoIdMap = {};
    for (const t of tiposNuevos) {
      const ex = await client.query(
        `SELECT id FROM tipos_actividad WHERE empresa_id=$1 AND trim(lower(datos->>'nombre'))=trim(lower($2))`,
        [empresaId, t.nombre || '']
      );
      if (ex.rows.length) {
        tipoIdMap[t.id] = ex.rows[0].id;
        continue;
      }
      await client.query(
        `INSERT INTO tipos_actividad (id, empresa_id, datos) VALUES ($1,$2,$3::jsonb)
         ON CONFLICT (id, empresa_id) DO NOTHING`,
        [t.id, empresaId, JSON.stringify(t)]
      );
    }

    // Campos: actualiza ha_totales de los existentes; da de alta los que falten
    // (el resto de sus datos, localidad/partido/provincia, quedan vacíos — el
    // Excel de Plan de Uso no los trae). Se busca por nombre (no solo por id):
    // la tabla exige nombre único por empresa, y el id que arma el Excel es
    // orientativo — si ya existe un campo con ese nombre (con otro id), hay
    // que actualizar ESE y no intentar crear uno nuevo. Los lotes del mismo
    // paquete referencian el id "orientativo", así que se resuelve con un mapa.
    const campoIdMap = {};
    for (const c of campos) {
      const ex = await client.query(
        `SELECT id FROM campos WHERE empresa_id=$1 AND trim(lower(nombre))=trim(lower($2))`,
        [empresaId, c.nombre || c.id]
      );
      if (ex.rows.length) {
        const idReal = ex.rows[0].id;
        campoIdMap[c.id] = idReal;
        await client.query(
          'UPDATE campos SET ha_totales=$3 WHERE id=$1 AND empresa_id=$2',
          [idReal, empresaId, c.haTotales != null ? c.haTotales : null]
        );
      } else {
        await client.query(
          `INSERT INTO campos (id, empresa_id, nombre, localidad, partido, provincia, ha_totales)
           VALUES ($1,$2,$3,'','','',$4)`,
          [c.id, empresaId, c.nombre || c.id, c.haTotales != null ? c.haTotales : null]
        );
      }
    }

    // Lotes + actividades: reemplazo total (borra TODO lo anterior de la empresa).
    // Los nombres repetidos del Excel ya llevan sufijo " (2)", " (3)"... (ver
    // _dedupNombresLotes al principio): la base exige nombre único por empresa.
    // El Excel no trae el mapa (KML): se conserva el de cada lote que sigue
    // existiendo, por id o por campo + nombre.
    const geoPrev = await client.query(
      'SELECT id, campo_id, lower(trim(nombre)) AS nom, geo FROM lotes WHERE empresa_id=$1 AND geo IS NOT NULL', [empresaId]);
    const geoPorId = {}, geoPorNombre = {};
    for (const g of geoPrev.rows) { geoPorId[g.id] = g.geo; geoPorNombre[g.campo_id + '|' + g.nom] = g.geo; }
    await client.query('DELETE FROM actividades WHERE empresa_id=$1', [empresaId]);
    await client.query('DELETE FROM lotes WHERE empresa_id=$1', [empresaId]);
    for (const l of lotes) {
      const campoIdReal = (l.campoId && campoIdMap[l.campoId]) || l.campoId;
      await client.query(
        `INSERT INTO lotes (id, campo_id, empresa_id, nombre, ha, ambiente, explotable, activo, tipo_override, geo)
         VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)`,
        [l.id, campoIdReal || null, empresaId, l.nombre || null, l.ha != null ? l.ha : null,
         l.ambiente || null, l.explotable != null ? l.explotable : null, l.activo !== false, l.tipoOverride || null,
         (function () {
           const g = geoPorId[l.id] || geoPorNombre[(campoIdReal || null) + '|' + String(l.nombre || '').trim().toLowerCase()];
           return g ? JSON.stringify(g) : null;
         })()]
      );
    }
    for (const a of actividades) {
      const tipoIdReal = (a.tipoActividadId && tipoIdMap[a.tipoActividadId]) || a.tipoActividadId;
      await client.query(
        `INSERT INTO actividades (id, empresa_id, lote_id, campania_id, tipo_actividad_id, ha, es_segunda, tenencia_id)
         VALUES ($1,$2,$3,$4,$5,$6,$7,$8)`,
        [a.id, empresaId, a.loteId || null, (a.campaniaId && campaniaIdMap[a.campaniaId]) || a.campaniaId || null,
         tipoIdReal || null, a.ha != null ? a.ha : null, a.esSegunda || false, a.tenenciaId || null]
      );
    }

    await client.query(
      `INSERT INTO cargas_excel (id, empresa_id, usuario_id, partes, resumen, avisos)
       VALUES ($1,$2,$3,$4::jsonb,$5::jsonb,$6::jsonb)`,
      ['carga_' + Date.now(), empresaId, sesion.id,
       JSON.stringify({ plan: true, reg: false, decisiones: casos.map(c => ({ caso: c.detalle, lote: c.lote, decision: decisiones[c.id] })) }),
       JSON.stringify(informe.resumen || []),
       JSON.stringify(informe.avisos || [])]
    );

    await client.query('COMMIT');
    res.json({ status: 'ok', lotes: lotes.length, actividades: actividades.length, loteIdMap: resol.loteIdMap });
  } catch (err) {
    await client.query('ROLLBACK').catch(() => {});
    console.error('/api/carga-excel/plan POST error:', err);
    const msg = uniqueViolation(err);
    if (msg) return res.status(409).json({ error: msg });
    res.status(500).json({ error: 'Error interno del servidor' });
  } finally {
    client.release();
  }
});

// ─────────────────────────────────────────────────────────────────────────────
// CRUD: /api/grupos-herramientas
// "Carpetas" para herramientas, un solo nivel (no contienen otros grupos).
// Por ahora solo las usa Herramientas Puntal (tipo='interna'), por eso el
// permiso de lectura exige herramientas_internas — si en el futuro también
// se usan para tipo='externa' (público), este chequeo hay que repensarlo.
// admin_general siempre puede leer/escribir.
// ─────────────────────────────────────────────────────────────────────────────
app.get('/api/grupos-herramientas', async (req, res) => {
  const sesion = await obtenerSesion(req);
  if (!sesion) return res.status(401).json({ error: 'No autenticado' });
  const puedeInternas = sesion.rol === 'admin_general' || sesion.herramientas_internas === true;
  if (!puedeInternas) return res.json([]);
  try {
    const r = await pool.query('SELECT id, nombre, descripcion, orden, activo FROM grupos_herramientas ORDER BY orden, nombre');
    res.json(r.rows);
  } catch (err) { res.status(500).json({ error: 'Error interno del servidor' }); }
});

app.post('/api/grupos-herramientas', async (req, res) => {
  const sesion = await obtenerSesion(req);
  if (!sesion) return res.status(401).json({ error: 'No autenticado' });
  if (sesion.rol !== 'admin_general') return res.status(403).json({ error: 'Sin permiso' });
  const g = req.body || {};
  if (!g.id || !g.nombre) return res.status(400).json({ error: 'Faltan id o nombre' });
  try {
    await pool.query(
      `INSERT INTO grupos_herramientas (id, nombre, descripcion, orden, activo)
       VALUES ($1,$2,$3,$4,$5)
       ON CONFLICT (id) DO UPDATE SET nombre=$2, descripcion=$3, orden=$4, activo=$5`,
      [g.id, g.nombre, g.descripcion || null, g.orden || 0, g.activo !== false]
    );
    res.status(201).json(g);
  } catch (err) { res.status(500).json({ error: 'Error interno del servidor' }); }
});

app.put('/api/grupos-herramientas/:id', async (req, res) => {
  const sesion = await obtenerSesion(req);
  if (!sesion) return res.status(401).json({ error: 'No autenticado' });
  if (sesion.rol !== 'admin_general') return res.status(403).json({ error: 'Sin permiso' });
  const g = { ...req.body, id: req.params.id };
  try {
    await pool.query(
      'UPDATE grupos_herramientas SET nombre=$2, descripcion=$3, orden=$4, activo=$5 WHERE id=$1',
      [g.id, g.nombre, g.descripcion || null, g.orden || 0, g.activo !== false]
    );
    res.json(g);
  } catch (err) { res.status(500).json({ error: 'Error interno del servidor' }); }
});

app.delete('/api/grupos-herramientas/:id', async (req, res) => {
  const sesion = await obtenerSesion(req);
  if (!sesion) return res.status(401).json({ error: 'No autenticado' });
  if (sesion.rol !== 'admin_general') return res.status(403).json({ error: 'Sin permiso' });
  try {
    // ON DELETE SET NULL en herramientas.grupo_id: las herramientas de este
    // grupo no se borran, quedan sin grupo (vuelven a verse sueltas).
    await pool.query('DELETE FROM grupos_herramientas WHERE id=$1', [req.params.id]);
    res.json({ status: 'ok' });
  } catch (err) { res.status(500).json({ error: 'Error interno del servidor' }); }
});

// ─────────────────────────────────────────────────────────────────────────────
// CRUD: /api/herramientas
// Lista de herramientas disponibles en el sistema (propias y externas).
// admin_general puede crear/editar/eliminar; los demás solo leer.
// ─────────────────────────────────────────────────────────────────────────────
app.get('/api/herramientas', async (req, res) => {
  const sesion = await obtenerSesion(req);
  if (!sesion) return res.status(401).json({ error: 'No autenticado' });
  try {
    // tipo='interna' (Herramientas Puntal) solo se lista si el usuario tiene el
    // permiso — admin_general siempre lo tiene, es quien las administra.
    const puedeInternas = sesion.rol === 'admin_general' || sesion.herramientas_internas === true;
    const r = await pool.query(
      `SELECT id, nombre, descripcion, tipo, url, dominio, fuente,
              vigencia_desde AS "vigenciaDesde", vigencia_hasta AS "vigenciaHasta",
              orden, activa, asignable, archivo_nombre AS "archivoNombre", grupo_id AS "grupoId"
         FROM herramientas
        WHERE tipo <> 'interna' OR $1
        ORDER BY orden, nombre`,
      [puedeInternas]
    );
    res.json(r.rows);
  } catch (err) { res.status(500).json({ error: 'Error interno del servidor' }); }
});

app.post('/api/herramientas', async (req, res) => {
  const sesion = await obtenerSesion(req);
  if (!sesion) return res.status(401).json({ error: 'No autenticado' });
  if (sesion.rol !== 'admin_general') return res.status(403).json({ error: 'Sin permiso' });
  const h = req.body;
  if (!h.id || !h.nombre) return res.status(400).json({ error: 'Faltan id o nombre' });
  try {
    await pool.query(
      `INSERT INTO herramientas (id, nombre, descripcion, tipo, url, dominio, fuente, vigencia_desde, vigencia_hasta, orden, activa, asignable, archivo_nombre, grupo_id)
       VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14)
       ON CONFLICT (id) DO UPDATE
         SET nombre=$2, descripcion=$3, tipo=$4, url=$5, dominio=$6, fuente=$7,
             vigencia_desde=$8, vigencia_hasta=$9, orden=$10, activa=$11, asignable=$12, archivo_nombre=$13, grupo_id=$14`,
      [h.id, h.nombre, h.descripcion||null, h.tipo||'propia', h.url||null, h.dominio||null,
       h.fuente||null, h.vigenciaDesde||null, h.vigenciaHasta||null, h.orden||0,
       h.activa !== false, h.asignable !== false, h.archivoNombre||null, h.grupoId||null]
    );
    res.status(201).json(h);
  } catch (err) { res.status(500).json({ error: 'Error interno del servidor' }); }
});

app.put('/api/herramientas/:id', async (req, res) => {
  const sesion = await obtenerSesion(req);
  if (!sesion) return res.status(401).json({ error: 'No autenticado' });
  if (sesion.rol !== 'admin_general') return res.status(403).json({ error: 'Sin permiso' });
  const h = { ...req.body, id: req.params.id };
  try {
    await pool.query(
      `UPDATE herramientas SET nombre=$2, descripcion=$3, tipo=$4, url=$5, dominio=$6, fuente=$7,
              vigencia_desde=$8, vigencia_hasta=$9, orden=$10, activa=$11, asignable=$12, archivo_nombre=$13, grupo_id=$14
       WHERE id=$1`,
      [h.id, h.nombre, h.descripcion||null, h.tipo||'propia', h.url||null, h.dominio||null,
       h.fuente||null, h.vigenciaDesde||null, h.vigenciaHasta||null, h.orden||0,
       h.activa !== false, h.asignable !== false, h.archivoNombre||null, h.grupoId||null]
    );
    res.json(h);
  } catch (err) { res.status(500).json({ error: 'Error interno del servidor' }); }
});

app.delete('/api/herramientas/:id', async (req, res) => {
  const sesion = await obtenerSesion(req);
  if (!sesion) return res.status(401).json({ error: 'No autenticado' });
  if (sesion.rol !== 'admin_general') return res.status(403).json({ error: 'Sin permiso' });
  try {
    const actual = await pool.query('SELECT url FROM herramientas WHERE id=$1', [req.params.id]);
    await pool.query('DELETE FROM herramientas WHERE id=$1', [req.params.id]);
    if (actual.rows.length) {
      borrarPdfHerramientaSiPropio(actual.rows[0].url);
      borrarArchivoInternoSiPropio(actual.rows[0].url);
    }
    res.json({ status: 'ok' });
  } catch (err) { res.status(500).json({ error: 'Error interno del servidor' }); }
});

// Subida de PDF para una herramienta externa existente: reemplaza `url` por la
// ruta del archivo servido de forma estática, y borra el PDF anterior si
// también era uno subido por este mismo endpoint (no si era un link externo).
app.post('/api/herramientas/:id/pdf', async (req, res) => {
  const sesion = await obtenerSesion(req);
  if (!sesion) return res.status(401).json({ error: 'No autenticado' });
  if (sesion.rol !== 'admin_general') return res.status(403).json({ error: 'Sin permiso' });

  uploadPdfHerramienta(req, res, async function (err) {
    if (err) return res.status(400).json({ error: err.message || 'Error al subir el archivo' });
    if (!req.file) return res.status(400).json({ error: 'Falta el archivo PDF' });
    try {
      const actual = await pool.query('SELECT url FROM herramientas WHERE id = $1', [req.params.id]);
      if (!actual.rows.length) {
        fs.unlink(req.file.path, function () {});
        return res.status(404).json({ error: 'Herramienta no encontrada' });
      }
      const nuevaUrl = 'uploads/herramientas/' + req.file.filename;
      await pool.query('UPDATE herramientas SET url = $2 WHERE id = $1', [req.params.id, nuevaUrl]);
      borrarPdfHerramientaSiPropio(actual.rows[0].url);
      res.json({ id: req.params.id, url: nuevaUrl });
    } catch (e) {
      console.error('POST /api/herramientas/:id/pdf error:', e);
      res.status(500).json({ error: 'Error interno del servidor' });
    }
  });
});

// Subida de archivo para una herramienta interna (tipo='interna', "Herramientas
// Puntal"). A diferencia de /pdf, el archivo NO queda en una ruta pública: se
// guarda fuera de frontend/ y `url` pasa a valer 'interno:<archivo_en_disco>',
// que no es servible directo por express.static. Solo admin_general sube.
app.post('/api/herramientas/:id/archivo', async (req, res) => {
  const sesion = await obtenerSesion(req);
  if (!sesion) return res.status(401).json({ error: 'No autenticado' });
  if (sesion.rol !== 'admin_general') return res.status(403).json({ error: 'Sin permiso' });

  uploadArchivoInterno(req, res, async function (err) {
    if (err) return res.status(400).json({ error: err.message || 'Error al subir el archivo' });
    if (!req.file) return res.status(400).json({ error: 'Falta el archivo' });
    try {
      const actual = await pool.query('SELECT url FROM herramientas WHERE id = $1', [req.params.id]);
      if (!actual.rows.length) {
        fs.unlink(req.file.path, function () {});
        return res.status(404).json({ error: 'Herramienta no encontrada' });
      }
      const nuevaUrl = 'interno:' + req.file.filename;
      await pool.query(
        'UPDATE herramientas SET url = $2, archivo_nombre = $3 WHERE id = $1',
        [req.params.id, nuevaUrl, req.file.originalname || req.file.filename]
      );
      borrarArchivoInternoSiPropio(actual.rows[0].url);
      res.json({ id: req.params.id, url: nuevaUrl, archivoNombre: req.file.originalname || req.file.filename });
    } catch (e) {
      console.error('POST /api/herramientas/:id/archivo error:', e);
      res.status(500).json({ error: 'Error interno del servidor' });
    }
  });
});

// Paso 1 para ver/descargar un archivo interno: valida sesión + permiso
// herramientas_internas (o admin_general) y devuelve un link de un solo uso, de
// vida corta, para no tener que mandar el archivo real con el Authorization
// header (un <a>/window.open no lo manda).
app.get('/api/herramientas/:id/archivo-url', async (req, res) => {
  const sesion = await obtenerSesion(req);
  if (!sesion) return res.status(401).json({ error: 'No autenticado' });
  const puedeInternas = sesion.rol === 'admin_general' || sesion.herramientas_internas === true;
  if (!puedeInternas) return res.status(403).json({ error: 'Sin permiso' });
  try {
    const r = await pool.query("SELECT url FROM herramientas WHERE id = $1 AND tipo = 'interna'", [req.params.id]);
    if (!r.rows.length || !r.rows[0].url || r.rows[0].url.indexOf('interno:') !== 0) {
      return res.status(404).json({ error: 'Archivo no encontrado' });
    }
    const token = mintTokenArchivoInterno(req.params.id);
    res.json({ url: '/api/herramientas/' + encodeURIComponent(req.params.id) + '/archivo?t=' + token });
  } catch (e) {
    res.status(500).json({ error: 'Error interno del servidor' });
  }
});

// Paso 2: entrega el archivo real, solo con un token recién emitido por el
// endpoint de arriba (de un solo uso, vence a los 30s). Sin sesión: el token
// ya implica que el permiso se chequeó al pedirlo.
app.get('/api/herramientas/:id/archivo', async (req, res) => {
  const token = String(req.query.t || '');
  if (!consumirTokenArchivoInterno(token, req.params.id)) {
    return res.status(403).json({ error: 'Link vencido, volvé a intentarlo' });
  }
  try {
    const r = await pool.query(
      "SELECT url, archivo_nombre AS \"archivoNombre\" FROM herramientas WHERE id = $1 AND tipo = 'interna'",
      [req.params.id]
    );
    if (!r.rows.length || !r.rows[0].url || r.rows[0].url.indexOf('interno:') !== 0) {
      return res.status(404).json({ error: 'Archivo no encontrado' });
    }
    const archivo = path.basename(r.rows[0].url.slice('interno:'.length));
    const rutaAbs = path.join(HERRAMIENTAS_INTERNAS_DIR, archivo);
    res.download(rutaAbs, r.rows[0].archivoNombre || archivo, function (err) {
      if (err && !res.headersSent) res.status(404).json({ error: 'Archivo no encontrado' });
    });
  } catch (e) {
    res.status(500).json({ error: 'Error interno del servidor' });
  }
});

// ─────────────────────────────────────────────────────────────────────────────
// ÓRDENES DE TRABAJO (tablero_insumos_ot)
// El número de OT se asigna de forma atómica vía contadores_ot, dentro de la
// misma transacción del INSERT — evita la carrera de asignarlo en el cliente.
// ─────────────────────────────────────────────────────────────────────────────
// Reemplaza TODOS los trabajos (labores) de una OT: borra e inserta de
// nuevo, igual que _guardarLineasComprobante hace con las líneas de un
// comprobante. El frontend manda siempre el conjunto completo de trabajos.
// Upsert por id, no "borrar todo y reinsertar": el flujo real de edición de
// una OT reenvía TAMBIÉN los trabajos ya aplicados (los que generaron un
// comprobante) junto con los nuevos/editados — y esos tienen
// comprobantes.ref_ot_trabajo con ON DELETE RESTRICT. Un DELETE sobre esos
// ids rompería la edición. Por eso: UPDATE si el id ya existe, INSERT si es
// nuevo, y DELETE solo de los que NO vienen en el array nuevo (el usuario
// los sacó del formulario) — si alguno de esos tiene comprobantes, el
// RESTRICT lo frena con un error claro en vez de un borrado silencioso.
async function _guardarTrabajosOt(client, otId, empresaId, trabajos) {
  const incoming = trabajos || [];
  const incomingIds = incoming.filter(t => t.id).map(t => t.id);
  if (incomingIds.length) {
    await client.query(
      `DELETE FROM ot_trabajos WHERE ot_id=$1 AND empresa_id=$2 AND id <> ALL($3::text[])`,
      [otId, empresaId, incomingIds]
    );
  } else {
    await client.query('DELETE FROM ot_trabajos WHERE ot_id=$1 AND empresa_id=$2', [otId, empresaId]);
  }
  const out = [];
  let orden = 0;
  for (const t of incoming) {
    orden++;
    const id = t.id || (otId + '_tr' + orden);
    await client.query(
      `INSERT INTO ot_trabajos (id, empresa_id, ot_id, labor_tipo, labor_id, subactividad, tercero_id,
                                tarifa, tarifa_moneda, monto_facturado, estado_fact, estado_pago, monto_pagado,
                                es_resiembra, orden)
       VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15)
       ON CONFLICT (id, empresa_id) DO UPDATE SET
         ot_id=$3, labor_tipo=$4, labor_id=$5, subactividad=$6, tercero_id=$7,
         tarifa=$8, tarifa_moneda=$9, monto_facturado=$10, estado_fact=$11, estado_pago=$12, monto_pagado=$13,
         es_resiembra=$14, orden=$15`,
      [id, empresaId, otId, t.laborTipo || null, t.laborId || null, t.subactividad || null,
       t.contratistaId || null, t.tarifa || null, t.tarifaMoneda || 'ARS', t.montoFacturado || 0,
       t.estadoFact || 'Sin facturar', t.estadoPago || 'No', t.montoPagado || 0, t.esResiembra || false, orden]
    );
    await _guardarDestinosTrabajo(client, id, empresaId, t);
    out.push({ ...t, id, otId, empresaId, orden });
  }
  return out;
}

// Destinos (lotes), líneas de insumo, cambios de cultivo y plantilla de un
// trabajo: se borran y se vuelven a escribir enteros (nada apunta a ellos con
// FK; movimientos.ref_destino_id es solo texto). jsonb_to_recordset se usa
// para mandar todas las filas de una tabla en un solo INSERT.
function _otNum(v) {
  if (v === null || v === undefined || v === '') return null;
  const n = Number(v);
  return isFinite(n) ? n : null;
}
// Superficies de los lotes de una OT (ha y haReal): número >= 0 si vienen.
// Cero se acepta (lote agregado con la superficie todavía sin cargar). Se
// valida antes de escribir nada. No se validan dosis ni cantidades.
function errorSuperficiesOt(trabajos) {
  for (const t of (trabajos || [])) {
    for (const d of ((t && t.destinos) || [])) {
      if (!d || typeof d !== 'object') continue;
      for (const k of ['ha', 'haReal']) {
        const v = d[k];
        if (v === null || v === undefined || v === '') continue;
        const n = Number(v);
        if (!isFinite(n)) return 'La superficie del lote ' + (d.loteId || '') + ' no es un número válido';
        if (n < 0) return 'La superficie del lote ' + (d.loteId || '') + ' no puede ser negativa';
      }
    }
  }
  return null;
}
function _otFecha(v) {
  const m = /^(\d{4}-\d{2}-\d{2})/.exec(String(v || ''));
  return m ? m[1] : null;
}
function _otTxt(v) { return v === null || v === undefined ? null : String(v); }
async function _guardarDestinosTrabajo(client, trabajoId, empresaId, t) {
  await client.query('DELETE FROM ot_destinos  WHERE trabajo_id=$1 AND empresa_id=$2', [trabajoId, empresaId]);
  await client.query('DELETE FROM ot_plantilla WHERE trabajo_id=$1 AND empresa_id=$2', [trabajoId, empresaId]);
  const dests = [], lineas = [], cambios = [], plantilla = [];
  const vistos = {};
  (t.destinos || []).forEach((d, i) => {
    if (!d || typeof d !== 'object') return;
    const id = String(d.id || (trabajoId + '_d' + (i + 1)));
    if (vistos[id]) return; // id repetido dentro del mismo trabajo: queda el primero
    vistos[id] = true;
    dests.push({
      id, orden: i + 1, lote_id: _otTxt(d.loteId), campo_id: d.campoId || null, cultivo: _otTxt(d.cultivo),
      ha: _otNum(d.ha), ha_real: _otNum(d.haReal), obs: _otTxt(d.obs),
      estado_lote: d.estadoLote === 'Aplicado' ? 'Aplicado' : 'Pendiente',
      fecha_aplic_real: _otFecha(d.fechaAplicReal), tanda_id: _otTxt(d.tandaId),
      cultivo_mantenido: _otTxt(d.cultivoMantenido), cultivo_mantenido_fecha: _otFecha(d.cultivoMantenidoFecha),
      cultivo_mantenido_ahora: _otTxt(d.cultivoMantenidoAhora),
      geo_ot: d.geoOt && typeof d.geoOt === 'object' ? d.geoOt : null,
    });
    (d.lineas || []).forEach((l, j) => {
      if (!l || typeof l !== 'object') return;
      lineas.push({
        destino_id: id, orden: j + 1, insumo_id: l.insumoId || null, deposito_id: l.depositoId || null,
        dosis: _otNum(l.dosis), dosis_real: _otNum(l.dosisReal), entregada: _otNum(l.entregada),
        usado: _otNum(l.usado), dev_stock: _otNum(l.devStock), dev_baja: _otNum(l.devBaja),
      });
    });
    (d.cambiosCultivo || []).forEach((c, j) => {
      if (!c || typeof c !== 'object') return;
      cambios.push({ destino_id: id, orden: j + 1, cultivo_de: _otTxt(c.de), cultivo_a: _otTxt(c.a), fecha: _otFecha(c.fecha) });
    });
  });
  (t.plantilla || []).forEach((p, i) => {
    if (!p || typeof p !== 'object') return;
    plantilla.push({ orden: i + 1, insumo_id: p.insumoId || null, dosis: _otNum(p.dosis), deposito_id: p.depositoId || null });
  });
  if (dests.length) {
    await client.query(
      `INSERT INTO ot_destinos (id, empresa_id, trabajo_id, orden, lote_id, campo_id, cultivo, ha, ha_real, obs,
                                estado_lote, fecha_aplic_real, tanda_id, cultivo_mantenido, cultivo_mantenido_fecha,
                                cultivo_mantenido_ahora, geo_ot)
       SELECT x.id, $1, $2, x.orden, x.lote_id, x.campo_id, x.cultivo, x.ha, x.ha_real, x.obs,
              x.estado_lote, x.fecha_aplic_real, x.tanda_id, x.cultivo_mantenido, x.cultivo_mantenido_fecha,
              x.cultivo_mantenido_ahora, x.geo_ot
         FROM jsonb_to_recordset($3::jsonb) AS x(id text, orden int, lote_id text, campo_id text, cultivo text,
              ha numeric, ha_real numeric, obs text, estado_lote text, fecha_aplic_real date, tanda_id text,
              cultivo_mantenido text, cultivo_mantenido_fecha date, cultivo_mantenido_ahora text, geo_ot jsonb)`,
      [empresaId, trabajoId, JSON.stringify(dests)]
    );
  }
  if (lineas.length) {
    await client.query(
      `INSERT INTO ot_destino_lineas (empresa_id, trabajo_id, destino_id, orden, insumo_id, deposito_id,
                                      dosis, dosis_real, entregada, usado, dev_stock, dev_baja)
       SELECT $1, $2, x.destino_id, x.orden, x.insumo_id, x.deposito_id,
              x.dosis, x.dosis_real, x.entregada, x.usado, x.dev_stock, x.dev_baja
         FROM jsonb_to_recordset($3::jsonb) AS x(destino_id text, orden int, insumo_id text, deposito_id text,
              dosis numeric, dosis_real numeric, entregada numeric, usado numeric, dev_stock numeric, dev_baja numeric)`,
      [empresaId, trabajoId, JSON.stringify(lineas)]
    );
  }
  if (cambios.length) {
    await client.query(
      `INSERT INTO ot_destino_cambios_cultivo (empresa_id, trabajo_id, destino_id, orden, cultivo_de, cultivo_a, fecha)
       SELECT $1, $2, x.destino_id, x.orden, x.cultivo_de, x.cultivo_a, x.fecha
         FROM jsonb_to_recordset($3::jsonb) AS x(destino_id text, orden int, cultivo_de text, cultivo_a text, fecha date)`,
      [empresaId, trabajoId, JSON.stringify(cambios)]
    );
  }
  if (plantilla.length) {
    await client.query(
      `INSERT INTO ot_plantilla (empresa_id, trabajo_id, orden, insumo_id, dosis, deposito_id)
       SELECT $1, $2, x.orden, x.insumo_id, x.dosis, x.deposito_id
         FROM jsonb_to_recordset($3::jsonb) AS x(orden int, insumo_id text, dosis numeric, deposito_id text)`,
      [empresaId, trabajoId, JSON.stringify(plantilla)]
    );
  }
}

// Lee los trabajos de la empresa (o de una OT) con sus destinos y plantilla
// armados como los guardaba el tablero. Un campo opcional del destino solo
// aparece si tiene valor, igual que en el documento original.
function _numDb(v) { return v === null || v === undefined ? null : Number(v); }
async function leerTrabajosOt(db, empresaId, otId) {
  const pTr = otId ? [empresaId, otId] : [empresaId];
  const filtroTr = otId ? ' AND t.ot_id = $2' : '';
  const [trs, dests, lins, ccs, plas] = await Promise.all([
    db.query(`SELECT t.* FROM ot_trabajos t WHERE t.empresa_id = $1${filtroTr} ORDER BY t.ot_id, t.orden`, pTr),
    db.query(`SELECT d.*, to_char(d.fecha_aplic_real, 'YYYY-MM-DD') AS f_aplic,
                     to_char(d.cultivo_mantenido_fecha, 'YYYY-MM-DD') AS f_mant
                FROM ot_destinos d JOIN ot_trabajos t ON t.id = d.trabajo_id AND t.empresa_id = d.empresa_id
               WHERE d.empresa_id = $1${filtroTr} ORDER BY d.trabajo_id, d.orden`, pTr),
    db.query(`SELECT l.* FROM ot_destino_lineas l JOIN ot_trabajos t ON t.id = l.trabajo_id AND t.empresa_id = l.empresa_id
               WHERE l.empresa_id = $1${filtroTr} ORDER BY l.trabajo_id, l.destino_id, l.orden`, pTr),
    db.query(`SELECT c.*, to_char(c.fecha, 'YYYY-MM-DD') AS f
                FROM ot_destino_cambios_cultivo c JOIN ot_trabajos t ON t.id = c.trabajo_id AND t.empresa_id = c.empresa_id
               WHERE c.empresa_id = $1${filtroTr} ORDER BY c.trabajo_id, c.destino_id, c.orden`, pTr),
    db.query(`SELECT p.* FROM ot_plantilla p JOIN ot_trabajos t ON t.id = p.trabajo_id AND t.empresa_id = p.empresa_id
               WHERE p.empresa_id = $1${filtroTr} ORDER BY p.trabajo_id, p.orden`, pTr),
  ]);
  const k = (a, b) => a + '\u0000' + b;
  const linPorDest = {}, ccPorDest = {}, destPorTr = {}, plaPorTr = {};
  for (const l of lins.rows) {
    const o = { insumoId: l.insumo_id || '', depositoId: l.deposito_id || '' };
    if (l.dosis !== null) o.dosis = _numDb(l.dosis);
    if (l.entregada !== null) o.entregada = _numDb(l.entregada);
    if (l.usado !== null) o.usado = _numDb(l.usado);
    if (l.dev_stock !== null) o.devStock = _numDb(l.dev_stock);
    if (l.dev_baja !== null) o.devBaja = _numDb(l.dev_baja);
    if (l.dosis_real !== null) o.dosisReal = _numDb(l.dosis_real);
    (linPorDest[k(l.trabajo_id, l.destino_id)] = linPorDest[k(l.trabajo_id, l.destino_id)] || []).push(o);
  }
  for (const c of ccs.rows) {
    (ccPorDest[k(c.trabajo_id, c.destino_id)] = ccPorDest[k(c.trabajo_id, c.destino_id)] || [])
      .push({ de: c.cultivo_de, a: c.cultivo_a, fecha: c.f || '' });
  }
  for (const d of dests.rows) {
    const o = {
      id: d.id, campoId: d.campo_id, loteId: d.lote_id, cultivo: d.cultivo, ha: _numDb(d.ha), obs: d.obs,
      estadoLote: d.estado_lote, fechaAplicReal: d.f_aplic || '',
      lineas: linPorDest[k(d.trabajo_id, d.id)] || [],
    };
    if (d.ha_real !== null) o.haReal = _numDb(d.ha_real);
    if (d.tanda_id !== null) o.tandaId = d.tanda_id;
    if (ccPorDest[k(d.trabajo_id, d.id)]) o.cambiosCultivo = ccPorDest[k(d.trabajo_id, d.id)];
    if (d.cultivo_mantenido !== null) o.cultivoMantenido = d.cultivo_mantenido;
    if (d.f_mant !== null) o.cultivoMantenidoFecha = d.f_mant;
    if (d.cultivo_mantenido_ahora !== null) o.cultivoMantenidoAhora = d.cultivo_mantenido_ahora;
    if (d.geo_ot !== null) o.geoOt = d.geo_ot;
    (destPorTr[d.trabajo_id] = destPorTr[d.trabajo_id] || []).push(o);
  }
  for (const p of plas.rows) {
    const o = { insumoId: p.insumo_id || '', depositoId: p.deposito_id || '' };
    if (p.dosis !== null) o.dosis = _numDb(p.dosis);
    (plaPorTr[p.trabajo_id] = plaPorTr[p.trabajo_id] || []).push(o);
  }
  return trs.rows.map(r => ({
    id: r.id, otId: r.ot_id, laborTipo: r.labor_tipo, laborId: r.labor_id, subactividad: r.subactividad,
    contratistaId: r.tercero_id, tarifa: r.tarifa, tarifaMoneda: r.tarifa_moneda,
    montoFacturado: r.monto_facturado, estadoFact: r.estado_fact,
    estadoPago: r.estado_pago, montoPagado: r.monto_pagado, esResiembra: r.es_resiembra,
    plantilla: plaPorTr[r.id] || [], destinos: destPorTr[r.id] || [], orden: r.orden,
  }));
}

app.get('/api/ordenes-trabajo', async (req, res) => {
  try {
    const sesion = await obtenerSesion(req);
    if (!sesion) return res.status(401).json({ error: 'No autenticado' });
    const empresaId = req.query.empresaId;
    if (!empresaId) return res.status(400).json({ error: 'Falta empresaId' });
    const permiso = await obtenerPermiso(req, empresaId);
    if (!permiso) return res.status(403).json({ error: 'Sin acceso a esta empresa' });
    if (!puedeEnHerramienta(permiso, 'tablero_insumos_ot', 'ver')) return res.status(403).json({ error: 'Tu usuario no tiene acceso a Registro de Labores e Insumos' });

    const params = [empresaId];
    let sql = `SELECT id, num, campania_id AS "campaniaId", fecha, obs, estado, ultimo_registro AS "ultimoRegistro", impresa, rapida
                 FROM ordenes_trabajo WHERE empresa_id = $1`;
    if (req.query.campaniaId) { params.push(req.query.campaniaId); sql += ` AND campania_id = $${params.length}`; }
    sql += ' ORDER BY num DESC';
    const r = await pool.query(sql, params);
    const porOt = {};
    for (const tr of await leerTrabajosOt(pool, empresaId)) { (porOt[tr.otId] = porOt[tr.otId] || []).push(tr); }
    // Usuario con campos restringidos: no recibe las OT que son solo de otros campos.
    res.json(r.rows.map(ot => ({ ...ot, trabajos: porOt[ot.id] || [] }))
      .filter(ot => otVisibleParaPermiso(permiso, ot.trabajos)));
  } catch (err) {
    console.error('/api/ordenes-trabajo GET error:', err);
    res.status(500).json({ error: 'Error interno del servidor' });
  }
});

// Stock comprometido por OT de campos que el usuario no tiene habilitados (opción
// acordada con el cliente): para que su comprometido y disponible coincidan con los
// del administrador en los depósitos que sí ve (generales o de sus campos), se
// mandan solo los totales por insumo y depósito, sin número de OT ni lotes. Misma
// cuenta que comprometido() del tablero: lotes no aplicados de OT no canceladas,
// dosis × ha (o la dosis sola si el destino es una unidad de negocio).
// Respuesta: { lineas: [{insumoId, depositoId, cant}], nOts } — nOts es cuántas de
// esas OT tienen pendientes (en cualquier depósito), para el indicador "OT con
// pendientes": propias + otros campos = el total del administrador.
app.get('/api/ordenes-trabajo/comprometido-otros-campos', async (req, res) => {
  try {
    const sesion = await obtenerSesion(req);
    if (!sesion) return res.status(401).json({ error: 'No autenticado' });
    const empresaId = req.query.empresaId;
    if (!empresaId) return res.status(400).json({ error: 'Falta empresaId' });
    const permiso = await obtenerPermiso(req, empresaId);
    if (!permiso) return res.status(403).json({ error: 'Sin acceso a esta empresa' });
    if (!puedeEnHerramienta(permiso, 'tablero_insumos_ot', 'ver')) return res.status(403).json({ error: 'Tu usuario no tiene acceso a Registro de Labores e Insumos' });
    const ajenos = await depositosAjenos(pool, permiso, empresaId);
    if (!ajenos) return res.json({ lineas: [], nOts: 0 }); // sin restricción de campos: ya recibe todas las OT

    // OT no canceladas que el usuario no recibe: tienen lotes y ninguno es de un
    // campo habilitado (ni sin campo). De esas, las líneas de lotes no aplicados.
    const r = await pool.query(
      `SELECT t.ot_id, d.lote_id, d.ha, l.insumo_id, l.deposito_id, l.dosis
         FROM ordenes_trabajo o
         JOIN ot_trabajos t       ON t.ot_id = o.id AND t.empresa_id = o.empresa_id
         JOIN ot_destinos d       ON d.trabajo_id = t.id AND d.empresa_id = t.empresa_id
         JOIN ot_destino_lineas l ON l.trabajo_id = d.trabajo_id AND l.empresa_id = d.empresa_id AND l.destino_id = d.id
        WHERE o.empresa_id = $1 AND o.estado <> 'Cancelada'
          AND d.estado_lote <> 'Aplicado' AND l.insumo_id IS NOT NULL
          AND NOT EXISTS (
                SELECT 1 FROM ot_trabajos t2
                  JOIN ot_destinos d2 ON d2.trabajo_id = t2.id AND d2.empresa_id = t2.empresa_id
                 WHERE t2.ot_id = o.id AND t2.empresa_id = o.empresa_id
                   AND (d2.campo_id IS NULL OR d2.campo_id = ANY($2::text[])))
        ORDER BY o.num, t.orden, d.orden, l.orden`,
      [empresaId, permiso.campoIds]);
    const tot = {};
    const conPendientes = new Set();
    for (const x of r.rows) {
      const esUN = String(x.lote_id || '').indexOf('UN:') === 0;
      const cant = esUN ? (Number(x.dosis) || 0) : (Number(x.dosis) || 0) * (Number(x.ha) || 0);
      if (!(cant > 0)) continue;
      conPendientes.add(x.ot_id);
      const dep = x.deposito_id || '__sin__';
      if (ajenos.has(dep)) continue; // depósito de otro campo: el usuario no lo ve
      const k = x.insumo_id + '|' + dep;
      tot[k] = (tot[k] || 0) + cant;
    }
    const nOts = conPendientes.size;
    res.json({
      lineas: Object.keys(tot).map(k => {
        const i = k.indexOf('|');
        return { insumoId: k.slice(0, i), depositoId: k.slice(i + 1), cant: tot[k] };
      }),
      nOts: nOts
    });
  } catch (err) {
    console.error('/api/ordenes-trabajo/comprometido-otros-campos GET error:', err);
    res.status(500).json({ error: 'Error interno del servidor' });
  }
});

app.post('/api/ordenes-trabajo', async (req, res) => {
  const o = req.body || {};
  const empresaId = o.empresaId;
  const client = await pool.connect();
  try {
    const sesion = await obtenerSesion(req);
    if (!sesion) { return res.status(401).json({ error: 'No autenticado' }); }
    if (!empresaId) { return res.status(400).json({ error: 'Falta empresaId' }); }
    const permiso = await obtenerPermiso(req, empresaId);
    if (!permiso) { return res.status(403).json({ error: 'Sin acceso a esta empresa' }); }
    if (!puedeEnHerramienta(permiso, 'tablero_insumos_ot', 'cargar')) { return res.status(403).json({ error: 'Tu usuario tiene permiso solo de consulta en esta herramienta.' }); }
    if (destinosAjenos(permiso, o.trabajos).length) { return res.status(403).json({ error: 'La OT tiene lotes de campos que tu usuario no tiene habilitados' }); }
    const errSup = errorSuperficiesOt(o.trabajos);
    if (errSup) { return res.status(400).json({ error: errSup }); }

    await client.query('BEGIN');
    await client.query(
      `INSERT INTO contadores_ot (empresa_id, siguiente) VALUES ($1, 1) ON CONFLICT (empresa_id) DO NOTHING`,
      [empresaId]
    );
    // GREATEST con el máximo existente: si el contador quedó atrasado (restore,
    // limpieza a mano), se corrige solo en vez de chocar con un número ya usado.
    const numRes = await client.query(
      `UPDATE contadores_ot
          SET siguiente = GREATEST(siguiente,
                (SELECT COALESCE(FLOOR(MAX(num)), 0) + 1 FROM ordenes_trabajo WHERE empresa_id = $1)) + 1
        WHERE empresa_id = $1
        RETURNING siguiente - 1 AS num`,
      [empresaId]
    );
    const num = numRes.rows[0].num;
    const id = o.id || ('ot_' + Date.now());
    await client.query(
      `INSERT INTO ordenes_trabajo (id, empresa_id, num, campania_id, fecha, obs, estado, ultimo_registro, impresa, rapida)
       VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)`,
      [id, empresaId, num, o.campaniaId || null, o.fecha || null, o.obs || null, o.estado || 'Pendiente',
       o.ultimoRegistro ? JSON.stringify(o.ultimoRegistro) : null, !!o.impresa, !!o.rapida]
    );
    const trabajos = await _guardarTrabajosOt(client, id, empresaId, o.trabajos);
    await client.query('COMMIT');
    res.status(201).json({ id, num, empresaId, campaniaId: o.campaniaId || null, fecha: o.fecha || null,
      obs: o.obs || null, estado: o.estado || 'Pendiente', impresa: !!o.impresa, rapida: !!o.rapida, trabajos });
  } catch (err) {
    await client.query('ROLLBACK').catch(() => {});
    console.error('/api/ordenes-trabajo POST error:', err);
    const msg = fkViolation(err);
    if (msg) return res.status(409).json({ error: msg });
    res.status(500).json({ error: 'Error interno del servidor' });
  } finally {
    client.release();
  }
});

app.put('/api/ordenes-trabajo/:id', async (req, res) => {
  const o = req.body || {};
  const empresaId = o.empresaId;
  const client = await pool.connect();
  try {
    const sesion = await obtenerSesion(req);
    if (!sesion) { return res.status(401).json({ error: 'No autenticado' }); }
    if (!empresaId) { return res.status(400).json({ error: 'Falta empresaId' }); }
    const permiso = await obtenerPermiso(req, empresaId);
    if (!permiso) { return res.status(403).json({ error: 'Sin acceso a esta empresa' }); }
    if (!puedeEnHerramienta(permiso, 'tablero_insumos_ot', 'cargar')) { return res.status(403).json({ error: 'Tu usuario tiene permiso solo de consulta en esta herramienta.' }); }
    const bloqueo = await verificarLockPropio('ordenes_trabajo', req.params.id, sesion);
    if (bloqueo) { return res.status(409).json({ error: 'Lo está editando ' + bloqueo.usuarioNombre }); }
    if ((permiso.campoIds || []).length) {
      // Los lotes de campos ajenos de una OT mixta tienen que llegar los mismos que estaban.
      const previos = await trabajosGuardadosDeOt(client, req.params.id, empresaId);
      if (!otVisibleParaPermiso(permiso, previos) ||
          destinosAjenos(permiso, previos).join(',') !== destinosAjenos(permiso, o.trabajos).join(',')) {
        return res.status(403).json({ error: 'La OT tiene lotes de campos que tu usuario no tiene habilitados' });
      }
    }

    const errSup = errorSuperficiesOt(o.trabajos);
    if (errSup) { return res.status(400).json({ error: errSup }); }

    await client.query('BEGIN');
    const upd = await client.query(
      `UPDATE ordenes_trabajo SET campania_id=$3, fecha=$4, obs=$5, estado=$6, ultimo_registro=$7, impresa=$8
        WHERE id=$1 AND empresa_id=$2`,
      [req.params.id, empresaId, o.campaniaId || null, o.fecha || null, o.obs || null, o.estado || 'Pendiente',
       o.ultimoRegistro ? JSON.stringify(o.ultimoRegistro) : null, !!o.impresa]
    );
    if (!upd.rowCount) {
      await client.query('ROLLBACK');
      return res.status(404).json({ error: 'La orden de trabajo no existe' });
    }
    const trabajos = await _guardarTrabajosOt(client, req.params.id, empresaId, o.trabajos);
    await client.query('COMMIT');
    res.json({ id: req.params.id, num: o.num, empresaId, campaniaId: o.campaniaId || null,
      fecha: o.fecha || null, obs: o.obs || null, estado: o.estado || 'Pendiente', trabajos });
  } catch (err) {
    await client.query('ROLLBACK').catch(() => {});
    console.error('/api/ordenes-trabajo PUT error:', err);
    const msg = fkViolation(err);
    if (msg) return res.status(409).json({ error: msg });
    res.status(500).json({ error: 'Error interno del servidor' });
  } finally {
    client.release();
  }
});

app.delete('/api/ordenes-trabajo/:id', async (req, res) => {
  try {
    const sesion = await obtenerSesion(req);
    if (!sesion) return res.status(401).json({ error: 'No autenticado' });
    const empresaId = req.query.empresaId;
    if (!empresaId) return res.status(400).json({ error: 'Falta empresaId' });
    const permiso = await obtenerPermiso(req, empresaId);
    if (!permiso) return res.status(403).json({ error: 'Sin acceso a esta empresa' });
    if (!puedeEnHerramienta(permiso, 'tablero_insumos_ot', 'cargar')) { return res.status(403).json({ error: 'Tu usuario tiene permiso solo de consulta en esta herramienta.' }); }
    const bloqueo = await verificarLockPropio('ordenes_trabajo', req.params.id, sesion);
    if (bloqueo) return res.status(409).json({ error: 'Lo está editando ' + bloqueo.usuarioNombre });
    if ((permiso.campoIds || []).length &&
        destinosAjenos(permiso, await trabajosGuardadosDeOt(pool, req.params.id, empresaId)).length) {
      return res.status(403).json({ error: 'La OT tiene lotes de campos que tu usuario no tiene habilitados' });
    }

    // ot_trabajos se borra solo (ON DELETE CASCADE). Si alguno de sus trabajos
    // ya generó un comprobante (consumo real de stock), el borrado se
    // rechaza (RESTRICT) — no se puede borrar una orden que ya tuvo
    // movimientos reales.
    await pool.query('DELETE FROM ordenes_trabajo WHERE id=$1 AND empresa_id=$2', [req.params.id, empresaId]);
    res.json({ status: 'ok' });
  } catch (err) {
    console.error('/api/ordenes-trabajo DELETE error:', err);
    const msg = fkViolation(err);
    if (msg) return res.status(409).json({ error: msg });
    res.status(500).json({ error: 'Error interno del servidor' });
  }
});

// ─────────────────────────────────────────────────────────────────────────────
// COMPROBANTES + MOVIMIENTOS (líneas embebidas)
// Un comprobante siempre viaja con sus líneas — se crean/actualizan juntos
// en una transacción. GET devuelve cada comprobante con sus líneas anidadas
// en `lineas`, para reconstruir state.comprobantes/state.movtos en un viaje.
// ─────────────────────────────────────────────────────────────────────────────
app.get('/api/comprobantes', async (req, res) => {
  try {
    const sesion = await obtenerSesion(req);
    if (!sesion) return res.status(401).json({ error: 'No autenticado' });
    const empresaId = req.query.empresaId;
    if (!empresaId) return res.status(400).json({ error: 'Falta empresaId' });
    const permiso = await obtenerPermiso(req, empresaId);
    if (!permiso) return res.status(403).json({ error: 'Sin acceso a esta empresa' });
    if (!puedeEnHerramienta(permiso, 'tablero_insumos_ot', 'ver')) return res.status(403).json({ error: 'Tu usuario no tiene acceso a Registro de Labores e Insumos' });

    const params = [empresaId];
    let sql = `SELECT id, fecha, tipo, comp_tipo AS "compTipo", comp_nro AS "compNro",
                      proveedor_id AS "proveedorId", campania_id AS "campaniaId", obs,
                      ref_ot_trabajo AS "refOtTrabajo", ref_ot_num AS "refOtNum", ref_tanda AS "refTanda"
                 FROM comprobantes WHERE empresa_id = $1`;
    if (req.query.campaniaId) { params.push(req.query.campaniaId); sql += ` AND campania_id = $${params.length}`; }
    const comps = await pool.query(sql, params);

    const movs = await pool.query(
      `SELECT id, comprobante_id AS "comprobanteId", insumo_id AS "insumoId", cantidad AS "cant",
              origen_deposito_id AS "origenId", destino_deposito_id AS "destinoId", ref_destino_id AS "refDest",
              precio, moneda
         FROM movimientos WHERE empresa_id = $1`,
      [empresaId]
    );
    const lineasPorComp = {};
    for (const m of movs.rows) {
      (lineasPorComp[m.comprobanteId] = lineasPorComp[m.comprobanteId] || []).push(m);
    }
    // Usuario con campos restringidos: los comprobantes cuyos movimientos son todos de
    // depósitos de otros campos viajan sin proveedor, número ni observaciones. Las líneas
    // (insumo, cantidad, precio, fecha) hacen falta igual: el precio promedio de cada
    // insumo es de toda la empresa. La pantalla no muestra esos movimientos.
    const ajenos = await depositosAjenos(pool, permiso, empresaId);
    res.json(comps.rows.map(c => {
      const lineas = lineasPorComp[c.id] || [];
      const oculto = ajenos && lineas.length && lineas.every(l => lineaAjena(ajenos, l.origenId, l.destinoId));
      return oculto ? { ...c, proveedorId: null, compNro: null, obs: null, lineas } : { ...c, lineas };
    }));
  } catch (err) {
    console.error('/api/comprobantes GET error:', err);
    res.status(500).json({ error: 'Error interno del servidor' });
  }
});

// Fecha (YYYY-MM-DD) del último cierre de stock de la empresa, o null. Todo lo
// fechado hasta ese día queda cerrado (como bloqueoFecha() del cliente).
async function fechaCierreStock(db, empresaId) {
  const r = await db.query(
    `SELECT to_char(MAX(fecha), 'YYYY-MM-DD') AS f FROM cierres_stock WHERE empresa_id = $1`, [empresaId]);
  return r.rows[0].f || null;
}
function msgCierre(fc) {
  const p = fc.split('-');
  return 'El stock está cerrado al ' + p[2] + '/' + p[1] + '/' + p[0].slice(2) +
    ': no se pueden cargar, editar ni borrar movimientos con fecha anterior o igual.';
}

async function _guardarLineasComprobante(client, compId, empresaId, lineas) {
  await client.query('DELETE FROM movimientos WHERE comprobante_id=$1 AND empresa_id=$2', [compId, empresaId]);
  for (const ln of (lineas || [])) {
    const lnId = ln.id || (compId + '_' + Math.random().toString(36).slice(2, 8));
    await client.query(
      `INSERT INTO movimientos (id, empresa_id, comprobante_id, insumo_id, cantidad, origen_deposito_id, destino_deposito_id, ref_destino_id, precio, moneda)
       VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)`,
      [lnId, empresaId, compId, ln.insumoId, ln.cant || 0, ln.origenId || null, ln.destinoId || null, ln.refDest || null,
       Number(ln.precio) > 0 ? Number(ln.precio) : null, Number(ln.precio) > 0 ? (ln.moneda === 'USD' ? 'USD' : 'ARS') : null]
    );
  }
}

app.post('/api/comprobantes', async (req, res) => {
  const c = req.body || {};
  const empresaId = c.empresaId;
  const client = await pool.connect();
  try {
    const sesion = await obtenerSesion(req);
    if (!sesion) { return res.status(401).json({ error: 'No autenticado' }); }
    if (!empresaId) { return res.status(400).json({ error: 'Falta empresaId' }); }
    const permiso = await obtenerPermiso(req, empresaId);
    if (!permiso) { return res.status(403).json({ error: 'Sin acceso a esta empresa' }); }
    if (!puedeEnHerramienta(permiso, 'tablero_insumos_ot', 'cargar')) { return res.status(403).json({ error: 'Tu usuario tiene permiso solo de consulta en esta herramienta.' }); }

    const ajenosPost = await depositosAjenos(client, permiso, empresaId);
    if ((c.lineas || []).some(l => lineaAjena(ajenosPost, l.origenId, l.destinoId))) { return res.status(403).json({ error: MSG_COMP_AJENO }); }

    const fcPost = await fechaCierreStock(client, empresaId);
    if (fcPost && c.fecha && String(c.fecha).slice(0, 10) <= fcPost) { return res.status(409).json({ error: msgCierre(fcPost) }); }

    const id = c.id || ('comp_' + Date.now());
    await client.query('BEGIN');
    await client.query(
      `INSERT INTO comprobantes (id, empresa_id, fecha, tipo, comp_tipo, comp_nro, proveedor_id, campania_id, obs, ref_ot_trabajo, ref_ot_num, ref_tanda)
       VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12)`,
      [id, empresaId, c.fecha || null, c.tipo || null, c.compTipo || null, c.compNro || null,
       c.proveedorId || null, c.campaniaId || null, c.obs || null, c.refOtTrabajo || null, c.refOtNum || null, c.refTanda || null]
    );
    await _guardarLineasComprobante(client, id, empresaId, c.lineas);
    await client.query('COMMIT');
    res.status(201).json({ ...c, id, empresaId });
  } catch (err) {
    await client.query('ROLLBACK').catch(() => {});
    console.error('/api/comprobantes POST error:', err);
    res.status(500).json({ error: 'Error interno del servidor' });
  } finally {
    client.release();
  }
});

app.put('/api/comprobantes/:id', async (req, res) => {
  const c = req.body || {};
  const empresaId = c.empresaId;
  const client = await pool.connect();
  try {
    const sesion = await obtenerSesion(req);
    if (!sesion) { return res.status(401).json({ error: 'No autenticado' }); }
    if (!empresaId) { return res.status(400).json({ error: 'Falta empresaId' }); }
    const permiso = await obtenerPermiso(req, empresaId);
    if (!permiso) { return res.status(403).json({ error: 'Sin acceso a esta empresa' }); }
    if (!puedeEnHerramienta(permiso, 'tablero_insumos_ot', 'cargar')) { return res.status(403).json({ error: 'Tu usuario tiene permiso solo de consulta en esta herramienta.' }); }
    const bloqueo = await verificarLockPropio('comprobantes', req.params.id, sesion);
    if (bloqueo) { return res.status(409).json({ error: 'Lo está editando ' + bloqueo.usuarioNombre }); }
    // Un comprobante con movimientos de otros campos le llega sin proveedor/número/obs:
    // guardarlo los borraría. Tampoco se pueden agregar movimientos a esos depósitos.
    const ajenosPut = await depositosAjenos(client, permiso, empresaId);
    if ((c.lineas || []).some(l => lineaAjena(ajenosPut, l.origenId, l.destinoId)) ||
        await comprobanteTieneAjenos(client, ajenosPut, req.params.id, empresaId)) {
      return res.status(403).json({ error: MSG_COMP_AJENO });
    }
    const fcPut = await fechaCierreStock(client, empresaId);
    if (fcPut) {
      const ant = await client.query(`SELECT to_char(fecha,'YYYY-MM-DD') AS f FROM comprobantes WHERE id=$1 AND empresa_id=$2`, [req.params.id, empresaId]);
      const fAnt = ant.rows[0] ? ant.rows[0].f : null;
      if ((fAnt && fAnt <= fcPut) || (c.fecha && String(c.fecha).slice(0, 10) <= fcPut)) { return res.status(409).json({ error: msgCierre(fcPut) }); }
    }

    await client.query('BEGIN');
    await client.query(
      `UPDATE comprobantes
          SET fecha=$3, tipo=$4, comp_tipo=$5, comp_nro=$6, proveedor_id=$7, campania_id=$8, obs=$9, ref_ot_trabajo=$10, ref_ot_num=$11, ref_tanda=$12
        WHERE id=$1 AND empresa_id=$2`,
      [req.params.id, empresaId, c.fecha || null, c.tipo || null, c.compTipo || null, c.compNro || null,
       c.proveedorId || null, c.campaniaId || null, c.obs || null, c.refOtTrabajo || null, c.refOtNum || null, c.refTanda || null]
    );
    await _guardarLineasComprobante(client, req.params.id, empresaId, c.lineas);
    await client.query('COMMIT');
    res.json({ ...c, id: req.params.id, empresaId });
  } catch (err) {
    await client.query('ROLLBACK').catch(() => {});
    console.error('/api/comprobantes PUT error:', err);
    res.status(500).json({ error: 'Error interno del servidor' });
  } finally {
    client.release();
  }
});

app.delete('/api/comprobantes/:id', async (req, res) => {
  try {
    const sesion = await obtenerSesion(req);
    if (!sesion) return res.status(401).json({ error: 'No autenticado' });
    const empresaId = req.query.empresaId;
    if (!empresaId) return res.status(400).json({ error: 'Falta empresaId' });
    const permiso = await obtenerPermiso(req, empresaId);
    if (!permiso) return res.status(403).json({ error: 'Sin acceso a esta empresa' });
    if (!puedeEnHerramienta(permiso, 'tablero_insumos_ot', 'cargar')) { return res.status(403).json({ error: 'Tu usuario tiene permiso solo de consulta en esta herramienta.' }); }
    const bloqueo = await verificarLockPropio('comprobantes', req.params.id, sesion);
    if (bloqueo) return res.status(409).json({ error: 'Lo está editando ' + bloqueo.usuarioNombre });

    if (await comprobanteTieneAjenos(pool, await depositosAjenos(pool, permiso, empresaId), req.params.id, empresaId)) {
      return res.status(403).json({ error: MSG_COMP_AJENO });
    }
    const fcDel = await fechaCierreStock(pool, empresaId);
    if (fcDel) {
      const ant = await pool.query(`SELECT to_char(fecha,'YYYY-MM-DD') AS f FROM comprobantes WHERE id=$1 AND empresa_id=$2`, [req.params.id, empresaId]);
      if (ant.rows[0] && ant.rows[0].f && ant.rows[0].f <= fcDel) return res.status(409).json({ error: msgCierre(fcDel) });
    }
    // ON DELETE CASCADE en movimientos se encarga de las líneas.
    await pool.query('DELETE FROM comprobantes WHERE id=$1 AND empresa_id=$2', [req.params.id, empresaId]);
    res.json({ status: 'ok' });
  } catch (err) {
    console.error('/api/comprobantes DELETE error:', err);
    res.status(500).json({ error: 'Error interno del servidor' });
  }
});

// ─────────────────────────────────────────────────────────────────────────────
// DATOS OPERATIVOS DE LABORES E INSUMOS DE UNA EMPRESA
// Lo que borra el Reset del tablero (client-src/2026-10-30: movimientos, OT,
// cierres, TC mensual y tarifas de referencia; los catálogos no se tocan) y
// lo que reemplaza la carga desde Excel antes de escribir lo nuevo.
// ─────────────────────────────────────────────────────────────────────────────
async function borrarOperativoInsumosOt(client, empresaId) {
  const n = {};
  // comprobantes antes que OT: ref_ot_trabajo es ON DELETE RESTRICT.
  n.movimientos = (await client.query('SELECT COUNT(*)::int AS c FROM movimientos WHERE empresa_id=$1', [empresaId])).rows[0].c;
  await client.query('DELETE FROM comprobantes WHERE empresa_id=$1', [empresaId]);
  n.OT = (await client.query('DELETE FROM ordenes_trabajo WHERE empresa_id=$1', [empresaId])).rowCount;
  await client.query('DELETE FROM cierres_stock WHERE empresa_id=$1', [empresaId]);
  await client.query('DELETE FROM tipo_cambio_mensual WHERE empresa_id=$1', [empresaId]);
  await client.query('DELETE FROM tarifas_referencia_labor WHERE empresa_id=$1', [empresaId]);
  await client.query('DELETE FROM contadores_ot WHERE empresa_id=$1', [empresaId]);
  return n;
}

app.delete('/api/insumos-ot/datos', async (req, res) => {
  const empresaId = req.query.empresaId;
  const client = await pool.connect();
  try {
    const sesion = await obtenerSesion(req);
    if (!sesion) { return res.status(401).json({ error: 'No autenticado' }); }
    if (!empresaId) { return res.status(400).json({ error: 'Falta empresaId' }); }
    const permiso = await obtenerPermiso(req, empresaId);
    if (!permiso) { return res.status(403).json({ error: 'Sin acceso a esta empresa' }); }
    if (!puedeEnHerramienta(permiso, 'tablero_insumos_ot', 'administrar')) { return res.status(403).json({ error: 'Esta acción requiere permiso de administrar.' }); }
    await client.query('BEGIN');
    const n = await borrarOperativoInsumosOt(client, empresaId);
    await client.query('COMMIT');
    res.json({ status: 'ok', borrados: n });
  } catch (err) {
    await client.query('ROLLBACK').catch(() => {});
    console.error('/api/insumos-ot/datos DELETE error:', err);
    res.status(500).json({ error: 'Error interno del servidor' });
  } finally {
    client.release();
  }
});

// ─────────────────────────────────────────────────────────────────────────────
// POST /api/carga-excel/registro — carga desde Excel de Labores e Insumos.
// Portado de IMP.aplicar() de client-src/2026-10-30/cargar_datos.html (parte
// "reg"): agrega labores y unidades que falten (globales), REEMPLAZA los
// insumos, depósitos y terceros de la empresa y todo su operativo (OT,
// movimientos, cierres, TC, tarifas). La lectura del Excel sigue en el
// navegador; acá se escribe todo en una transacción.
// ─────────────────────────────────────────────────────────────────────────────
app.post('/api/carga-excel/registro', async (req, res) => {
  const b = req.body || {};
  const empresaId = b.empresaId;
  const client = await pool.connect();
  try {
    const sesion = await obtenerSesion(req);
    if (!sesion) { return res.status(401).json({ error: 'No autenticado' }); }
    if (sesion.rol !== 'admin_general' && sesion.rol !== 'admin_cliente') {
      return res.status(403).json({ error: 'La carga masiva desde Excel la hace un administrador' });
    }
    if (!empresaId) { return res.status(400).json({ error: 'Falta empresaId' }); }
    const permiso = await obtenerPermiso(req, empresaId);
    if (!permiso) { return res.status(403).json({ error: 'Sin acceso a esta empresa' }); }

    const arr = x => (Array.isArray(x) ? x : []);
    const labores = arr(b.labores), unidades = arr(b.unidades), insumos = arr(b.insumos);
    const depositos = arr(b.depositos), terceros = arr(b.terceros), ots = arr(b.ots), comps = arr(b.comprobantes);
    const opIns = {}; for (const o of arr(b.insumosOperativos)) if (o && o.id) opIns[o.id] = o;

    await client.query('BEGIN');

    // Campaña del Excel ('26-27') -> la del catálogo ('26/27', camp_2627).
    const campRes = await client.query('SELECT id, nombre FROM campanias');
    const campPorNombre = {};
    for (const r of campRes.rows) {
      campPorNombre[normalizarNombreCampania(r.id)] = campPorNombre[normalizarNombreCampania(r.id)] || r.id;
      campPorNombre[normalizarNombreCampania(r.nombre)] = r.id;
    }
    async function campaniaReal(c) {
      if (!c) return null;
      const k = normalizarNombreCampania(c);
      if (campPorNombre[k]) return campPorNombre[k];
      const mx = await client.query('SELECT COALESCE(MAX(orden),0)+1 AS o FROM campanias');
      await client.query('INSERT INTO campanias (id, nombre, orden, activa) VALUES ($1,$1,$2,false) ON CONFLICT (id) DO NOTHING', [c, mx.rows[0].o]);
      campPorNombre[k] = c;
      return c;
    }
    const campReg = await campaniaReal(b.campania);

    // Labores y unidades (globales): solo se agregan; si ya hay una con ese nombre/sigla se usa esa.
    const laborIdMap = {};
    for (const l of labores) {
      if (!l || !l.nombre) continue;
      const ex = await client.query('SELECT id FROM labores WHERE trim(lower(nombre)) = trim(lower($1))', [l.nombre]);
      if (ex.rows.length) { laborIdMap[l.id] = ex.rows[0].id; continue; }
      await client.query('INSERT INTO labores (id, nombre, unidad_labor, precio_ref, activo) VALUES ($1,$2,$3,$4,true) ON CONFLICT (id) DO NOTHING',
        [l.id, l.nombre, l.unidadLabor || null, Number(l.precioRef) || 0]);
      laborIdMap[l.id] = l.id;
    }
    const unidadIdMap = {};
    for (const u of unidades) {
      if (!u || !u.sigla) continue;
      const ex = await client.query('SELECT id FROM unidades WHERE trim(lower(sigla)) = trim(lower($1))', [u.sigla]);
      if (ex.rows.length) { unidadIdMap[u.id] = ex.rows[0].id; continue; }
      await client.query('INSERT INTO unidades (id, sigla, nombre, activo) VALUES ($1,$2,$3,true) ON CONFLICT (id) DO NOTHING',
        [u.id, u.sigla, u.nombre || u.sigla]);
      unidadIdMap[u.id] = u.id;
    }

    // Borrar lo de la empresa (operativo primero: movimientos/OT apuntan a los catálogos).
    // % MS (Registro de Pastoreos): el Excel no lo trae; se conserva por id o por nombre + tipo.
    const msPrev = await client.query(
      `SELECT id, lower(trim(datos->>'nombre')) || '|' || coalesce(datos->>'tipo','') AS k, pct_ms FROM insumos WHERE empresa_id=$1 AND pct_ms IS NOT NULL`, [empresaId]);
    const msPorId = {}, msPorNombre = {};
    for (const r of msPrev.rows) { msPorId[r.id] = r.pct_ms; msPorNombre[r.k] = r.pct_ms; }
    const borrados = await borrarOperativoInsumosOt(client, empresaId);
    borrados['insumos'] = (await client.query('DELETE FROM insumos WHERE empresa_id=$1', [empresaId])).rowCount;
    borrados['depósitos'] = (await client.query('DELETE FROM depositos WHERE empresa_id=$1', [empresaId])).rowCount;
    await client.query('DELETE FROM choferes WHERE empresa_id=$1', [empresaId]);
    borrados['terceros'] = (await client.query('DELETE FROM terceros WHERE empresa_id=$1', [empresaId])).rowCount;

    // Como /api/maestros: datos lleva el objeto entero, con su id y empresaId.
    const sinIdEmp = o => ({ ...o, id: o.id, empresaId });
    for (const x of insumos) {
      const d = sinIdEmp(x);
      if (d.unidadId && unidadIdMap[d.unidadId]) d.unidadId = unidadIdMap[d.unidadId];
      const op = opIns[x.id];
      if (op) { if (op.depositoId) d.depositoId = op.depositoId; d.stockMin = Number(op.stockMin) || 0; d.moneda = op.moneda === 'USD' ? 'USD' : 'ARS'; }
      delete d.pctMS;
      const ms = msPorId[x.id] != null ? msPorId[x.id] : msPorNombre[String(d.nombre || '').trim().toLowerCase() + '|' + (d.tipo || '')];
      await client.query('INSERT INTO insumos (id, empresa_id, datos, pct_ms) VALUES ($1,$2,$3,$4)', [x.id, empresaId, d, ms != null ? ms : null]);
    }
    for (const x of depositos) await guardarDeposito(client, sinIdEmp(x));
    for (const x of terceros) await client.query('INSERT INTO terceros (id, empresa_id, datos) VALUES ($1,$2,$3)', [x.id, empresaId, sinIdEmp(x)]);

    // OT con su número del Excel
    let maxNum = 0;
    for (const o of ots) {
      const num = Number(o.num) || 0; if (num > maxNum) maxNum = num;
      await client.query(
        `INSERT INTO ordenes_trabajo (id, empresa_id, num, campania_id, fecha, obs, estado, ultimo_registro, impresa, rapida)
         VALUES ($1,$2,$3,$4,$5,$6,$7,NULL,false,false)`,
        [o.id, empresaId, num, await campaniaReal(o.campaniaId), o.fecha || null, o.obs || null, o.estado || 'Pendiente']
      );
      const trs = arr(o.trabajos).map(t => ({ ...t, laborId: (t.laborId && laborIdMap[t.laborId]) || t.laborId || null }));
      await _guardarTrabajosOt(client, o.id, empresaId, trs);
    }
    await client.query(
      `INSERT INTO contadores_ot (empresa_id, siguiente) VALUES ($1,$2)
       ON CONFLICT (empresa_id) DO UPDATE SET siguiente = EXCLUDED.siguiente`,
      [empresaId, Math.max(Number(b.nextOt) || 0, maxNum + 1)]
    );

    // Comprobantes y movimientos
    let nLineas = 0;
    for (const c of comps) {
      await client.query(
        `INSERT INTO comprobantes (id, empresa_id, fecha, tipo, comp_tipo, comp_nro, proveedor_id, campania_id, obs, ref_ot_trabajo, ref_ot_num, ref_tanda)
         VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12)`,
        [c.id, empresaId, c.fecha || null, c.tipo || null, c.compTipo || null, c.compNro || null, c.proveedorId || null,
         await campaniaReal(c.campaniaId), c.obs || null, c.refOtTrabajo || null, c.refOtNum || null, c.refTanda || null]
      );
      await _guardarLineasComprobante(client, c.id, empresaId, c.lineas);
      nLineas += arr(c.lineas).length;
    }

    // La campaña del Excel pasa a ser la activa (como IMP.aplicar del cliente).
    if (campReg) await client.query('UPDATE campanias SET activa = (id = $1)', [campReg]);

    const informe = b.informe || {};
    await client.query(
      `INSERT INTO cargas_excel (id, empresa_id, usuario_id, partes, resumen, avisos)
       VALUES ($1,$2,$3,$4::jsonb,$5::jsonb,$6::jsonb)`,
      ['carga_' + Date.now(), empresaId, sesion.id, JSON.stringify({ plan: false, reg: true }),
       JSON.stringify(informe.resumen || []), JSON.stringify(informe.avisos || [])]
    );
    await client.query('COMMIT');
    res.json({ status: 'ok', borrados,
      escritos: { insumos: insumos.length, 'depósitos': depositos.length, terceros: terceros.length, OT: ots.length, movimientos: nLineas } });
  } catch (err) {
    await client.query('ROLLBACK').catch(() => {});
    console.error('/api/carga-excel/registro POST error:', err);
    const msgFk = fkViolation(err);
    if (msgFk) return res.status(409).json({ error: msgFk });
    res.status(500).json({ error: 'Error interno del servidor' + (err && err.code === '23505' ? ': hay nombres repetidos en el Excel' : '') });
  } finally {
    client.release();
  }
});

// ─────────────────────────────────────────────────────────────────────────────
// CIERRES DE STOCK (portado de client-src/2026-10-30: openCierreStock /
// confirmarCierreStock / anularUltimoCierre). El cierre y sus comprobantes de
// ajuste se graban en una sola transacción; anular solo se puede con el último.
// ─────────────────────────────────────────────────────────────────────────────
app.get('/api/cierres-stock', async (req, res) => {
  try {
    const sesion = await obtenerSesion(req);
    if (!sesion) return res.status(401).json({ error: 'No autenticado' });
    const empresaId = req.query.empresaId;
    if (!empresaId) return res.status(400).json({ error: 'Falta empresaId' });
    const permiso = await obtenerPermiso(req, empresaId);
    if (!permiso) return res.status(403).json({ error: 'Sin acceso a esta empresa' });
    if (!puedeEnHerramienta(permiso, 'tablero_insumos_ot', 'ver')) return res.status(403).json({ error: 'Tu usuario no tiene acceso a Registro de Labores e Insumos' });
    const r = await pool.query(
      `SELECT id, to_char(fecha,'YYYY-MM-DD') AS fecha, precios, comp_ids AS "compIds",
              to_char(creado_el,'YYYY-MM-DD') AS el, creado_por AS por
         FROM cierres_stock WHERE empresa_id = $1 ORDER BY fecha`, [empresaId]);
    res.json(r.rows);
  } catch (err) {
    console.error('/api/cierres-stock GET error:', err);
    res.status(500).json({ error: 'Error interno del servidor' });
  }
});

app.post('/api/cierres-stock', async (req, res) => {
  const b = req.body || {};
  const empresaId = b.empresaId;
  const client = await pool.connect();
  try {
    const sesion = await obtenerSesion(req);
    if (!sesion) { return res.status(401).json({ error: 'No autenticado' }); }
    if (!empresaId) { return res.status(400).json({ error: 'Falta empresaId' }); }
    const permiso = await obtenerPermiso(req, empresaId);
    if (!permiso) { return res.status(403).json({ error: 'Sin acceso a esta empresa' }); }
    if (!puedeEnHerramienta(permiso, 'tablero_insumos_ot', 'administrar')) { return res.status(403).json({ error: 'Esta acción requiere permiso de administrar.' }); }
    const fecha = String(b.fecha || '').slice(0, 10);
    if (!/^\d{4}-\d{2}-\d{2}$/.test(fecha)) { return res.status(400).json({ error: 'Falta la fecha del cierre' }); }

    await client.query('BEGIN');
    // Serializa cierres concurrentes de la misma empresa.
    await client.query('SELECT pg_advisory_xact_lock(hashtext($1))', ['cierre_stock:' + empresaId]);
    const fc = await fechaCierreStock(client, empresaId);
    if (fc && fecha <= fc) {
      await client.query('ROLLBACK'); return res.status(409).json({ error: 'La fecha tiene que ser posterior al último cierre (' + fc + ').' });
    }
    const comps = Array.isArray(b.comprobantes) ? b.comprobantes : [];
    const compIds = [];
    for (const c of comps) {
      const cid = c.id || ('comp_' + Date.now() + '_' + compIds.length);
      await client.query(
        `INSERT INTO comprobantes (id, empresa_id, fecha, tipo, comp_tipo, comp_nro, proveedor_id, campania_id, obs, ref_ot_trabajo, ref_ot_num, ref_tanda)
         VALUES ($1,$2,$3,$4,$5,$6,NULL,NULL,$7,NULL,NULL,NULL)`,
        [cid, empresaId, fecha, c.tipo || null, c.compTipo || 'Cierre', c.compNro || null, c.obs || null]
      );
      await _guardarLineasComprobante(client, cid, empresaId, c.lineas);
      compIds.push(cid);
    }
    const id = b.id || ('cierre_' + Date.now());
    const precios = (b.precios && typeof b.precios === 'object') ? b.precios : {};
    await client.query(
      `INSERT INTO cierres_stock (id, empresa_id, fecha, precios, comp_ids, creado_el, creado_por)
       VALUES ($1,$2,$3,$4::jsonb,$5,CURRENT_DATE,$6)`,
      [id, empresaId, fecha, JSON.stringify(precios), compIds, sesion.nombre || null]
    );
    await client.query('COMMIT');
    res.status(201).json({ id, fecha, precios, compIds, por: sesion.nombre || null });
  } catch (err) {
    await client.query('ROLLBACK').catch(() => {});
    console.error('/api/cierres-stock POST error:', err);
    res.status(500).json({ error: 'Error interno del servidor' });
  } finally {
    client.release();
  }
});

app.delete('/api/cierres-stock/:id', async (req, res) => {
  const empresaId = req.query.empresaId;
  const client = await pool.connect();
  try {
    const sesion = await obtenerSesion(req);
    if (!sesion) { return res.status(401).json({ error: 'No autenticado' }); }
    if (!empresaId) { return res.status(400).json({ error: 'Falta empresaId' }); }
    const permiso = await obtenerPermiso(req, empresaId);
    if (!permiso) { return res.status(403).json({ error: 'Sin acceso a esta empresa' }); }
    if (!puedeEnHerramienta(permiso, 'tablero_insumos_ot', 'administrar')) { return res.status(403).json({ error: 'Esta acción requiere permiso de administrar.' }); }

    await client.query('BEGIN');
    await client.query('SELECT pg_advisory_xact_lock(hashtext($1))', ['cierre_stock:' + empresaId]);
    const ult = await client.query(
      `SELECT id, comp_ids FROM cierres_stock WHERE empresa_id=$1 ORDER BY fecha DESC LIMIT 1`, [empresaId]);
    if (!ult.rows.length || ult.rows[0].id !== req.params.id) {
      await client.query('ROLLBACK'); return res.status(409).json({ error: 'Solo se puede anular el último cierre de stock.' });
    }
    const ids = ult.rows[0].comp_ids || [];
    if (ids.length) await client.query('DELETE FROM comprobantes WHERE empresa_id=$1 AND id = ANY($2)', [empresaId, ids]);
    await client.query('DELETE FROM cierres_stock WHERE id=$1 AND empresa_id=$2', [req.params.id, empresaId]);
    await client.query('COMMIT');
    res.json({ status: 'ok' });
  } catch (err) {
    await client.query('ROLLBACK').catch(() => {});
    console.error('/api/cierres-stock DELETE error:', err);
    res.status(500).json({ error: 'Error interno del servidor' });
  } finally {
    client.release();
  }
});

// ─────────────────────────────────────────────────────────────────────────────
// TARIFAS DE REFERENCIA DE LABOR (por empresa, labor y campaña)
// Es solo una sugerencia para autocompletar al emitir una OT — el valor
// real queda en ot_trabajos.tarifa de cada OT ya emitida, editable ahí.
// GET devuelve { 'laborId||campaniaId': {v, m} }, listo para asignar
// directo a state.tarifasLP en el frontend.
// ─────────────────────────────────────────────────────────────────────────────
app.get('/api/tarifas-referencia-labor', async (req, res) => {
  try {
    const sesion = await obtenerSesion(req);
    if (!sesion) return res.status(401).json({ error: 'No autenticado' });
    const empresaId = req.query.empresaId;
    if (!empresaId) return res.status(400).json({ error: 'Falta empresaId' });
    const permiso = await obtenerPermiso(req, empresaId);
    if (!permiso) return res.status(403).json({ error: 'Sin acceso a esta empresa' });
    if (!puedeEnHerramienta(permiso, 'tablero_insumos_ot', 'ver')) return res.status(403).json({ error: 'Tu usuario no tiene acceso a Registro de Labores e Insumos' });

    const r = await pool.query(
      'SELECT labor_id AS "laborId", campania_id AS "campaniaId", valor, moneda FROM tarifas_referencia_labor WHERE empresa_id = $1',
      [empresaId]
    );
    const out = {};
    r.rows.forEach(row => { out[row.laborId + '||' + row.campaniaId] = { v: Number(row.valor), m: row.moneda }; });
    res.json(out);
  } catch (err) {
    console.error('/api/tarifas-referencia-labor GET error:', err);
    res.status(500).json({ error: 'Error interno del servidor' });
  }
});

app.put('/api/tarifas-referencia-labor', async (req, res) => {
  const c = req.body || {};
  try {
    const sesion = await obtenerSesion(req);
    if (!sesion) return res.status(401).json({ error: 'No autenticado' });
    if (!c.empresaId || !c.laborId || !c.campaniaId) return res.status(400).json({ error: 'Faltan datos' });
    const permiso = await obtenerPermiso(req, c.empresaId);
    if (!permiso) return res.status(403).json({ error: 'Sin acceso a esta empresa' });
    if (permiso.nivel !== 'administrar') return res.status(403).json({ error: 'Sin permiso' });

    await pool.query(
      `INSERT INTO tarifas_referencia_labor (empresa_id, labor_id, campania_id, valor, moneda)
       VALUES ($1,$2,$3,$4,$5)
       ON CONFLICT (empresa_id, labor_id, campania_id) DO UPDATE SET valor=$4, moneda=$5`,
      [c.empresaId, c.laborId, c.campaniaId, c.valor || 0, c.moneda || 'ARS']
    );
    res.json({ status: 'ok' });
  } catch (err) {
    console.error('/api/tarifas-referencia-labor PUT error:', err);
    res.status(500).json({ error: 'Error interno del servidor' });
  }
});

// ─────────────────────────────────────────────────────────────────────────────
// CONFIG OPERATIVA (tipo de cambio por empresa, tablero_insumos_ot)
// tc_usd/tc_apertura/tc_cierre: 3 escalares, un solo "dueño" por empresa —
// bajo riesgo de pisado, sin lock. El tipo de cambio MENSUAL vive aparte, en
// tipo_cambio_mensual (una fila por empresa+mes): antes era un único JSONB
// que se reescribía entero en cada guardado, y con varios usuarios cargando
// meses distintos en simultáneo, guardar pisaba en silencio lo que acababa
// de cargar otro. Guardar un mes ahora es un UPDATE de esa fila puntual.
// ─────────────────────────────────────────────────────────────────────────────
app.get('/api/config-operativa', async (req, res) => {
  try {
    const sesion = await obtenerSesion(req);
    if (!sesion) return res.status(401).json({ error: 'No autenticado' });
    const empresaId = req.query.empresaId;
    if (!empresaId) return res.status(400).json({ error: 'Falta empresaId' });
    const permiso = await obtenerPermiso(req, empresaId);
    if (!permiso) return res.status(403).json({ error: 'Sin acceso a esta empresa' });
    if (!puedeEnHerramienta(permiso, 'tablero_insumos_ot', 'ver')) return res.status(403).json({ error: 'Tu usuario no tiene acceso a Registro de Labores e Insumos' });

    const [rConfig, rMensual] = await Promise.all([
      pool.query(
        `SELECT tc_usd AS "tcUSD", tc_apertura AS "tcApertura", tc_cierre AS "tcCierre"
           FROM config_operativa WHERE empresa_id = $1`,
        [empresaId]
      ),
      pool.query(
        `SELECT anio_mes AS "anioMes", valor FROM tipo_cambio_mensual WHERE empresa_id = $1`,
        [empresaId]
      ),
    ]);
    const base = rConfig.rows[0] || { tcUSD: 1000, tcApertura: 0, tcCierre: 0 };
    const tcMensual = {};
    rMensual.rows.forEach(r => { tcMensual[r.anioMes] = Number(r.valor); });
    res.json({ ...base, tcMensual });
  } catch (err) {
    console.error('/api/config-operativa GET error:', err);
    res.status(500).json({ error: 'Error interno del servidor' });
  }
});

app.put('/api/config-operativa', async (req, res) => {
  const c = req.body || {};
  const empresaId = c.empresaId;
  try {
    const sesion = await obtenerSesion(req);
    if (!sesion) return res.status(401).json({ error: 'No autenticado' });
    if (!empresaId) return res.status(400).json({ error: 'Falta empresaId' });
    const permiso = await obtenerPermiso(req, empresaId);
    if (!permiso) return res.status(403).json({ error: 'Sin acceso a esta empresa' });
    if (!puedeEnHerramienta(permiso, 'tablero_insumos_ot', 'administrar')) { return res.status(403).json({ error: 'Esta acción requiere permiso de administrar.' }); }

    await pool.query(
      `INSERT INTO config_operativa (empresa_id, tc_usd, tc_apertura, tc_cierre)
       VALUES ($1,$2,$3,$4)
       ON CONFLICT (empresa_id) DO UPDATE SET tc_usd=$2, tc_apertura=$3, tc_cierre=$4`,
      [empresaId, c.tcUSD || 1000, c.tcApertura || 0, c.tcCierre || 0]
    );
    res.json({ status: 'ok' });
  } catch (err) {
    console.error('/api/config-operativa PUT error:', err);
    res.status(500).json({ error: 'Error interno del servidor' });
  }
});

// Alta/edición del TC de UN mes puntual — nunca toca los demás meses.
app.put('/api/config-operativa/tc-mensual/:anioMes', async (req, res) => {
  const empresaId = (req.body || {}).empresaId;
  const valor = (req.body || {}).valor;
  try {
    const sesion = await obtenerSesion(req);
    if (!sesion) return res.status(401).json({ error: 'No autenticado' });
    if (!empresaId) return res.status(400).json({ error: 'Falta empresaId' });
    if (valor == null || isNaN(Number(valor)) || Number(valor) <= 0) {
      return res.status(400).json({ error: 'Falta un valor numérico positivo' });
    }
    const permiso = await obtenerPermiso(req, empresaId);
    if (!permiso) return res.status(403).json({ error: 'Sin acceso a esta empresa' });
    if (!puedeEnHerramienta(permiso, 'tablero_insumos_ot', 'administrar')) { return res.status(403).json({ error: 'Esta acción requiere permiso de administrar.' }); }

    await pool.query(
      `INSERT INTO tipo_cambio_mensual (empresa_id, anio_mes, valor)
       VALUES ($1,$2,$3)
       ON CONFLICT (empresa_id, anio_mes) DO UPDATE SET valor = $3`,
      [empresaId, req.params.anioMes, Number(valor)]
    );
    res.json({ status: 'ok' });
  } catch (err) {
    console.error('/api/config-operativa/tc-mensual PUT error:', err);
    res.status(500).json({ error: 'Error interno del servidor' });
  }
});

app.delete('/api/config-operativa/tc-mensual/:anioMes', async (req, res) => {
  const empresaId = req.query.empresaId;
  try {
    const sesion = await obtenerSesion(req);
    if (!sesion) return res.status(401).json({ error: 'No autenticado' });
    if (!empresaId) return res.status(400).json({ error: 'Falta empresaId' });
    const permiso = await obtenerPermiso(req, empresaId);
    if (!permiso) return res.status(403).json({ error: 'Sin acceso a esta empresa' });
    if (!puedeEnHerramienta(permiso, 'tablero_insumos_ot', 'administrar')) { return res.status(403).json({ error: 'Esta acción requiere permiso de administrar.' }); }

    await pool.query(
      'DELETE FROM tipo_cambio_mensual WHERE empresa_id = $1 AND anio_mes = $2',
      [empresaId, req.params.anioMes]
    );
    res.json({ status: 'ok' });
  } catch (err) {
    console.error('/api/config-operativa/tc-mensual DELETE error:', err);
    res.status(500).json({ error: 'Error interno del servidor' });
  }
});

// ─────────────────────────────────────────────────────────────────────────────
// calendario_actividades.html — antes guardaba todo en localStorage (roles y
// actividades elegidas por empresa, tareas marcadas "hecha" por mes); ahora
// persiste en la base para no perderse y compartirse entre usuarios/dispositivos.
app.get('/api/calendario-actividades/config', async (req, res) => {
  try {
    const sesion = await obtenerSesion(req);
    if (!sesion) return res.status(401).json({ error: 'No autenticado' });
    const empresaId = req.query.empresaId;
    if (!empresaId) return res.status(400).json({ error: 'Falta empresaId' });
    const permiso = await obtenerPermiso(req, empresaId);
    if (!permiso) return res.status(403).json({ error: 'Sin acceso a esta empresa' });

    const r = await pool.query(
      `SELECT roles_elegidos AS "rolesElegidos", actividades_elegidas AS "actividadesElegidas"
         FROM calendario_actividades_config WHERE empresa_id = $1`,
      [empresaId]
    );
    res.json(r.rows[0] || { rolesElegidos: [], actividadesElegidas: [] });
  } catch (err) {
    console.error('/api/calendario-actividades/config GET error:', err);
    res.status(500).json({ error: 'Error interno del servidor' });
  }
});

app.put('/api/calendario-actividades/config', async (req, res) => {
  const c = req.body || {};
  const empresaId = c.empresaId;
  try {
    const sesion = await obtenerSesion(req);
    if (!sesion) return res.status(401).json({ error: 'No autenticado' });
    if (!empresaId) return res.status(400).json({ error: 'Falta empresaId' });
    const permiso = await obtenerPermiso(req, empresaId);
    if (!permiso) return res.status(403).json({ error: 'Sin acceso a esta empresa' });

    await pool.query(
      `INSERT INTO calendario_actividades_config (empresa_id, roles_elegidos, actividades_elegidas)
       VALUES ($1, $2::jsonb, $3::jsonb)
       ON CONFLICT (empresa_id) DO UPDATE SET roles_elegidos = $2::jsonb, actividades_elegidas = $3::jsonb`,
      [empresaId, JSON.stringify(c.rolesElegidos || []), JSON.stringify(c.actividadesElegidas || [])]
    );
    res.json({ status: 'ok' });
  } catch (err) {
    console.error('/api/calendario-actividades/config PUT error:', err);
    res.status(500).json({ error: 'Error interno del servidor' });
  }
});

// Devuelve TODAS las tareas marcadas "hecha" de la empresa, agrupadas por mes
// ({ 'YYYY-MM': ['tareaId', ...] }) — el calendario necesita poder mostrar
// cualquier mes/año sin ida y vuelta al servidor por cada click.
app.get('/api/calendario-actividades/hechas', async (req, res) => {
  try {
    const sesion = await obtenerSesion(req);
    if (!sesion) return res.status(401).json({ error: 'No autenticado' });
    const empresaId = req.query.empresaId;
    if (!empresaId) return res.status(400).json({ error: 'Falta empresaId' });
    const permiso = await obtenerPermiso(req, empresaId);
    if (!permiso) return res.status(403).json({ error: 'Sin acceso a esta empresa' });

    const r = await pool.query(
      'SELECT anio_mes AS "anioMes", tarea_id AS "tareaId" FROM calendario_actividades_hechas WHERE empresa_id = $1',
      [empresaId]
    );
    const out = {};
    r.rows.forEach(row => { (out[row.anioMes] = out[row.anioMes] || []).push(row.tareaId); });
    res.json(out);
  } catch (err) {
    console.error('/api/calendario-actividades/hechas GET error:', err);
    res.status(500).json({ error: 'Error interno del servidor' });
  }
});

app.put('/api/calendario-actividades/hechas', async (req, res) => {
  const c = req.body || {};
  try {
    const sesion = await obtenerSesion(req);
    if (!sesion) return res.status(401).json({ error: 'No autenticado' });
    if (!c.empresaId || !c.anioMes || !c.tareaId) return res.status(400).json({ error: 'Faltan datos' });
    const permiso = await obtenerPermiso(req, c.empresaId);
    if (!permiso) return res.status(403).json({ error: 'Sin acceso a esta empresa' });

    await pool.query(
      `INSERT INTO calendario_actividades_hechas (empresa_id, anio_mes, tarea_id)
       VALUES ($1,$2,$3) ON CONFLICT DO NOTHING`,
      [c.empresaId, c.anioMes, c.tareaId]
    );
    res.json({ status: 'ok' });
  } catch (err) {
    console.error('/api/calendario-actividades/hechas PUT error:', err);
    res.status(500).json({ error: 'Error interno del servidor' });
  }
});

app.delete('/api/calendario-actividades/hechas/:anioMes/:tareaId', async (req, res) => {
  const empresaId = req.query.empresaId;
  try {
    const sesion = await obtenerSesion(req);
    if (!sesion) return res.status(401).json({ error: 'No autenticado' });
    if (!empresaId) return res.status(400).json({ error: 'Falta empresaId' });
    const permiso = await obtenerPermiso(req, empresaId);
    if (!permiso) return res.status(403).json({ error: 'Sin acceso a esta empresa' });

    await pool.query(
      'DELETE FROM calendario_actividades_hechas WHERE empresa_id = $1 AND anio_mes = $2 AND tarea_id = $3',
      [empresaId, req.params.anioMes, req.params.tareaId]
    );
    res.json({ status: 'ok' });
  } catch (err) {
    console.error('/api/calendario-actividades/hechas DELETE error:', err);
    res.status(500).json({ error: 'Error interno del servidor' });
  }
});

// ─────────────────────────────────────────────────────────────────────────────
// ─────────────────────────────────────────────────────────────────────────────
// REGISTRO DE PASTOREOS (registro_pastoreos.html)
// ─────────────────────────────────────────────────────────────────────────────
// El tablero trabaja con los mismos objetos que guardaba en localStorage (claves
// gan_*). El servidor los arma desde tablas en columnas al leer y los desarma al
// guardar: el pastoreo viaja como documento (con sus movimientos y entregas de
// suplemento) y se guarda entero en una transacción.
//
// Permisos (mismo criterio que el tablero): ver para leer, cargar para guardar,
// administrar para borrar y restaurar respaldo; categorías de hacienda solo
// admin_general. Campos: un usuario con campos restringidos ve solo los
// pastoreos de sus campos y no puede guardar nada sobre lotes de otros campos
// (incluye los pases: decisión del cliente, 2026-11-11).
const TOOL_PAST = 'registro_pastoreos';
const MSG_PAST_VER = 'Tu usuario no tiene acceso al Registro de Pastoreos';
const MSG_PAST_CARGAR = 'Tu usuario tiene permiso solo de consulta en el Registro de Pastoreos';
const MSG_PAST_ADM = 'Esta acción requiere permiso de administrar en el Registro de Pastoreos';

// fecha 'YYYY-MM-DD' válida -> [fecha, null]; cualquier otra cosa se conserva como texto
function pastFecha(s) {
  if (s == null || s === '') return [null, null];
  const t = String(s);
  if (/^\d{4}-\d{2}-\d{2}$/.test(t)) {
    const d = new Date(t + 'T00:00:00Z');
    if (!isNaN(d) && d.toISOString().slice(0, 10) === t) return [t, null];
  }
  return [null, t];
}
function pastNum(x) {
  if (x == null || x === '') return null;
  const n = Number(x);
  return isFinite(n) ? n : null;
}
function pastTxt(x) { return x == null ? '' : String(x); }
function pastFechaOut(fecha, txt) {
  if (fecha) return (fecha instanceof Date) ? fecha.toISOString().slice(0, 10) : String(fecha).slice(0, 10);
  return txt || '';
}
function pastIso(t) { return t ? new Date(t).toISOString() : undefined; }

// Contexto común: sesión, permiso y nivel requerido. Devuelve null si ya respondió.
async function pastContexto(req, res, empresaId, nivel) {
  const sesion = await obtenerSesion(req);
  if (!sesion) { res.status(401).json({ error: 'No autenticado' }); return null; }
  if (!empresaId) { res.status(400).json({ error: 'Falta empresaId' }); return null; }
  const permiso = await obtenerPermiso(req, empresaId);
  if (!permiso) { res.status(403).json({ error: 'Sin acceso a esta empresa' }); return null; }
  if (!puedeEnHerramienta(permiso, TOOL_PAST, 'ver')) { res.status(403).json({ error: MSG_PAST_VER }); return null; }
  if (nivel === 'cargar' && !puedeEnHerramienta(permiso, TOOL_PAST, 'cargar')) { res.status(403).json({ error: MSG_PAST_CARGAR }); return null; }
  if (nivel === 'administrar' && !puedeEnHerramienta(permiso, TOOL_PAST, 'administrar')) { res.status(403).json({ error: MSG_PAST_ADM }); return null; }
  return { sesion, permiso };
}

// Lotes de campos que el usuario no tiene habilitados, entre los indicados.
// Devuelve [] si no tiene restricción de campos.
async function pastLotesAjenos(db, permiso, empresaId, loteIds) {
  if (!(permiso.campoIds || []).length) return [];
  const ids = (loteIds || []).filter(Boolean);
  if (!ids.length) return [];
  const r = await db.query(
    `SELECT l.id, l.nombre, l.campo_id, c.nombre AS campo FROM lotes l LEFT JOIN campos c ON c.id = l.campo_id
      WHERE l.empresa_id = $1 AND l.id = ANY($2::text[])`, [empresaId, ids]);
  return r.rows.filter(x => !campoHabilitado(permiso, x.campo_id));
}
function pastMsgAjenos(ajenos) {
  const campos = [...new Set(ajenos.map(x => x.campo || x.campo_id))].join(', ');
  return 'No tenés permiso sobre el campo ' + campos + ' (lote ' + ajenos.map(x => x.nombre).join(', ') +
    '). Pedile al administrador acceso a todos los campos que manejás.';
}
function lotesDeDoc(d) {
  const ls = (d && Array.isArray(d.loteIds) && d.loteIds.length) ? d.loteIds : [d && d.loteId];
  return ls.filter(Boolean);
}

// ── Lectura: arma los "documentos" gan_* que espera el tablero ───────────────
async function pastLeerPastoreos(db, empresaId, permiso) {
  const ps = await db.query(
    `SELECT id, campania_id, campo_id, lote_id, lote_ids, num, tipo_actividad_id, origen, importado, creado
       FROM pastoreos WHERE empresa_id = $1 ORDER BY lote_id, num`, [empresaId]);
  const visibles = ps.rows.filter(p => campoHabilitado(permiso, p.campo_id));
  if (!visibles.length) return [];
  const ids = visibles.map(p => p.id);
  const [mv, sp, sc] = await Promise.all([
    db.query(`SELECT * FROM pastoreo_movimientos WHERE empresa_id = $1 AND pastoreo_id = ANY($2::text[]) ORDER BY pastoreo_id, orden`, [empresaId, ids]),
    db.query(`SELECT * FROM pastoreo_suplementos WHERE empresa_id = $1 AND pastoreo_id = ANY($2::text[]) ORDER BY pastoreo_id, orden`, [empresaId, ids]),
    db.query(`SELECT * FROM pastoreo_suplemento_componentes WHERE empresa_id = $1 AND pastoreo_id = ANY($2::text[]) ORDER BY pastoreo_id, suplemento_id, orden`, [empresaId, ids]),
  ]);
  const comps = {};
  for (const c of sc.rows) {
    const k = c.pastoreo_id + '|' + c.suplemento_id;
    (comps[k] = comps[k] || []).push({ insumoId: c.insumo_id, pctIncl: pastNum(c.pct_incl), pctMS: pastNum(c.pct_ms) });
  }
  const docs = {};
  for (const p of visibles) {
    const d = {
      id: p.id, empresaId, campaniaId: p.campania_id, campoId: p.campo_id, loteId: p.lote_id,
      loteIds: (p.lote_ids && p.lote_ids.length) ? p.lote_ids : null, num: p.num,
      tipoActividadId: p.tipo_actividad_id, movs: [], supl: [],
    };
    if (p.origen) d.origen = p.origen;
    if (p.importado) d.importado = true;
    if (p.creado) d.creado = pastIso(p.creado);
    docs[p.id] = d;
  }
  for (const m of mv.rows) {
    const d = docs[m.pastoreo_id]; if (!d) continue;
    const o = { id: m.id, fecha: pastFechaOut(m.fecha, m.fecha_txt), tipo: m.tipo, categoriaId: m.categoria_id,
      cab: pastNum(m.cab), kg: pastNum(m.kg), obs: m.obs };
    if (m.rodeo_id) o.rodeoId = m.rodeo_id;
    if (m.cambio_id) o.cambioId = m.cambio_id;
    if (m.cierra) o.cierra = true;
    d.movs.push(o);
  }
  for (const s of sp.rows) {
    const d = docs[s.pastoreo_id]; if (!d) continue;
    const o = { id: s.id, fecha: pastFechaOut(s.fecha, s.fecha_txt), kgTC: pastNum(s.kg_tc), obs: s.obs };
    if (s.insumo_id) o.insumoId = s.insumo_id;
    if (s.racion_id) { o.racionId = s.racion_id; o.comp = comps[s.pastoreo_id + '|' + s.id] || []; }
    if (s.racion_nombre != null) o.racionNombre = s.racion_nombre;
    if (s.pct_ms != null) o.pctMS = pastNum(s.pct_ms);
    if (s.humedad != null) o.humedad = pastNum(s.humedad);
    if (s.remito != null) o.remito = s.remito;
    d.supl.push(o);
  }
  return Object.values(docs);
}

async function pastLeerTodo(db, empresaId, permiso) {
  const filtra = (permiso.campoIds || []).length > 0;
  const lotesOk = filtra
    ? (await db.query('SELECT id FROM lotes WHERE empresa_id = $1 AND (campo_id IS NULL OR campo_id = ANY($2::text[]))', [empresaId, permiso.campoIds])).rows.map(r => r.id)
    : null;
  const loteVisible = id => !lotesOk || lotesOk.indexOf(id) !== -1;
  await db.query(
    `INSERT INTO negocios_ganaderos (id, empresa_id, nombre, activo)
     SELECT $2, $1, 'Campo', true WHERE NOT EXISTS (SELECT 1 FROM negocios_ganaderos WHERE empresa_id = $1)
     ON CONFLICT DO NOTHING`, [empresaId, 'neg_' + empresaId + '_campo']);
  const [pastoreos, cats, negs, rods, racs, rcomp, ms, sup, rec, tas, cfg, pend] = await Promise.all([
    pastLeerPastoreos(db, empresaId, permiso),
    db.query('SELECT id, nombre, orden, activo FROM categorias_hacienda ORDER BY orden, nombre'),
    db.query('SELECT id, nombre, activo FROM negocios_ganaderos WHERE empresa_id = $1 ORDER BY nombre', [empresaId]),
    db.query('SELECT * FROM rodeos WHERE empresa_id = $1 ORDER BY nombre', [empresaId]),
    db.query('SELECT * FROM raciones WHERE empresa_id = $1 ORDER BY nombre', [empresaId]),
    db.query('SELECT racion_id, insumo_id, pct_incl FROM racion_componentes WHERE empresa_id = $1 ORDER BY racion_id, orden', [empresaId]),
    db.query('SELECT id, pct_ms FROM insumos WHERE empresa_id = $1 AND pct_ms IS NOT NULL', [empresaId]),
    db.query('SELECT campania_id, lote_id, ganadera FROM pastoreo_superficie WHERE empresa_id = $1', [empresaId]),
    db.query('SELECT campania_id, lote_id, tipo_actividad_id FROM pastoreo_recurso WHERE empresa_id = $1', [empresaId]),
    db.query('SELECT tipo_actividad_id, tcb, fecha FROM pastoreo_tasas WHERE empresa_id = $1', [empresaId]),
    db.query('SELECT datos FROM pastoreo_config WHERE empresa_id = $1', [empresaId]),
    db.query('SELECT items FROM pastoreo_pendientes WHERE empresa_id = $1', [empresaId]),
  ]);
  const compsPorRac = {};
  for (const c of rcomp.rows) (compsPorRac[c.racion_id] = compsPorRac[c.racion_id] || []).push({ insumoId: c.insumo_id, pctIncl: pastNum(c.pct_incl) });
  return {
    gan_pastoreos: pastoreos,
    gan_categorias: cats.rows.map(c => ({ id: c.id, nombre: c.nombre, orden: c.orden, activo: c.activo })),
    gan_negocios: negs.rows.map(n => ({ id: n.id, empresaId, nombre: n.nombre, activo: n.activo })),
    gan_rodeos: rods.rows.map(r => ({ id: r.id, empresaId, negocioId: r.negocio_id, nombre: r.nombre, activo: r.activo, obs: r.obs,
      creado: pastIso(r.creado), actualizado: pastIso(r.actualizado) })),
    gan_raciones: racs.rows.map(r => ({ id: r.id, empresaId, nombre: r.nombre, componentes: compsPorRac[r.id] || [], activa: r.activa,
      obs: r.obs, creado: pastIso(r.creado), actualizado: pastIso(r.actualizado) })),
    gan_insumos_ms: ms.rows.map(r => ({ empresaId, insumoId: r.id, pctMS: pastNum(r.pct_ms) })),
    gan_superficie: sup.rows.filter(r => loteVisible(r.lote_id)).map(r => ({ empresaId, campaniaId: r.campania_id, loteId: r.lote_id, ganadera: r.ganadera })),
    gan_recurso: rec.rows.filter(r => loteVisible(r.lote_id)).map(r => ({ empresaId, campaniaId: r.campania_id, loteId: r.lote_id, tipoActividadId: r.tipo_actividad_id })),
    gan_tasas: tas.rows.map(r => ({ empresaId, tipoActividadId: r.tipo_actividad_id, tcb: pastNum(r.tcb), fecha: pastFechaOut(r.fecha, null) })),
    gan_cfg: cfg.rows.length ? [Object.assign({}, cfg.rows[0].datos, { empresaId })] : [],
    gan_pendientes: pend.rows.length ? [{ empresaId, items: pend.rows[0].items || [] }] : [],
  };
}

app.get('/api/pastoreos/datos', async (req, res) => {
  try {
    const empresaId = req.query.empresaId;
    const c = await pastContexto(req, res, empresaId, 'ver'); if (!c) return;
    res.json(await pastLeerTodo(pool, empresaId, c.permiso));
  } catch (err) {
    console.error('/api/pastoreos/datos GET error:', err);
    res.status(500).json({ error: 'Error interno del servidor' });
  }
});

// ── Escritura de un pastoreo (documento completo) ────────────────────────────
async function pastEscribir(db, empresaId, d) {
  const lotes = lotesDeDoc(d);
  if (!d.id) throw Object.assign(new Error('pastoreo sin id'), { http: 400, msg: 'Pastoreo sin identificador' });
  if (!lotes.length) throw Object.assign(new Error('pastoreo sin lote'), { http: 400, msg: 'El pastoreo no tiene lote' });
  const lr = await db.query('SELECT campo_id FROM lotes WHERE id = $1 AND empresa_id = $2', [d.loteId || lotes[0], empresaId]);
  const campoId = lr.rows.length ? lr.rows[0].campo_id : (d.campoId || null);
  await db.query(
    `INSERT INTO pastoreos (id, empresa_id, campania_id, campo_id, lote_id, lote_ids, num, tipo_actividad_id, origen, importado, creado, actualizado)
     VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$11,$10, now())
     ON CONFLICT (id, empresa_id) DO UPDATE SET campania_id=$3, campo_id=$4, lote_id=$5, lote_ids=$6, num=$7,
       tipo_actividad_id=$8, origen=$9, importado=$11, creado=COALESCE(pastoreos.creado, $10), actualizado=now()`,
    [d.id, empresaId, d.campaniaId || null, campoId, d.loteId || lotes[0],
     (Array.isArray(d.loteIds) && d.loteIds.length) ? d.loteIds : null,
     pastNum(d.num) != null ? Math.round(pastNum(d.num)) : null, d.tipoActividadId || null, pastTxt(d.origen),
     d.creado || null, d.importado === true]);
  // hijos: se reemplazan enteros (el documento es la verdad)
  await db.query('DELETE FROM pastoreo_movimientos WHERE pastoreo_id = $1 AND empresa_id = $2', [d.id, empresaId]);
  await db.query('DELETE FROM pastoreo_suplementos WHERE pastoreo_id = $1 AND empresa_id = $2', [d.id, empresaId]);
  const movs = Array.isArray(d.movs) ? d.movs : [];
  for (let i = 0; i < movs.length; i++) {
    const m = movs[i] || {};
    const f = pastFecha(m.fecha);
    await db.query(
      `INSERT INTO pastoreo_movimientos (pastoreo_id, empresa_id, id, orden, fecha, fecha_txt, tipo, categoria_id, rodeo_id, cab, kg, obs, cambio_id, cierra)
       VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14)`,
      [d.id, empresaId, m.id || ('m' + i), i, f[0], f[1], pastTxt(m.tipo), m.categoriaId || null, m.rodeoId || null,
       pastNum(m.cab), pastNum(m.kg), pastTxt(m.obs), m.cambioId || null, m.cierra === true]);
  }
  const supl = Array.isArray(d.supl) ? d.supl : [];
  for (let i = 0; i < supl.length; i++) {
    const s = supl[i] || {};
    const f = pastFecha(s.fecha), sid = s.id || ('s' + i);
    await db.query(
      `INSERT INTO pastoreo_suplementos (pastoreo_id, empresa_id, id, orden, fecha, fecha_txt, insumo_id, racion_id, racion_nombre, kg_tc, pct_ms, humedad, remito, obs)
       VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14)`,
      [d.id, empresaId, sid, i, f[0], f[1], s.insumoId || null, s.racionId || null,
       s.racionNombre != null ? String(s.racionNombre) : null, pastNum(s.kgTC), pastNum(s.pctMS), pastNum(s.humedad),
       s.remito != null ? String(s.remito) : null, pastTxt(s.obs)]);
    const comp = Array.isArray(s.comp) ? s.comp : [];
    for (let j = 0; j < comp.length; j++) {
      const c = comp[j] || {};
      if (!c.insumoId) continue;
      await db.query(
        `INSERT INTO pastoreo_suplemento_componentes (pastoreo_id, empresa_id, suplemento_id, orden, insumo_id, pct_incl, pct_ms)
         VALUES ($1,$2,$3,$4,$5,$6,$7)`,
        [d.id, empresaId, sid, j, c.insumoId, pastNum(c.pctIncl), pastNum(c.pctMS)]);
    }
  }
}

function pastError(res, err, donde) {
  if (err && err.http) return res.status(err.http).json({ error: err.msg });
  const u = uniqueViolation(err); if (u) return res.status(409).json({ error: u });
  if (err && err.code === '23503') {
    const c = String(err.constraint || '');
    const msg = /categoria/.test(c) ? 'Hay movimientos con una categoría de hacienda que no existe en el sistema'
      : /rodeo/.test(c) ? 'Hay movimientos con un rodeo que no existe o que no se puede borrar porque tiene movimientos'
      : /negocio/.test(c) ? 'La unidad de negocio tiene rodeos: dala de baja en lugar de eliminarla'
      : /campania/.test(c) ? 'La campaña no existe en el sistema'
      : (fkViolation(err) || 'Hay datos asociados que lo impiden');
    return res.status(409).json({ error: msg });
  }
  if (err && (err.code === '22P02' || err.code === '22003' || err.code === '23514' || err.code === '22007' || err.code === '22008'))
    return res.status(400).json({ error: 'Hay un dato con formato inválido' });
  console.error(donde + ' error:', err);
  return res.status(500).json({ error: 'Error interno del servidor' });
}

// Guarda uno o varios pastoreos en una transacción (un pase escribe el origen y
// el destino juntos). importacion=true: carga única del histórico, solo
// admin_general y solo si la empresa todavía no tiene pastoreos.
app.post('/api/pastoreos/guardar', async (req, res) => {
  const b = req.body || {}, empresaId = b.empresaId;
  const c = await pastContexto(req, res, empresaId, 'cargar').catch(err => { pastError(res, err, '/api/pastoreos/guardar'); return null; });
  if (!c) return;
  const docs = Array.isArray(b.docs) ? b.docs : [];
  if (!docs.length) return res.status(400).json({ error: 'No hay pastoreos para guardar' });
  const client = await pool.connect();
  try {
    if (b.importacion) {
      if (c.sesion.rol !== 'admin_general') return res.status(403).json({ error: 'La carga del histórico la hace el equipo Puntal' });
      const ya = await client.query('SELECT 1 FROM pastoreos WHERE empresa_id = $1 LIMIT 1', [empresaId]);
      if (ya.rows.length) return res.status(409).json({ error: 'Esta empresa ya tiene pastoreos: el histórico se importa una sola vez' });
    }
    // campos: los lotes nuevos y los que ya tenía cada pastoreo tienen que ser de campos habilitados
    const ids = docs.map(d => d && d.id).filter(Boolean);
    const prev = ids.length ? await client.query('SELECT lote_id, lote_ids FROM pastoreos WHERE empresa_id = $1 AND id = ANY($2::text[])', [empresaId, ids]) : { rows: [] };
    let lotes = [];
    for (const d of docs) lotes = lotes.concat(lotesDeDoc(d));
    for (const p of prev.rows) lotes = lotes.concat(p.lote_ids && p.lote_ids.length ? p.lote_ids : [p.lote_id]);
    const ajenos = await pastLotesAjenos(client, c.permiso, empresaId, [...new Set(lotes)]);
    if (ajenos.length) return res.status(403).json({ error: pastMsgAjenos(ajenos) });

    await client.query('BEGIN');
    for (const d of docs) await pastEscribir(client, empresaId, d);
    if (b.importacion && b.pendientes) {
      await client.query(
        `INSERT INTO pastoreo_pendientes (empresa_id, items) VALUES ($1, $2::jsonb)
         ON CONFLICT (empresa_id) DO UPDATE SET items = $2::jsonb`, [empresaId, JSON.stringify(b.pendientes.items || [])]);
    }
    if (b.importacion && Array.isArray(b.insumosMs)) {
      for (const x of b.insumosMs) {
        if (!x || !x.insumoId || pastNum(x.pctMS) == null) continue;
        await client.query('UPDATE insumos SET pct_ms = $3 WHERE id = $1 AND empresa_id = $2 AND pct_ms IS NULL', [x.insumoId, empresaId, pastNum(x.pctMS)]);
      }
    }
    await client.query('COMMIT');
    res.json({ status: 'ok', guardados: docs.length });
  } catch (err) {
    await client.query('ROLLBACK').catch(() => {});
    pastError(res, err, '/api/pastoreos/guardar');
  } finally {
    client.release();
  }
});

app.delete('/api/pastoreos/:id', async (req, res) => {
  const empresaId = req.query.empresaId;
  try {
    const c = await pastContexto(req, res, empresaId, 'administrar'); if (!c) return;
    const p = await pool.query('SELECT lote_id, lote_ids FROM pastoreos WHERE id = $1 AND empresa_id = $2', [req.params.id, empresaId]);
    if (!p.rows.length) return res.status(404).json({ error: 'El pastoreo no existe' });
    const ajenos = await pastLotesAjenos(pool, c.permiso, empresaId, p.rows[0].lote_ids && p.rows[0].lote_ids.length ? p.rows[0].lote_ids : [p.rows[0].lote_id]);
    if (ajenos.length) return res.status(403).json({ error: pastMsgAjenos(ajenos) });
    await pool.query('DELETE FROM pastoreos WHERE id = $1 AND empresa_id = $2', [req.params.id, empresaId]);
    res.json({ status: 'ok' });
  } catch (err) { pastError(res, err, '/api/pastoreos DELETE'); }
});

// ── Catálogos y correcciones (una fila por llamada) ──────────────────────────
// POST /api/pastoreos/:col          { empresaId, rec }     alta o modificación
// DELETE /api/pastoreos/:col/borrar { empresaId, ... }     baja (POST, la clave puede ser compuesta)
const PAST_COLS = {
  categorias: {
    nivel: 'cargar', soloAdminGeneral: true,
    async guardar(db, emp, r) {
      if (!r.id || !String(r.nombre || '').trim()) throw Object.assign(new Error(), { http: 400, msg: 'Escribí un nombre.' });
      await db.query(`INSERT INTO categorias_hacienda (id, nombre, orden, activo) VALUES ($1,$2,$3,$4)
                      ON CONFLICT (id) DO UPDATE SET nombre=$2, orden=$3, activo=$4`,
        [r.id, String(r.nombre).trim(), Math.round(pastNum(r.orden) || 0), r.activo !== false]);
    },
    async borrar(db, emp, k) {
      const u = await db.query('SELECT 1 FROM pastoreo_movimientos WHERE categoria_id = $1 LIMIT 1', [k.id]);
      if (u.rows.length) throw Object.assign(new Error(), { http: 409, msg: 'La categoría tiene movimientos en alguna empresa: dala de baja en lugar de eliminarla.' });
      await db.query('DELETE FROM categorias_hacienda WHERE id = $1', [k.id]);
    },
  },
  negocios: {
    nivel: 'cargar',
    async guardar(db, emp, r) {
      if (!r.id || !String(r.nombre || '').trim()) throw Object.assign(new Error(), { http: 400, msg: 'Escribí un nombre.' });
      await db.query(`INSERT INTO negocios_ganaderos (id, empresa_id, nombre, activo) VALUES ($1,$2,$3,$4)
                      ON CONFLICT (id, empresa_id) DO UPDATE SET nombre=$3, activo=$4`,
        [r.id, emp, String(r.nombre).trim(), r.activo !== false]);
    },
    async borrar(db, emp, k) { await db.query('DELETE FROM negocios_ganaderos WHERE id = $1 AND empresa_id = $2', [k.id, emp]); },
  },
  rodeos: {
    nivel: 'cargar',
    async guardar(db, emp, r) {
      if (!r.id || !String(r.nombre || '').trim()) throw Object.assign(new Error(), { http: 400, msg: 'Escribí un nombre.' });
      if (!r.negocioId) throw Object.assign(new Error(), { http: 400, msg: 'Elegí la unidad de negocio.' });
      await db.query(`INSERT INTO rodeos (id, empresa_id, negocio_id, nombre, activo, obs, creado, actualizado) VALUES ($1,$2,$3,$4,$5,$6,$7,$8)
                      ON CONFLICT (id, empresa_id) DO UPDATE SET negocio_id=$3, nombre=$4, activo=$5, obs=$6, actualizado=$8`,
        [r.id, emp, r.negocioId, String(r.nombre).trim(), r.activo !== false, pastTxt(r.obs), r.creado || new Date().toISOString(), r.actualizado || new Date().toISOString()]);
    },
    async borrar(db, emp, k) { await db.query('DELETE FROM rodeos WHERE id = $1 AND empresa_id = $2', [k.id, emp]); },
  },
  raciones: {
    nivel: 'cargar',
    async guardar(db, emp, r) {
      if (!r.id || !String(r.nombre || '').trim()) throw Object.assign(new Error(), { http: 400, msg: 'Escribí un nombre.' });
      await db.query(`INSERT INTO raciones (id, empresa_id, nombre, activa, obs, creado, actualizado) VALUES ($1,$2,$3,$4,$5,$6,$7)
                      ON CONFLICT (id, empresa_id) DO UPDATE SET nombre=$3, activa=$4, obs=$5, actualizado=$7`,
        [r.id, emp, String(r.nombre).trim(), r.activa !== false, pastTxt(r.obs), r.creado || new Date().toISOString(), r.actualizado || new Date().toISOString()]);
      await db.query('DELETE FROM racion_componentes WHERE racion_id = $1 AND empresa_id = $2', [r.id, emp]);
      const cs = Array.isArray(r.componentes) ? r.componentes : [];
      for (let i = 0; i < cs.length; i++) {
        if (!cs[i] || !cs[i].insumoId) continue;
        await db.query('INSERT INTO racion_componentes (racion_id, empresa_id, orden, insumo_id, pct_incl) VALUES ($1,$2,$3,$4,$5)',
          [r.id, emp, i, cs[i].insumoId, pastNum(cs[i].pctIncl)]);
      }
    },
    async borrar(db, emp, k) {
      const u = await db.query('SELECT 1 FROM pastoreo_suplementos WHERE racion_id = $1 AND empresa_id = $2 LIMIT 1', [k.id, emp]);
      if (u.rows.length) throw Object.assign(new Error(), { http: 409, msg: 'Tiene entregas: dala de baja en lugar de eliminarla.' });
      await db.query('DELETE FROM raciones WHERE id = $1 AND empresa_id = $2', [k.id, emp]);
    },
  },
  // % MS: dato del insumo; lo carga cualquiera con "cargar" en la herramienta (decisión del cliente)
  'insumos-ms': {
    nivel: 'cargar', borrarNivel: 'cargar',
    async guardar(db, emp, r) {
      const pm = pastNum(r.pctMS);
      if (pm == null || pm <= 0 || pm > 100) throw Object.assign(new Error(), { http: 400, msg: 'El % MS tiene que estar entre 1 y 100.' });
      const u = await db.query('UPDATE insumos SET pct_ms = $3 WHERE id = $1 AND empresa_id = $2', [r.insumoId, emp, pm]);
      if (!u.rowCount) throw Object.assign(new Error(), { http: 404, msg: 'El insumo no existe' });
    },
    async borrar(db, emp, k) { await db.query('UPDATE insumos SET pct_ms = NULL WHERE id = $1 AND empresa_id = $2', [k.insumoId, emp]); },
  },
  superficie: {
    nivel: 'cargar', borrarNivel: 'cargar', porLote: true,
    async guardar(db, emp, r) {
      await db.query(`INSERT INTO pastoreo_superficie (empresa_id, campania_id, lote_id, ganadera) VALUES ($1,$2,$3,$4)
                      ON CONFLICT (empresa_id, campania_id, lote_id) DO UPDATE SET ganadera=$4`, [emp, r.campaniaId, r.loteId, r.ganadera === true]);
    },
    async borrar(db, emp, k) { await db.query('DELETE FROM pastoreo_superficie WHERE empresa_id=$1 AND campania_id=$2 AND lote_id=$3', [emp, k.campaniaId, k.loteId]); },
  },
  recurso: {
    nivel: 'cargar', borrarNivel: 'cargar', porLote: true,
    async guardar(db, emp, r) {
      if (!r.tipoActividadId) throw Object.assign(new Error(), { http: 400, msg: 'Elegí el recurso.' });
      await db.query(`INSERT INTO pastoreo_recurso (empresa_id, campania_id, lote_id, tipo_actividad_id) VALUES ($1,$2,$3,$4)
                      ON CONFLICT (empresa_id, campania_id, lote_id) DO UPDATE SET tipo_actividad_id=$4`, [emp, r.campaniaId, r.loteId, r.tipoActividadId]);
    },
    async borrar(db, emp, k) { await db.query('DELETE FROM pastoreo_recurso WHERE empresa_id=$1 AND campania_id=$2 AND lote_id=$3', [emp, k.campaniaId, k.loteId]); },
  },
  tasas: {
    nivel: 'cargar', borrarNivel: 'cargar',
    async guardar(db, emp, r) {
      const v = pastNum(r.tcb);
      if (v == null || v < 0 || v > 300) throw Object.assign(new Error(), { http: 400, msg: 'La tasa de crecimiento tiene que estar entre 0 y 300 kg MS/ha/día.' });
      await db.query(`INSERT INTO pastoreo_tasas (empresa_id, tipo_actividad_id, tcb, fecha) VALUES ($1,$2,$3,$4)
                      ON CONFLICT (empresa_id, tipo_actividad_id) DO UPDATE SET tcb=$3, fecha=$4`, [emp, r.tipoActividadId, v, pastFecha(r.fecha)[0]]);
    },
    async borrar(db, emp, k) { await db.query('DELETE FROM pastoreo_tasas WHERE empresa_id=$1 AND tipo_actividad_id=$2', [emp, k.tipoActividadId]); },
  },
  config: {
    nivel: 'cargar',
    async guardar(db, emp, r) {
      const d = Object.assign({}, r); delete d.empresaId;
      await db.query(`INSERT INTO pastoreo_config (empresa_id, datos) VALUES ($1,$2::jsonb)
                      ON CONFLICT (empresa_id) DO UPDATE SET datos=$2::jsonb`, [emp, JSON.stringify(d)]);
    },
  },
  pendientes: {
    nivel: 'cargar',
    async guardar(db, emp, r) {
      await db.query(`INSERT INTO pastoreo_pendientes (empresa_id, items) VALUES ($1,$2::jsonb)
                      ON CONFLICT (empresa_id) DO UPDATE SET items=$2::jsonb`, [emp, JSON.stringify(Array.isArray(r.items) ? r.items : [])]);
    },
  },
};

app.post('/api/pastoreos/catalogo/:col', async (req, res) => {
  const b = req.body || {}, empresaId = b.empresaId, cfg = PAST_COLS[req.params.col];
  try {
    if (!cfg) return res.status(404).json({ error: 'Colección desconocida' });
    const c = await pastContexto(req, res, empresaId, cfg.nivel); if (!c) return;
    if (cfg.soloAdminGeneral && c.sesion.rol !== 'admin_general')
      return res.status(403).json({ error: 'Las categorías de hacienda son generales: solo el equipo Puntal las crea o modifica.' });
    const r = b.rec || {};
    if (cfg.porLote) {
      const ajenos = await pastLotesAjenos(pool, c.permiso, empresaId, [r.loteId]);
      if (ajenos.length) return res.status(403).json({ error: pastMsgAjenos(ajenos) });
    }
    await cfg.guardar(pool, empresaId, r);
    res.json({ status: 'ok' });
  } catch (err) { pastError(res, err, '/api/pastoreos/catalogo/' + req.params.col); }
});

app.post('/api/pastoreos/catalogo/:col/borrar', async (req, res) => {
  const b = req.body || {}, empresaId = b.empresaId, cfg = PAST_COLS[req.params.col];
  try {
    if (!cfg || !cfg.borrar) return res.status(404).json({ error: 'Colección desconocida' });
    const c = await pastContexto(req, res, empresaId, cfg.borrarNivel || 'administrar'); if (!c) return;
    if (cfg.soloAdminGeneral && c.sesion.rol !== 'admin_general')
      return res.status(403).json({ error: 'Las categorías de hacienda son generales: solo el equipo Puntal las crea o modifica.' });
    const k = b.clave || {};
    if (cfg.porLote) {
      const ajenos = await pastLotesAjenos(pool, c.permiso, empresaId, [k.loteId]);
      if (ajenos.length) return res.status(403).json({ error: pastMsgAjenos(ajenos) });
    }
    await cfg.borrar(pool, empresaId, k);
    res.json({ status: 'ok' });
  } catch (err) { pastError(res, err, '/api/pastoreos/catalogo/' + req.params.col + '/borrar'); }
});

// Restaurar un respaldo descargado desde el tablero: reemplaza los datos propios
// de la empresa en una transacción. Las categorías solo las agrega o modifica
// admin_general. Para usuarios con campos restringidos no se permite (pisaría
// pastoreos de campos que no ve).
app.post('/api/pastoreos/restaurar', async (req, res) => {
  const b = req.body || {}, empresaId = b.empresaId, d = b.datos || {};
  const c = await pastContexto(req, res, empresaId, 'administrar').catch(err => { pastError(res, err, '/api/pastoreos/restaurar'); return null; });
  if (!c) return;
  if ((c.permiso.campoIds || []).length) return res.status(403).json({ error: 'Para restaurar un respaldo necesitás acceso a todos los campos de la empresa.' });
  const arr = k => (Array.isArray(d[k]) ? d[k] : []).filter(x => x && x.empresaId === empresaId);
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    if (c.sesion.rol === 'admin_general' && Array.isArray(d.gan_categorias)) {
      for (const x of d.gan_categorias) if (x && x.id && x.nombre) await PAST_COLS.categorias.guardar(client, empresaId, x);
    }
    for (const t of ['pastoreos', 'raciones', 'rodeos', 'negocios_ganaderos', 'pastoreo_superficie', 'pastoreo_recurso',
                     'pastoreo_tasas', 'pastoreo_config', 'pastoreo_pendientes'])
      await client.query('DELETE FROM ' + t + ' WHERE empresa_id = $1', [empresaId]);
    await client.query('UPDATE insumos SET pct_ms = NULL WHERE empresa_id = $1', [empresaId]);
    for (const x of arr('gan_negocios')) await PAST_COLS.negocios.guardar(client, empresaId, x);
    for (const x of arr('gan_rodeos')) await PAST_COLS.rodeos.guardar(client, empresaId, x);
    for (const x of arr('gan_raciones')) await PAST_COLS.raciones.guardar(client, empresaId, x);
    for (const x of arr('gan_insumos_ms')) {
      const pm = pastNum(x.pctMS != null ? x.pctMS : (typeof x.humedad === 'number' ? Math.round((1 - x.humedad) * 10000) / 100 : null));
      if (pm != null && pm > 0 && pm <= 100) await client.query('UPDATE insumos SET pct_ms = $3 WHERE id = $1 AND empresa_id = $2', [x.insumoId, empresaId, pm]);
    }
    for (const x of arr('gan_superficie')) await PAST_COLS.superficie.guardar(client, empresaId, x);
    for (const x of arr('gan_recurso')) if (x.tipoActividadId) await PAST_COLS.recurso.guardar(client, empresaId, x);
    for (const x of arr('gan_tasas')) if (pastNum(x.tcb) != null) await PAST_COLS.tasas.guardar(client, empresaId, x);
    const cf = arr('gan_cfg'); if (cf.length) await PAST_COLS.config.guardar(client, empresaId, cf[0]);
    const pe = arr('gan_pendientes'); if (pe.length) await PAST_COLS.pendientes.guardar(client, empresaId, pe[0]);
    for (const x of arr('gan_pastoreos')) await pastEscribir(client, empresaId, x);
    await client.query('COMMIT');
    res.json({ status: 'ok', pastoreos: arr('gan_pastoreos').length });
  } catch (err) {
    await client.query('ROLLBACK').catch(() => {});
    pastError(res, err, '/api/pastoreos/restaurar');
  } finally {
    client.release();
  }
});

const PORT = process.env.PORT || 8080;
app.listen(PORT, () => console.log(`PA API lista en puerto ${PORT}`));
