-- =============================================================================
-- init.sql — Puntal Agro · Esquema PostgreSQL
-- =============================================================================
-- Ejecutado automáticamente por postgres:16-alpine al crear el volumen.
-- Requiere: base de datos "puntal_agro" creada vía POSTGRES_DB en docker-compose.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- SECCIÓN 1: LISTAS GLOBALES (mantenidas por Puntal, no por los clientes)
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE campanias (
    id      TEXT PRIMARY KEY,
    nombre  TEXT NOT NULL,
    orden   INT  NOT NULL DEFAULT 0,
    activa  BOOLEAN NOT NULL DEFAULT false
);
CREATE UNIQUE INDEX uq_campanias_nombre ON campanias (trim(lower(nombre)));

CREATE TABLE especies (
    id     TEXT PRIMARY KEY,
    nombre TEXT NOT NULL,
    sigla  TEXT,
    activo BOOLEAN NOT NULL DEFAULT true
);
CREATE UNIQUE INDEX uq_especies_nombre ON especies (trim(lower(nombre)));

CREATE TABLE unidades (
    id     TEXT PRIMARY KEY,
    sigla  TEXT NOT NULL,
    nombre TEXT,
    activo BOOLEAN NOT NULL DEFAULT true
);
CREATE UNIQUE INDEX uq_unidades_sigla ON unidades (trim(lower(sigla)));

-- sistema: HRAC (herbicidas), IRAC (insecticidas), FRAC (fungicidas)
CREATE TABLE modos_accion (
    id          TEXT PRIMARY KEY,
    sistema     TEXT NOT NULL CHECK (sistema IN ('HRAC','IRAC','FRAC')),
    codigo      TEXT NOT NULL,
    descripcion TEXT,
    activo      BOOLEAN NOT NULL DEFAULT true
);
CREATE UNIQUE INDEX uq_modos_accion_sistema_codigo ON modos_accion (sistema, trim(lower(codigo)));

CREATE TABLE tipos_proveedor (
    id     TEXT PRIMARY KEY,
    nombre TEXT NOT NULL
);
CREATE UNIQUE INDEX uq_tipos_proveedor_nombre ON tipos_proveedor (trim(lower(nombre)));

-- Labores: lista global; el tipo LP/LC se define al emitir la OT
CREATE TABLE labores (
    id           TEXT PRIMARY KEY,
    nombre       TEXT NOT NULL,
    unidad_labor TEXT,
    precio_ref   NUMERIC(12,2) DEFAULT 0,
    activo       BOOLEAN NOT NULL DEFAULT true
);
CREATE UNIQUE INDEX uq_labores_nombre ON labores (trim(lower(nombre)));

CREATE TABLE herramientas (
    id             TEXT PRIMARY KEY,
    nombre         TEXT NOT NULL,
    descripcion    TEXT,
    tipo           TEXT NOT NULL DEFAULT 'propia' CHECK (tipo IN ('propia','externa')),
    url            TEXT,
    dominio        TEXT,
    -- Solo usadas por tipo='externa': fuente (texto libre, ej. "Simpleza",
    -- "CREA"), rango de vigencia para mostrar/ocultar en el inicio (NULL =
    -- sin límite en ese extremo), y orden de aparición en la grilla.
    fuente         TEXT,
    vigencia_desde DATE,
    vigencia_hasta DATE,
    orden          INTEGER NOT NULL DEFAULT 0,
    activa         BOOLEAN NOT NULL DEFAULT true,
    asignable      BOOLEAN NOT NULL DEFAULT true
);

-- Categorías de insumo (global, confirmado por el cliente 2026-07-21 — ver
-- decision_catalogos_insumos_por_empresa en la memoria del proyecto).
-- fito=true dispara composición de principios activos/EIQ/formulación;
-- subcat=true dispara el selector de subcategoría (hoy solo Coadyuvantes).
CREATE TABLE categorias_insumo (
    id     TEXT PRIMARY KEY,
    codigo TEXT NOT NULL,
    label  TEXT NOT NULL,
    base   BOOLEAN NOT NULL DEFAULT false,
    fito   BOOLEAN NOT NULL DEFAULT false,
    subcat BOOLEAN NOT NULL DEFAULT false,
    activo BOOLEAN NOT NULL DEFAULT true
);
CREATE UNIQUE INDEX uq_categorias_insumo_codigo ON categorias_insumo (trim(lower(codigo)));

-- Usos (cultivo / unidad de negocio — global). color: usado por tablero_uso_suelo
-- para pintar los KPIs/composición por uso sin depender de una clase CSS fija.
CREATE TABLE usos_actividad (
    id     TEXT PRIMARY KEY,
    codigo TEXT NOT NULL,
    label  TEXT NOT NULL,
    color  TEXT,
    activo BOOLEAN NOT NULL DEFAULT true
);
CREATE UNIQUE INDEX uq_usos_actividad_codigo ON usos_actividad (trim(lower(codigo)));

-- Tenencia de la tierra (global). Régimen de tenencia por actividad
-- (Propio/Tomado en alquiler/Cedido en alquiler/Convenio), usado por
-- tablero_uso_suelo para clasificar composición y reportes.
CREATE TABLE tenencias (
    id     TEXT PRIMARY KEY,
    nombre TEXT NOT NULL,
    activo BOOLEAN NOT NULL DEFAULT true
);
CREATE UNIQUE INDEX uq_tenencias_nombre ON tenencias (trim(lower(nombre)));

-- Formulaciones (orden de mezclado en tanque — global)
CREATE TABLE formulaciones (
    id          TEXT PRIMARY KEY,
    codigo      TEXT,
    descripcion TEXT NOT NULL,
    orden       INTEGER NOT NULL DEFAULT 0,
    activo      BOOLEAN NOT NULL DEFAULT true
);
CREATE UNIQUE INDEX uq_formulaciones_descripcion ON formulaciones (trim(lower(descripcion)));

-- Principios activos (global). eiq NULL = N/D (feromonas, biológicos,
-- coadyuvantes: suman 0 al EIQ total del insumo).
CREATE TABLE principios_activos (
    id     TEXT PRIMARY KEY,
    nombre TEXT NOT NULL,
    eiq    NUMERIC(6,2),
    uso    TEXT,
    activo BOOLEAN NOT NULL DEFAULT true
);
CREATE UNIQUE INDEX uq_principios_activos_nombre ON principios_activos (trim(lower(nombre)));

-- ─────────────────────────────────────────────────────────────────────────────
-- SECCIÓN 2: JERARQUÍA CLIENTE → EMPRESA → CAMPO → LOTE
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE clientes (
    id                    TEXT PRIMARY KEY,
    nombre                TEXT NOT NULL,
    email                 TEXT,
    telefono              TEXT,
    nombre_contacto       TEXT,
    activo                BOOLEAN NOT NULL DEFAULT true,
    fecha_alta            DATE DEFAULT CURRENT_DATE,
    cuit                  TEXT,
    razon_social          TEXT,
    direccion             TEXT,
    factura_centralizada  BOOLEAN NOT NULL DEFAULT true
);
CREATE UNIQUE INDEX uq_clientes_nombre ON clientes (trim(lower(nombre)));
-- CUIT es opcional pero, si se carga, tiene que ser único (índice parcial:
-- no evalúa filas con cuit NULL o vacío).
CREATE UNIQUE INDEX uq_clientes_cuit ON clientes (cuit) WHERE cuit IS NOT NULL AND cuit <> '';

CREATE TABLE empresas (
    id           TEXT PRIMARY KEY,
    cliente_id   TEXT NOT NULL REFERENCES clientes(id) ON DELETE RESTRICT,
    razon_social TEXT NOT NULL,
    cuit         TEXT,
    direccion    TEXT,
    condicion_iva TEXT,
    activo       BOOLEAN NOT NULL DEFAULT true
);
CREATE UNIQUE INDEX uq_empresas_rs_cliente ON empresas (cliente_id, trim(lower(razon_social)));
CREATE UNIQUE INDEX uq_empresas_cuit ON empresas (cuit) WHERE cuit IS NOT NULL AND cuit <> '';

CREATE TABLE campos (
    id         TEXT PRIMARY KEY,
    empresa_id TEXT NOT NULL REFERENCES empresas(id) ON DELETE CASCADE,
    nombre     TEXT NOT NULL,
    localidad  TEXT,
    partido    TEXT,
    provincia  TEXT,
    ha_totales NUMERIC(10,2)
);
CREATE UNIQUE INDEX uq_campos_nombre_empresa ON campos (empresa_id, trim(lower(nombre)));

CREATE TABLE lotes (
    id            TEXT PRIMARY KEY,
    campo_id      TEXT REFERENCES campos(id) ON DELETE CASCADE,
    empresa_id    TEXT NOT NULL REFERENCES empresas(id),
    nombre        TEXT,
    ha            NUMERIC(10,2),
    -- Atributos propios del Plan de Uso del Suelo (tablero_uso_suelo.html).
    -- Antes vivían en un blob JSON aparte (tabla tableros); se traen acá para
    -- poder validar/consultar por SQL (ver decision_tablas_independientes_por_tablero).
    ambiente      TEXT,                          -- código de ambientes.datos->>'codigo'
    explotable    NUMERIC(10,2),                 -- NULL = pendiente de carga (no es 0)
    activo        BOOLEAN NOT NULL DEFAULT true,
    tipo_override TEXT                           -- 'AGR'/'GAN' manual; NULL = usar el sugerido
);
-- Único por empresa (no por campo): así lo valida hoy el frontend
-- (tablero_uso_suelo.html compara contra TODOS los lotes de la empresa).
CREATE UNIQUE INDEX uq_lotes_nombre_empresa ON lotes (empresa_id, trim(lower(nombre)));

-- ─────────────────────────────────────────────────────────────────────────────
-- SECCIÓN 3: USUARIOS, SESIONES Y PERMISOS
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE usuarios (
    id            TEXT PRIMARY KEY,
    nombre        TEXT NOT NULL,
    email         TEXT NOT NULL,
    password_hash TEXT,
    rol           TEXT NOT NULL DEFAULT 'usuario'
                      CHECK (rol IN ('admin_general','admin_cliente','usuario')),
    cliente_id    TEXT REFERENCES clientes(id),
    activo        BOOLEAN NOT NULL DEFAULT true
);
-- trim(lower(...)) porque /api/auth/login busca así (email.trim().toLowerCase());
-- server.js normaliza el email antes de guardar para que siempre coincidan.
CREATE UNIQUE INDEX uq_usuarios_email ON usuarios (trim(lower(email)));

CREATE TABLE sesiones (
    token              TEXT PRIMARY KEY,
    usuario_id         TEXT NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,
    creada_en          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expira_en          TIMESTAMPTZ,
    empresa_id_activa  TEXT REFERENCES empresas(id) ON DELETE SET NULL
);

-- Un usuario tiene UN permiso por empresa. campoIds=[] significa todos los campos.
CREATE TABLE permisos (
    id           SERIAL PRIMARY KEY,
    usuario_id   TEXT NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,
    empresa_id   TEXT NOT NULL REFERENCES empresas(id) ON DELETE CASCADE,
    campo_ids    TEXT[]  NOT NULL DEFAULT '{}',
    herramientas TEXT[]  NOT NULL DEFAULT '{}',
    nivel        TEXT    NOT NULL DEFAULT 'ver'
                     CHECK (nivel IN ('ver','cargar','administrar')),
    UNIQUE (usuario_id, empresa_id)
);

-- Locking pesimista de registros: evita que dos usuarios de la MISMA empresa
-- pisen el mismo registro editando a la vez (concurrencia entre empresas
-- distintas ya está resuelta por el aislamiento fila-por-fila del resto del
-- esquema). 'tabla' es un identificador lógico del recurso (nombre de
-- colección o namespace tipo 'plan_uso_suelo:lote'), no necesariamente el
-- nombre físico de una tabla. No hace falta empresa_id en la clave: los ids
-- se generan con uid() y ya son únicos entre empresas.
CREATE TABLE registro_locks (
    tabla         TEXT NOT NULL,
    registro_id   TEXT NOT NULL,
    empresa_id    TEXT REFERENCES empresas(id) ON DELETE CASCADE,
    usuario_id    TEXT NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,
    bloqueado_en  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (tabla, registro_id)
);
CREATE INDEX idx_registro_locks_usuario ON registro_locks(usuario_id);

-- ─────────────────────────────────────────────────────────────────────────────
-- SECCIÓN 4: MAESTROS POR EMPRESA
-- Almacenados como JSONB para flexibilidad y compatibilidad con pa-core.js.
-- El id y empresa_id son columnas propias (para índices y FK); el objeto
-- completo también vive en `datos` para simplificar la serialización desde JS.
-- ─────────────────────────────────────────────────────────────────────────────

-- Terceros (proveedores y/o clientes comerciales)
CREATE TABLE terceros (
    id           TEXT NOT NULL,
    empresa_id   TEXT NOT NULL REFERENCES empresas(id) ON DELETE CASCADE,
    datos        JSONB NOT NULL DEFAULT '{}',
    PRIMARY KEY (id, empresa_id)
);
CREATE INDEX idx_terceros_empresa ON terceros(empresa_id);
CREATE UNIQUE INDEX uq_terceros_nombre_empresa ON terceros (empresa_id, trim(lower(datos->>'nombre')));

-- Choferes (pertenecen a un tercero transportista)
CREATE TABLE choferes (
    id           TEXT NOT NULL,
    empresa_id   TEXT NOT NULL REFERENCES empresas(id) ON DELETE CASCADE,
    tercero_id   TEXT NOT NULL,
    datos        JSONB NOT NULL DEFAULT '{}',
    PRIMARY KEY (id, empresa_id),
    FOREIGN KEY (tercero_id, empresa_id) REFERENCES terceros(id, empresa_id) ON DELETE CASCADE
);
CREATE INDEX idx_choferes_empresa ON choferes(empresa_id);
CREATE UNIQUE INDEX uq_choferes_nombre_empresa ON choferes (empresa_id, trim(lower(datos->>'nombre')));

-- Depósitos (de insumos o acopio de granos)
CREATE TABLE depositos (
    id         TEXT NOT NULL,
    empresa_id TEXT NOT NULL REFERENCES empresas(id) ON DELETE CASCADE,
    datos      JSONB NOT NULL DEFAULT '{}',
    PRIMARY KEY (id, empresa_id)
);
CREATE INDEX idx_depositos_empresa ON depositos(empresa_id);
CREATE UNIQUE INDEX uq_depositos_nombre_empresa ON depositos (empresa_id, trim(lower(datos->>'nombre')));

-- Insumos (catálogo unificado agroquímicos + fertilizantes + otros)
CREATE TABLE insumos (
    id         TEXT NOT NULL,
    empresa_id TEXT NOT NULL REFERENCES empresas(id) ON DELETE CASCADE,
    datos      JSONB NOT NULL DEFAULT '{}',
    PRIMARY KEY (id, empresa_id)
);
CREATE INDEX idx_insumos_empresa ON insumos(empresa_id);
CREATE UNIQUE INDEX ux_insumos_empresa_nombre_tipo ON insumos (empresa_id, trim(lower(datos->>'nombre')), trim(datos->>'tipo'));

-- Tipos de actividad (cultivos y usos del suelo, por empresa)
CREATE TABLE tipos_actividad (
    id         TEXT NOT NULL,
    empresa_id TEXT NOT NULL REFERENCES empresas(id) ON DELETE CASCADE,
    datos      JSONB NOT NULL DEFAULT '{}',
    PRIMARY KEY (id, empresa_id)
);
CREATE INDEX idx_tipos_actividad_empresa ON tipos_actividad(empresa_id);
CREATE UNIQUE INDEX uq_tipos_actividad_nombre_empresa ON tipos_actividad (empresa_id, trim(lower(datos->>'nombre')));

-- Catálogo default de cultivos/usos del suelo (global, editable por
-- admin_general en Maestros): plantilla que se copia a tipos_actividad de
-- cada empresa al darse de alta (ver sembrarCultivosDefault() en server.js).
CREATE TABLE cultivos_default (
    id         TEXT PRIMARY KEY,
    sigla      TEXT NOT NULL,
    nombre     TEXT NOT NULL,
    es_cultivo BOOLEAN NOT NULL DEFAULT true,
    actividad  TEXT,               -- código de uso: AGR/GAN/DOB (ver usos_actividad)
    especie_id TEXT REFERENCES especies(id),
    graminea   BOOLEAN,
    default2da BOOLEAN NOT NULL DEFAULT false,
    activo     BOOLEAN NOT NULL DEFAULT true
);
CREATE UNIQUE INDEX uq_cultivos_default_sigla ON cultivos_default (trim(upper(sigla)));

-- Ambientes (clasificación de lotes por potencial productivo, por empresa;
-- código, descripción, tipo sugerido AGR/GAN/OTRO y color de UI)
CREATE TABLE ambientes (
    id         TEXT NOT NULL,
    empresa_id TEXT NOT NULL REFERENCES empresas(id) ON DELETE CASCADE,
    datos      JSONB NOT NULL DEFAULT '{}',
    PRIMARY KEY (id, empresa_id)
);
CREATE INDEX idx_ambientes_empresa ON ambientes(empresa_id);
CREATE UNIQUE INDEX uq_ambientes_codigo_empresa ON ambientes (empresa_id, trim(upper(datos->>'codigo')));

-- Socios (por empresa) — entidad simple agregada por el cliente 2026-07-21
CREATE TABLE socios (
    id         TEXT NOT NULL,
    empresa_id TEXT NOT NULL REFERENCES empresas(id) ON DELETE CASCADE,
    datos      JSONB NOT NULL DEFAULT '{}',
    PRIMARY KEY (id, empresa_id)
);
CREATE INDEX idx_socios_empresa ON socios(empresa_id);
CREATE UNIQUE INDEX uq_socios_nombre_empresa ON socios (empresa_id, trim(lower(datos->>'nombre')));

-- ─────────────────────────────────────────────────────────────────────────────
-- SECCIÓN 5: DATOS OPERATIVOS
-- ─────────────────────────────────────────────────────────────────────────────

-- Actividades (asignación cultivo/uso a lote en campaña; N filas por lote/campaña)
CREATE TABLE actividades (
    id                TEXT NOT NULL,
    empresa_id        TEXT NOT NULL REFERENCES empresas(id),
    lote_id           TEXT REFERENCES lotes(id) ON DELETE CASCADE,
    campania_id       TEXT REFERENCES campanias(id),
    tipo_actividad_id TEXT,
    ha                NUMERIC(10,2),
    es_segunda        BOOLEAN NOT NULL DEFAULT false,
    tenencia_id       TEXT REFERENCES tenencias(id),  -- opcional (tablero_uso_suelo.html)
    PRIMARY KEY (id, empresa_id),
    FOREIGN KEY (tipo_actividad_id, empresa_id) REFERENCES tipos_actividad(id, empresa_id) ON DELETE RESTRICT
);
CREATE INDEX idx_actividades_lote     ON actividades(lote_id, campania_id);
CREATE INDEX idx_actividades_empresa  ON actividades(empresa_id, campania_id);

-- Órdenes de trabajo
-- labor_id/subactividad/tarifa quedan sin usar por el frontend real (la labor
-- se define por lote dentro de destinos[].subact, no a nivel de cabecera) —
-- se conservan por si se necesitan a futuro, no se dropean sin necesidad.
CREATE TABLE ordenes_trabajo (
    id           TEXT NOT NULL,
    empresa_id   TEXT NOT NULL REFERENCES empresas(id) ON DELETE CASCADE,
    num          INTEGER NOT NULL,
    campania_id  TEXT REFERENCES campanias(id),
    fecha        DATE,
    labor_tipo   TEXT CHECK (labor_tipo IN ('LP','LC')),
    labor_id     TEXT REFERENCES labores(id),
    subactividad TEXT,
    tercero_id   TEXT,
    tarifa       NUMERIC(12,2),
    obs          TEXT,
    estado       TEXT NOT NULL DEFAULT 'Pendiente'
                     CHECK (estado IN ('Pendiente','Parcial','Aplicada','Cancelada')),
    estado_fact  TEXT NOT NULL DEFAULT 'Sin facturar'
                     CHECK (estado_fact IN ('Sin facturar','Parcial','Facturado')),
    plantilla    JSONB NOT NULL DEFAULT '[]',
    destinos     JSONB NOT NULL DEFAULT '[]',
    PRIMARY KEY (id, empresa_id),
    FOREIGN KEY (tercero_id, empresa_id) REFERENCES terceros(id, empresa_id) ON DELETE RESTRICT
);
CREATE INDEX idx_ots_empresa ON ordenes_trabajo(empresa_id, campania_id);
CREATE UNIQUE INDEX uq_ordenes_trabajo_num_empresa ON ordenes_trabajo(empresa_id, num);

-- Contador atómico de num de OT (evita la carrera de asignarlo en el cliente).
CREATE TABLE contadores_ot (
    empresa_id TEXT PRIMARY KEY REFERENCES empresas(id) ON DELETE CASCADE,
    siguiente  INTEGER NOT NULL DEFAULT 1
);

-- Comprobantes: cabecera de movimiento, compartida por N líneas (movimientos).
CREATE TABLE comprobantes (
    id           TEXT NOT NULL,
    empresa_id   TEXT NOT NULL REFERENCES empresas(id) ON DELETE CASCADE,
    fecha        DATE,
    tipo         TEXT,
    comp_tipo    TEXT,
    comp_nro     TEXT,
    proveedor_id TEXT,
    campania_id  TEXT REFERENCES campanias(id),
    obs          TEXT,
    ref_ot       TEXT,
    ref_ot_num   INTEGER,
    PRIMARY KEY (id, empresa_id),
    FOREIGN KEY (proveedor_id, empresa_id) REFERENCES terceros(id, empresa_id) ON DELETE RESTRICT,
    FOREIGN KEY (ref_ot, empresa_id)       REFERENCES ordenes_trabajo(id, empresa_id) ON DELETE SET NULL
);
CREATE INDEX idx_comprobantes_empresa ON comprobantes(empresa_id, campania_id);

-- Movimientos de stock: líneas de un comprobante (se generan al confirmar
-- aplicación de OT o al cargar un movimiento manual).
CREATE TABLE movimientos (
    id                   TEXT NOT NULL,
    empresa_id           TEXT NOT NULL REFERENCES empresas(id),
    comprobante_id       TEXT NOT NULL,
    insumo_id            TEXT NOT NULL,
    cantidad             NUMERIC(14,4),
    origen_deposito_id   TEXT,
    destino_deposito_id  TEXT,
    ref_destino_id       TEXT, -- id del destino (lote) dentro del JSONB destinos de la OT, si aplica
    PRIMARY KEY (id, empresa_id),
    FOREIGN KEY (comprobante_id, empresa_id)      REFERENCES comprobantes(id, empresa_id)     ON DELETE CASCADE,
    FOREIGN KEY (insumo_id, empresa_id)           REFERENCES insumos(id, empresa_id)          ON DELETE RESTRICT,
    FOREIGN KEY (origen_deposito_id, empresa_id)  REFERENCES depositos(id, empresa_id)        ON DELETE RESTRICT,
    FOREIGN KEY (destino_deposito_id, empresa_id) REFERENCES depositos(id, empresa_id)        ON DELETE RESTRICT
);
CREATE INDEX idx_movimientos_empresa_insumo ON movimientos(empresa_id, insumo_id);
CREATE INDEX idx_movimientos_comprobante ON movimientos(comprobante_id, empresa_id);

-- Config operativa por empresa (tipo de cambio para valorizar stock). Único
-- resto de config liviana de tablero_insumos_ot que antes vivía en el blob.
CREATE TABLE config_operativa (
    empresa_id  TEXT PRIMARY KEY REFERENCES empresas(id) ON DELETE CASCADE,
    tc_usd      NUMERIC(12,2) DEFAULT 1000,
    tc_apertura NUMERIC(12,2) DEFAULT 0,
    tc_cierre   NUMERIC(12,2) DEFAULT 0
);

-- Tipo de cambio mensual (uno por empresa y mes). Antes era un único JSONB
-- (config_operativa.tc_mensual) que se reescribía entero en cada guardado:
-- con varios usuarios en simultáneo, guardar el TC de un mes podía pisar en
-- silencio el de otro mes que acababa de cargar otro usuario. Cada mes es
-- ahora su propia fila — guardar uno no toca los demás.
CREATE TABLE tipo_cambio_mensual (
    empresa_id TEXT NOT NULL REFERENCES empresas(id) ON DELETE CASCADE,
    anio_mes   TEXT NOT NULL,  -- 'YYYY-MM'
    valor      NUMERIC(12,2) NOT NULL,
    PRIMARY KEY (empresa_id, anio_mes)
);
CREATE INDEX idx_tc_mensual_empresa ON tipo_cambio_mensual(empresa_id);

-- ─────────────────────────────────────────────────────────────────────────────
-- SECCIÓN 7: DATOS INICIALES (SEED)
-- ─────────────────────────────────────────────────────────────────────────────

-- Campañas
INSERT INTO campanias (id, nombre, orden, activa) VALUES
    ('camp_2223', '22/23', 0, false),
    ('camp_2324', '23/24', 1, false),
    ('camp_2425', '24/25', 2, false),
    ('camp_2526', '25/26', 3, true),
    ('camp_2627', '26/27', 4, false),
    ('camp_2728', '27/28', 5, false);

-- Especies / Granos
INSERT INTO especies (id, nombre, sigla) VALUES
    ('esp_0', 'Soja',              'Sj'),
    ('esp_1', 'Maíz',              'Mz'),
    ('esp_2', 'Trigo',             'Tr'),
    ('esp_3', 'Sorgo',             'Sg'),
    ('esp_4', 'Girasol',           'G'),
    ('esp_5', 'Cebada',            'Cb'),
    ('esp_6', 'Avena',             'Av'),
    ('esp_7', 'Maíz Planta Entera','MzPE');

-- Unidades de medida
INSERT INTO unidades (id, sigla, nombre) VALUES
    ('u_1', 'Lt',  'Litros'),
    ('u_2', 'Kg',  'Kilogramos'),
    ('u_3', 'g',   'Gramos'),
    ('u_4', 'cc',  'Centímetros cúbicos'),
    ('u_5', 'ml',  'Mililitros'),
    ('u_6', 'u',   'Unidades'),
    ('u_7', 'tn',  'Toneladas');

-- Tipos de proveedor
INSERT INTO tipos_proveedor (id, nombre) VALUES
    ('tp_1', 'transportista'),
    ('tp_2', 'contratista'),
    ('tp_3', 'prestador de servicios'),
    ('tp_4', 'insumos');

-- Labores (lista global de Puntal)
INSERT INTO labores (id, nombre, precio_ref) VALUES
    ('lab_1',  'Siembra',                    0),
    ('lab_2',  'Pulv. Terrestre',             0),
    ('lab_3',  'Pulv. Aérea',                0),
    ('lab_4',  'Desmalezado',                0),
    ('lab_5',  'Corte-hilerado',             0),
    ('lab_6',  'Enrrollado',                 0),
    ('lab_7',  'Embolsado',                  0),
    ('lab_8',  'Extracción bolsa',           0),
    ('lab_9',  'Clasificación semillas',     0),
    ('lab_10', 'Elaboración ración',         0),
    ('lab_11', 'Distribución ración',        0),
    ('lab_12', 'Gerenciamiento',             0),
    ('lab_13', 'Fertilización líquida',      0),
    ('lab_14', 'Monitoreos',                 0),
    ('lab_15', 'Acarreos',                   0),
    ('lab_16', 'Labor Fardos',               0),
    ('lab_17', 'Disco-Rastra-Rolo',          0),
    ('lab_18', 'Fertilización voleo',        0),
    ('lab_19', 'Rolo triturador',            0);

-- Modos de acción (HRAC / IRAC / FRAC)
INSERT INTO modos_accion (id, sistema, codigo, descripcion) VALUES
    -- HRAC
    ('moa_h01','HRAC','ACCasa',  'Inhibidores de la acetil coenzima-A carboxilasa (ACCasa)'),
    ('moa_h02','HRAC','ALSSulf', 'Inhibidores ALS - Sulfonilureas'),
    ('moa_h03','HRAC','ALSIMI',  'Inhibidores ALS - Imidazolinonas'),
    ('moa_h04','HRAC','InhF2',   'Inhibidores de la fotosíntesis en el fotosistema II'),
    ('moa_h05','HRAC','InhF1',   'Inhibidores del fotosistema I'),
    ('moa_h06','HRAC','PPO',     'Inhibidores de la enzima protoporfirinógeno oxidasa (PPO)'),
    ('moa_h07','HRAC','HPPD',    'Inhibidores de la biosíntesis de carotenoides (HPPD)'),
    ('moa_h08','HRAC','EPSPS',   'Inhibidores de la enzima EPSPS (Glifosato)'),
    ('moa_h09','HRAC','IGS',     'Inhibidores de la glutamino sintetasa'),
    ('moa_h10','HRAC','AuxSin',  'Acción similar al ácido indol acético (auxinas sintéticas)'),
    ('moa_h11','HRAC','IDC',     'Inhibidores de la división celular'),
    ('moa_h12','HRAC','ISC',     'Inhibidores de la síntesis de celulosa'),
    ('moa_h13','HRAC','ISL',     'Inhibidores de la síntesis de lípidos'),
    ('moa_h14','HRAC','ITA',     'Inhibidores del transporte de auxinas'),
    ('moa_h15','HRAC','H-MOAD',  'Modo de acción desconocido (herbicida)'),
    -- IRAC
    ('moa_i01','IRAC','1',       'Inhibidores de la acetilcolinesterasa'),
    ('moa_i02','IRAC','2',       'Antagonistas de canales de sodio'),
    ('moa_i03','IRAC','3',       'Moduladores del canal de sodio'),
    ('moa_i04','IRAC','4',       'Moduladores competitivos del receptor nicotínico de la acetilcolina'),
    ('moa_i05','IRAC','5',       'Moduladores alostéricos del receptor nicotínico de la acetilcolina'),
    ('moa_i06','IRAC','6',       'Moduladores alostéricos del canal de cloro dependiente del glutamato'),
    ('moa_i07','IRAC','28',      'Moduladores del receptor de la rianodina'),
    ('moa_i08','IRAC','F-MOAD',  'Compuestos de modo de acción desconocido (insecticida)'),
    -- FRAC
    ('moa_f01','FRAC','A',       'Metabolismo de ácidos nucleicos'),
    ('moa_f02','FRAC','B',       'Citoesqueleto y proteínas motoras'),
    ('moa_f03','FRAC','C',       'Respiración'),
    ('moa_f04','FRAC','D',       'Síntesis de aminoácidos y proteínas'),
    ('moa_f05','FRAC','E',       'Señal de transducción'),
    ('moa_f06','FRAC','F',       'Síntesis o transporte de lípidos'),
    ('moa_f07','FRAC','G',       'Biosíntesis de esterol en las membranas'),
    ('moa_f08','FRAC','H',       'Biosíntesis de pared celular'),
    ('moa_f09','FRAC','M',       'Químicos con actividad multisitio'),
    ('moa_f10','FRAC','F-MOAD',  'Modo de acción desconocido (fungicida)');

-- Categorías de insumo (global)
INSERT INTO categorias_insumo (id, codigo, label, base, fito, subcat, activo) VALUES
    ('cat_sem',  'SEM',  'Semillas',                   true, false, false, true),
    ('cat_cura', 'CURA', 'Curasemillas e Inoculantes', true, false, false, true),
    ('cat_herb', 'HERB', 'Herbicidas',                 true, true,  false, true),
    ('cat_inse', 'INSE', 'Insecticidas',                true, true,  false, true),
    ('cat_fung', 'FUNG', 'Fungicidas',                  true, true,  false, true),
    ('cat_coad', 'COAD', 'Coadyuvantes y Correctores',  true, false, true,  true),
    ('cat_fert', 'FERT', 'Fertilizantes',               true, false, false, true),
    ('cat_otro', 'OTRO', 'Otros Insumos',               true, false, false, true);

-- Usos (cultivo / unidad de negocio — global)
INSERT INTO usos_actividad (id, codigo, label, color, activo) VALUES
    ('uso_agr', 'AGR', 'Agricultura',      '#4A6533', true),
    ('uso_gan', 'GAN', 'Ganadería',        '#C8642D', true),
    ('uso_dob', 'DOB', 'Doble propósito',  '#2E6E9E', true);

-- Catálogo default de cultivos/usos del suelo: se copia a tipos_actividad de
-- cada empresa nueva al darse de alta (ver sembrarCultivosDefault() en server.js).
INSERT INTO cultivos_default (id, sigla, nombre, es_cultivo, actividad, especie_id, graminea, default2da, activo) VALUES
    ('cd_tr',    'Tr',    'Trigo',                    true,  'AGR', 'esp_2', null,  false, true),
    ('cd_cb',    'Cb',    'Cebada',                    true,  'AGR', 'esp_5', null,  false, true),
    ('cd_av',    'Av',    'Avena',                     true,  'AGR', 'esp_6', null,  false, true),
    ('cd_g',     'G',     'Girasol',                   true,  'AGR', 'esp_4', null,  false, true),
    ('cd_mz',    'Mz',    'Maíz',                      true,  'AGR', 'esp_1', null,  false, true),
    ('cd_mzt',   'MzT',   'Maíz tardío',               true,  'AGR', 'esp_1', null,  false, true),
    ('cd_mz2',   'Mz2ª',  'Maíz 2ª',                   true,  'AGR', 'esp_1', null,  true,  true),
    ('cd_mzspe', 'MzSPE', 'Maíz Silo PE',              true,  'AGR', 'esp_7', null,  false, true),
    ('cd_sj1',   'Sj1ª',  'Soja 1ª',                   true,  'AGR', 'esp_0', false, false, true),
    ('cd_sj2',   'Sj2ª',  'Soja 2ª',                   true,  'AGR', 'esp_0', false, true,  true),
    ('cd_sg',    'Sg',    'Sorgo',                     true,  'AGR', 'esp_3', true,  false, true),
    ('cd_csvg',  'CS-VG', 'Cv. Servicio Vicia-Gram.',  true,  'AGR', null,    null,  false, true),
    ('cd_csg',   'CS-G',  'Cv. Servicio Gramínea',     true,  'AGR', null,    true,  false, true),
    ('cd_vi',    'VI',    'Verdeo invierno',           true,  'GAN', null,    true,  true,  true),
    ('cd_mzp',   'MzP',   'Maíz pastoreo',             true,  'GAN', null,    true,  false, true),
    ('cd_sgf',   'SgF',   'Sorgo forrajero',           true,  'GAN', null,    true,  false, true),
    ('cd_mzd',   'MzD',   'Maíz pastoreo diferido',    true,  'GAN', null,    true,  false, true),
    ('cd_sgd',   'SgD',   'Sorgo pastoreo diferido',   true,  'GAN', null,    true,  false, true),
    ('cd_prg',   'PRG',   'Promoción Rye Grass',       true,  'GAN', null,    true,  false, true),
    ('cd_pi',    'PI',    'Pradera implantada',        true,  'GAN', null,    true,  true,  true),
    ('cd_ppfe',  'PPFe',  'Pradera Festuca',           true,  'GAN', null,    true,  false, true),
    ('cd_ppalf', 'PPAlf', 'Pradera Alfalfa',           true,  'GAN', null,    false, false, true),
    ('cd_ppag',  'PPAg',  'Pradera Agropiro',          true,  'GAN', null,    true,  false, true),
    ('cd_pd',    'PD',    'Pradera degradada',         true,  'GAN', null,    null,  false, true),
    ('cd_cn',    'CN',    'Campo natural',             true,  'GAN', null,    null,  false, true),
    ('cd_cnd',   'CND',   'Campo natural degradado',   true,  'GAN', null,    null,  false, true),
    ('cd_arrto', 'ARRTO', 'Arrendamiento',             false, null,  null,    null,  false, true);

INSERT INTO tenencias (id, nombre, activo) VALUES
    ('ten_prop', 'Propio',                true),
    ('ten_alqt', 'Tomado en alquiler',    true),
    ('ten_alqc', 'Cedido en alquiler',    true),
    ('ten_conv', 'Convenio',              true);

-- Formulaciones (orden de mezclado en tanque — global)
INSERT INTO formulaciones (id, codigo, descripcion, orden, activo) VALUES
    ('f_agua', '',   'Agua (media carga, corrección dureza/pH)',           1,  true),
    ('f_coad', '',   'Coadyuvantes / correctores / secuestrantes',          2,  true),
    ('f_anti', '',   'Antiespumante',                                      3,  true),
    ('f_wp',   'WP', 'Polvos mojables',                                    4,  true),
    ('f_wg',   'WG', 'Gránulos dispersables',                              5,  true),
    ('f_sg',   'SG', 'Gránulos solubles',                                  6,  true),
    ('f_od',   'OD', 'Dispersiones oleosas',                               7,  true),
    ('f_sc',   'SC', 'Suspensiones concentradas',                          8,  true),
    ('f_cs',   'CS', 'Suspensiones de encapsulados (microcápsulas)',       9,  true),
    ('f_se',   'SE', 'Suspo-emulsiones',                                   10, true),
    ('f_ew',   'EW', 'Emulsiones de aceite en agua',                       11, true),
    ('f_ec',   'EC', 'Concentrados emulsionables',                         12, true),
    ('f_sl',   'SL', 'Concentrados / líquidos solubles',                   13, true),
    ('f_acei', '',   'Aceites / surfactantes / adyuvantes finales',        14, true),
    ('f_foli', '',   'Micronutrientes / fertilizantes foliares',           15, true);

-- Principios activos (global, 152 filas — base EIQ Referencia CropLife/SENASA + EIQ Cornell)
INSERT INTO principios_activos (id, nombre, eiq, uso, activo) VALUES
('pa_0', '(E,E)8,10-DODECADIENOL', NULL, 'Feromona (control de plagas)', true),
('pa_1', '(E,Z)7,9-DODECADIENIL ACETATO', NULL, 'Feromona (control de plagas)', true),
('pa_2', '(Z)/(E)-8-DODECENIL ACETATO', NULL, 'Feromona (control de plagas)', true),
('pa_3', '2,4 D', 19.27, 'Herbicida', true),
('pa_4', '2,4-DB', 19.27, 'Herbicida', true),
('pa_5', 'ABAMECTINA', 35.65, 'Insecticida/Acaricida', true),
('pa_6', 'ACEFATO', 18.45, 'Insecticida', true),
('pa_7', 'ACEITE DE SOJA', 5.0, 'Coadyuvante', true),
('pa_8', 'ACEITE MINERAL', 5.0, 'Coadyuvante', true),
('pa_9', 'ACETAMIPRID', 24.83, 'Insecticida', true),
('pa_10', 'ACETOCLOR', 22.0, 'Herbicida', true),
('pa_11', 'ACIDO FOSFORICO', NULL, 'Coadyuvante', true),
('pa_12', 'ACIDO GIBERELICO', 5.0, 'Regulador de crecimiento', true),
('pa_13', 'AFIDOPYROPEN', 18.0, 'Insecticida', true),
('pa_14', 'ALCOHOL GRASO ETOXILADO', NULL, 'Coadyuvante', true),
('pa_15', 'ALCOHOL LAURICO ETOXILADO', NULL, 'Coadyuvante', true),
('pa_16', 'ALCOHOL LINEAL ETOXILADO', NULL, 'Coadyuvante', true),
('pa_17', 'ALCOHOLES GRASOS', NULL, 'Coadyuvante', true),
('pa_18', 'ALFACIPERMETRINA/ALFAMETRINA', 36.71, 'Insecticida', true),
('pa_19', 'ALQUIL ARIL POLIGLICOL ETER', NULL, 'Coadyuvante', true),
('pa_20', 'AMETRINA', 22.0, 'Herbicida', true),
('pa_21', 'ATRAZINA', 22.71, 'Herbicida', true),
('pa_22', 'AZOXISTROBINA', 27.33, 'Fungicida', true),
('pa_23', 'AZUFRE', 33.0, 'Fungicida/Acaricida', true),
('pa_24', 'BACILLUS AMYLOLIQUEFACIENS', NULL, 'Fungicida biológico', true),
('pa_25', 'BACILLUS THURINGIENSIS', NULL, 'Insecticida biológico', true),
('pa_26', 'BACILLUS THURINGIENSIS var AIZAWAI', NULL, 'Insecticida biológico', true),
('pa_27', 'BENAZOLIN ETIL', 20.0, 'Herbicida', true),
('pa_28', 'BENZOATO DE EMAMECTINA', 30.5, 'Insecticida', true),
('pa_29', 'BENZOVINDIFLUPIR', 22.0, 'Fungicida', true),
('pa_30', 'BICICLOPIRONA', 20.0, 'Herbicida', true),
('pa_31', 'BIFENTRIN', 44.43, 'Insecticida', true),
('pa_32', 'BOSCALID', 19.43, 'Fungicida', true),
('pa_33', 'BROMOXINIL', 21.93, 'Herbicida', true),
('pa_34', 'Bacillus Velezensis', NULL, 'Fungicida biológico', true),
('pa_35', 'CAPTAN', 33.0, 'Fungicida', true),
('pa_36', 'CARBARIL', 22.83, 'Insecticida', true),
('pa_37', 'CARBENDAZIM', 33.0, 'Fungicida', true),
('pa_38', 'CARBONATO BASICO DE COBRE', 33.67, 'Fungicida', true),
('pa_39', 'CARFENTRAZONE ETIL', 19.83, 'Herbicida', true),
('pa_40', 'CIPERMETRINA', 36.71, 'Insecticida', true),
('pa_41', 'CIPROCONAZOLE', 21.67, 'Fungicida', true),
('pa_42', 'CLETODIM', 18.93, 'Herbicida', true),
('pa_43', 'CLOMAZONE', 23.13, 'Herbicida', true),
('pa_44', 'CLOPYRALID', 19.5, 'Herbicida', true),
('pa_45', 'CLOQUINTOCET MEXIL', 15.0, 'Protector (safener)', true),
('pa_46', 'CLORANTRANILIPROLE', 27.5, 'Insecticida', true),
('pa_47', 'CLORFENAPIR', 36.27, 'Insecticida/Acaricida', true),
('pa_48', 'CLORIMURON ETIL', 24.0, 'Herbicida', true),
('pa_49', 'CLOROTALONIL', 33.0, 'Fungicida', true),
('pa_50', 'DELTAMETRINA', 27.13, 'Insecticida', true),
('pa_51', 'DICAMBA', 25.43, 'Herbicida', true),
('pa_52', 'DICLOSULAM', 17.83, 'Herbicida', true),
('pa_53', 'DIFENOCONAZOLE', 22.83, 'Fungicida', true),
('pa_54', 'DIFLUFENICAN', 19.83, 'Herbicida', true),
('pa_55', 'DIMETOATO', 32.71, 'Insecticida', true),
('pa_56', 'DIMETOMORF', 21.83, 'Fungicida', true),
('pa_57', 'DINOTEFURAN', 26.5, 'Insecticida', true),
('pa_58', 'DIQUAT', 33.93, 'Herbicida', true),
('pa_59', 'DIQUAT DIBROMURO', 33.93, 'Herbicida', true),
('pa_60', 'DIURON', 24.66, 'Herbicida', true),
('pa_61', 'DODECIL BENCEN SULFONICO', NULL, 'Coadyuvante', true),
('pa_62', 'EPOXICONAZOLE', 35.45, 'Fungicida', true),
('pa_63', 'ESTERES METILICOS DE ACIDOS GRASOS DE ACEITE DE SOJA', NULL, 'Coadyuvante', true),
('pa_64', 'ESTERES METILICOS DE ACIDOS GRASOS DE ACEITE VEGETAL', NULL, 'Coadyuvante', true),
('pa_65', 'ETEFON', 26.13, 'Regulador de crecimiento', true),
('pa_66', 'FENOXAPROP-P ETIL', 19.83, 'Herbicida', true),
('pa_67', 'FIPRONIL', 35.83, 'Insecticida', true),
('pa_68', 'FLUAZINAM', 21.13, 'Fungicida', true),
('pa_69', 'FLUDIOXONIL', 20.13, 'Fungicida', true),
('pa_70', 'FLUMETSULAM', 19.0, 'Herbicida', true),
('pa_71', 'FLUMIOXAZIN', 17.66, 'Herbicida', true),
('pa_72', 'FLUROCLORIDONA', 22.0, 'Herbicida', true),
('pa_73', 'FLUROXIPIR MEPTIL', 21.0, 'Herbicida', true),
('pa_74', 'FLUTRIAFOL', 22.0, 'Fungicida', true),
('pa_75', 'FLUXAPIROXAD', 28.0, 'Fungicida', true),
('pa_76', 'FOMESAFEN', 19.0, 'Herbicida', true),
('pa_77', 'FOSFURO DE ALUMINIO', 30.0, 'Fumigante/Insecticida', true),
('pa_78', 'GLIFOSATO', 15.33, 'Herbicida', true),
('pa_79', 'GLUFOSINATO DE AMONIO', 19.92, 'Herbicida', true),
('pa_80', 'HALAUXIFEN METIL', 19.0, 'Herbicida', true),
('pa_81', 'HALOXIFOP-P METIL', 19.5, 'Herbicida', true),
('pa_82', 'HEPTAMETILTRISILOXANO', NULL, 'Coadyuvante', true),
('pa_83', 'HIDROXIDO DE COBRE', 33.67, 'Fungicida', true),
('pa_84', 'IMAZALIL', 24.0, 'Fungicida', true),
('pa_85', 'IMAZAPIC', 19.83, 'Herbicida', true),
('pa_86', 'IMAZAPIR', 19.87, 'Herbicida', true),
('pa_87', 'IMAZETAPIR', 19.0, 'Herbicida', true),
('pa_88', 'IMIDACLOPRID', 36.71, 'Insecticida', true),
('pa_89', 'IPRODIONE', 30.5, 'Fungicida', true),
('pa_90', 'ISOXABEN', 21.0, 'Herbicida', true),
('pa_91', 'ISOXAFLUTOLE', 22.5, 'Herbicida', true),
('pa_92', 'LAMBDA-CIALOTRINA', 44.45, 'Insecticida', true),
('pa_93', 'LECITINA DE SOJA', 10.0, 'Coadyuvante', true),
('pa_94', 'LUFENURON', 22.93, 'Insecticida', true),
('pa_95', 'M.C.P.A.', 19.5, 'Herbicida', true),
('pa_96', 'M.S.M.A.', 23.0, 'Herbicida', true),
('pa_97', 'MANCOZEB', 32.87, 'Fungicida', true),
('pa_98', 'MESOTRIONE', 19.5, 'Herbicida', true),
('pa_99', 'METALAXIL', 22.13, 'Fungicida', true),
('pa_100', 'METALAXIL -M', 22.13, 'Fungicida', true),
('pa_101', 'METALDEHIDO', 22.0, 'Molusquicida', true),
('pa_102', 'METIL CICLOPROPENO', 10.0, 'Regulador de crecimiento', true),
('pa_103', 'METIL TIOFANATO', 35.0, 'Fungicida', true),
('pa_104', 'METOLACLORO', 21.61, 'Herbicida', true),
('pa_105', 'METOMIL', 36.5, 'Insecticida', true),
('pa_106', 'METOXIFENOCIDE', 22.93, 'Insecticida', true),
('pa_107', 'METRIBUZIN', 28.0, 'Herbicida', true),
('pa_108', 'METSULFURON METIL', 21.0, 'Herbicida', true),
('pa_109', 'MICLOBUTANIL', 22.0, 'Fungicida', true),
('pa_110', 'NICOSULFURON', 19.83, 'Herbicida', true),
('pa_111', 'NONIL FENOL ETOXILADO', NULL, 'Coadyuvante', true),
('pa_112', 'NOVALURON', 22.0, 'Insecticida', true),
('pa_113', 'OXICLORURO DE COBRE', 33.67, 'Fungicida', true),
('pa_114', 'OXIDO CUPROSO', 33.67, 'Fungicida', true),
('pa_115', 'OXIFLUORFEN', 27.43, 'Herbicida', true),
('pa_116', 'PARAQUAT DICLORURO', 38.07, 'Herbicida', true),
('pa_117', 'PENDIMETALIN', 23.0, 'Herbicida', true),
('pa_118', 'PICLORAM', 19.83, 'Herbicida', true),
('pa_119', 'PICOXISTROBIN', 27.0, 'Fungicida', true),
('pa_120', 'PIDIFLUMETOFEN', 22.0, 'Fungicida', true),
('pa_121', 'PINOXADEN', 19.83, 'Herbicida', true),
('pa_122', 'PIRACLOSTROBIN', 31.5, 'Fungicida', true),
('pa_123', 'PIRIMETANIL', 19.43, 'Fungicida', true),
('pa_124', 'PIRIMIFOS METIL', 33.83, 'Insecticida', true),
('pa_125', 'PIRIPROXIFEN', 26.93, 'Insecticida (regulador)', true),
('pa_126', 'PIROXASULFONE', 18.5, 'Herbicida', true),
('pa_127', 'PROFENOFOS', 41.5, 'Insecticida', true),
('pa_128', 'PROHEXADIONE DE CALCIO', 15.0, 'Regulador de crecimiento', true),
('pa_129', 'PROMETRINA', 22.0, 'Herbicida', true),
('pa_130', 'PROPICONAZOLE', 21.93, 'Fungicida', true),
('pa_131', 'PROTIOCONAZOLE', 22.0, 'Fungicida', true),
('pa_132', 'QUIZALOFOP-P ETIL', 20.83, 'Herbicida', true),
('pa_133', 'S-METOLACLORO', 21.61, 'Herbicida', true),
('pa_134', 'SAFLUFENACIL', 19.83, 'Herbicida', true),
('pa_135', 'SEDAXANE', 19.0, 'Fungicida', true),
('pa_136', 'SPINOSAD', 26.0, 'Insecticida', true),
('pa_137', 'SULFATO DE AMONIO', 10.0, 'Coadyuvante', true),
('pa_138', 'SULFATO DE COBRE PENTAHIDRATADO', 33.67, 'Fungicida', true),
('pa_139', 'SULFENTRAZONE', 23.5, 'Herbicida', true),
('pa_140', 'T.C.M.T.B.', 30.0, 'Fungicida', true),
('pa_141', 'TEBUCONAZOLE', 25.33, 'Fungicida', true),
('pa_142', 'TERBUTILAZINA', 23.0, 'Herbicida', true),
('pa_143', 'TIABENDAZOL', 23.5, 'Fungicida', true),
('pa_144', 'TIAMETOXAM', 33.7, 'Insecticida', true),
('pa_145', 'TIENCARBAZONE METIL', 18.0, 'Herbicida', true),
('pa_146', 'TIODICARB', 33.93, 'Insecticida', true),
('pa_147', 'TIRAM', 35.93, 'Fungicida', true),
('pa_148', 'TOPRAMEZONE', 19.0, 'Herbicida', true),
('pa_149', 'TRICHODERMA AFROHARZIANUM cepa Th2R199', NULL, 'Fungicida biológico', true),
('pa_150', 'TRICHODERMA HARZIANUM', NULL, 'Fungicida biológico', true),
('pa_151', 'TRIFLOXISTROBIN', 27.0, 'Fungicida', true);

-- Herramientas / tableros disponibles
INSERT INTO herramientas (id, nombre, descripcion, tipo, url, dominio, asignable) VALUES
    ('tablero_agro',       'Tablero Comercial Agropecuario', 'Seguimiento comercial de granos y precios',            'propia',  'tablero_agro.html',       'Comercial',    true),
    ('tablero_evolucion',  'Evolución de Variables',         'IPC, tipo de cambio y contexto macro',                 'propia',  'tablero_evolucion.html',  'Contexto',     true),
    ('tablero_insumos_ot', 'Registro de Labores e Insumos',  'OTs, movimientos de stock y fitosanitarios',          'propia',  'tablero_insumos_ot.html', 'Operativo',    true),
    ('tablero_uso_suelo',  'Plan de Uso del Suelo',          'Actividades por lote, campaña y superficie',           'propia',  'tablero_uso_suelo.html',  'Planificación',true),
    ('ProgramaSiembra',    'Programa de Siembra',            'Planificación de siembra por lote y campaña',          'propia',  'ProgramaSiembra.html',    'Planificación',true),
    ('tablero_hacienda',   'Tablero de Relaciones Ganaderas','Manejo ganadero y carga animal',                       'propia',  'tablero_hacienda.html',   'Ganadería',    true),
    ('tablero_labores',    'Precio de Labores y Fletes',     'Referencia de tarifas CATAC y labores por campaña',    'propia',  'tablero_labores.html',    'Operativo',    true),
    ('Fitosanitarios',     'Fitosanitarios',                  'Registro y auditoría de aplicaciones fitosanitarias', 'propia',  'Fitosanitarios.html',     'Operativo',    true),
    ('exist_prod_ganadera','Existencia y Producción Ganadera','Existencias de hacienda por negocio, rodeo y categoría. Movimientos, conciliación de stock y seguimiento de cabezas y kilos.', 'propia', 'exist_prod_ganadera.html', 'Ganadería', true);

-- Herramientas externas (calculadoras, informes en PDF, sitios externos —
-- se muestran en el inicio bajo "Externos"; solo admin_general las edita).
INSERT INTO herramientas (id, nombre, descripcion, tipo, url, fuente, orden, asignable) VALUES
    ('ext_calc_alquileres',  'Calculadora de Alquileres',
     'Calculadora de arrendamientos agrícolas para estimar el valor del alquiler de campo en distintos esquemas.',
     'externa', 'https://simpleza.com.ar/herramientas/calculadora-alquileres/', 'Simpleza', 1, false),
    ('ext_agri_finanzas',    'Agricultura & Finanzas',
     'Simulador financiero agrícola: rentabilidad por cultivo, impacto de shocks de precios y rindes, y escenarios de financiamiento con o sin socio a riesgo.',
     'externa', 'https://simpleza.com.ar/herramientas/agriculturafinanciera/', 'Simpleza', 2, false),
    ('ext_reporte_actualidad','Reporte de Actualidad Agro',
     'Reporte de actualidad del sector agropecuario con análisis de coyuntura y datos de referencia.',
     'externa', 'https://drive.google.com/file/d/1xfwCMCIAalW0YV47MCtThDFhc60dBNIJ/view', 'CREA', 3, false),
    ('ext_rif_urea_india',   'RIF Especial · Licitación Urea India',
     'Informe especial sobre la licitación oficial de compra de urea de India (NFL) de mayo 2026: volúmenes, fechas, restricciones geopolíticas e impacto esperado en precios internacionales.',
     'externa', 'rif_especial_urea_india.pdf.pdf', 'Ingeniería en Fertilizantes', 4, false),
    ('ext_apuntes_zym',      'Apuntes para Empresas · Mayo 2026',
     'Análisis de contexto para empresas agropecuarias: macro en la micro, baja de retenciones, negocio agrícola, ganadero y lechero. Método del 1% y el Furgón de Cola.',
     'externa', 'apuntes_zorraquin_meneses_mayo2026.pdf', 'Zorraquín + Meneses', 5, false),
    ('ext_rif_semanal_fert', 'RIF Semanal · Mercado de Fertilizantes',
     'Reporte semanal del mercado de fertilizantes (29 mayo 2026): nitrogenados, fosfatados, precios locales e internacionales, y relación insumo-producto para trigo y maíz.',
     'externa', 'rif_semanal_2026_22.pdf', 'Ingeniería en Fertilizantes', 6, false);

-- ─── CLIENTE / EMPRESA / CAMPO DEMO ─────────────────────────────────────────

INSERT INTO clientes (id, nombre, email, activo, cuit, razon_social, factura_centralizada) VALUES
    ('cli_demo', 'Cliente Demo', 'demo@puntalagro.com', true, '30-00000001-0', 'Cliente Demo S.A.', true);

INSERT INTO empresas (id, cliente_id, razon_social, cuit, activo) VALUES
    ('e_1', 'cli_demo', 'Estancia Don Eduardo',     '30-00000001-1', true),
    ('e_2', 'cli_demo', 'Agropecuaria del Litoral', '30-00000002-1', true);

INSERT INTO campos (id, empresa_id, nombre, localidad, provincia, ha_totales) VALUES
    ('c_1', 'e_1', 'Campo Viejo',    'Río Cuarto',  'Córdoba',      500),
    ('c_2', 'e_1', 'La Loma',        'Sampacho',    'Córdoba',      300),
    ('c_3', 'e_2', 'El Talar',       'Gualeguaychú','Entre Ríos',   800);

INSERT INTO lotes (id, campo_id, empresa_id, nombre, ha) VALUES
    ('l_1', 'c_1', 'e_1', 'Lote 1', 120),
    ('l_2', 'c_1', 'e_1', 'Lote 2',  95),
    ('l_3', 'c_2', 'e_1', 'Lote A', 150);

-- Cultivos/usos del suelo de Estancia Don Eduardo (e_1), tal como los cargaría
-- el cliente en Maestros — ver tablero_uso_suelo.html (Plan de uso de suelo).
INSERT INTO tipos_actividad (id, empresa_id, datos) VALUES
    ('ta_e1_tr',    'e_1', '{"id":"ta_e1_tr","empresaId":"e_1","nombre":"Trigo","sigla":"Tr","esCultivo":true,"actividad":"AGR","especieId":"esp_2","graminea":null,"default2da":false,"activo":true}'),
    ('ta_e1_cb',    'e_1', '{"id":"ta_e1_cb","empresaId":"e_1","nombre":"Cebada","sigla":"Cb","esCultivo":true,"actividad":"AGR","especieId":"esp_5","graminea":null,"default2da":false,"activo":true}'),
    ('ta_e1_av',    'e_1', '{"id":"ta_e1_av","empresaId":"e_1","nombre":"Avena","sigla":"Av","esCultivo":true,"actividad":"AGR","especieId":"esp_6","graminea":null,"default2da":false,"activo":true}'),
    ('ta_e1_g',     'e_1', '{"id":"ta_e1_g","empresaId":"e_1","nombre":"Girasol","sigla":"G","esCultivo":true,"actividad":"AGR","especieId":"esp_4","graminea":null,"default2da":false,"activo":true}'),
    ('ta_e1_mz',    'e_1', '{"id":"ta_e1_mz","empresaId":"e_1","nombre":"Maíz","sigla":"Mz","esCultivo":true,"actividad":"AGR","especieId":"esp_1","graminea":null,"default2da":false,"activo":true}'),
    ('ta_e1_mzt',   'e_1', '{"id":"ta_e1_mzt","empresaId":"e_1","nombre":"Maíz tardío","sigla":"MzT","esCultivo":true,"actividad":"AGR","especieId":"esp_1","graminea":null,"default2da":false,"activo":true}'),
    ('ta_e1_mz2',   'e_1', '{"id":"ta_e1_mz2","empresaId":"e_1","nombre":"Maíz 2ª","sigla":"Mz2ª","esCultivo":true,"actividad":"AGR","especieId":"esp_1","graminea":null,"default2da":true,"activo":true}'),
    ('ta_e1_mzspe', 'e_1', '{"id":"ta_e1_mzspe","empresaId":"e_1","nombre":"Maíz Silo PE","sigla":"MzSPE","esCultivo":true,"actividad":"AGR","especieId":"esp_7","graminea":null,"default2da":false,"activo":true}'),
    ('ta_e1_sj1',   'e_1', '{"id":"ta_e1_sj1","empresaId":"e_1","nombre":"Soja 1ª","sigla":"Sj1ª","esCultivo":true,"actividad":"AGR","especieId":"esp_0","graminea":false,"default2da":false,"activo":true}'),
    ('ta_e1_sj2',   'e_1', '{"id":"ta_e1_sj2","empresaId":"e_1","nombre":"Soja 2ª","sigla":"Sj2ª","esCultivo":true,"actividad":"AGR","especieId":"esp_0","graminea":false,"default2da":true,"activo":true}'),
    ('ta_e1_sg',    'e_1', '{"id":"ta_e1_sg","empresaId":"e_1","nombre":"Sorgo","sigla":"Sg","esCultivo":true,"actividad":"AGR","especieId":"esp_3","graminea":true,"default2da":false,"activo":true}'),
    ('ta_e1_csvg',  'e_1', '{"id":"ta_e1_csvg","empresaId":"e_1","nombre":"Cv. Servicio Vicia-Gram.","sigla":"CS-VG","esCultivo":true,"actividad":"AGR","especieId":null,"graminea":null,"default2da":false,"activo":true}'),
    ('ta_e1_csg',   'e_1', '{"id":"ta_e1_csg","empresaId":"e_1","nombre":"Cv. Servicio Gramínea","sigla":"CS-G","esCultivo":true,"actividad":"AGR","especieId":null,"graminea":true,"default2da":false,"activo":true}'),
    ('ta_e1_vi',    'e_1', '{"id":"ta_e1_vi","empresaId":"e_1","nombre":"Verdeo invierno","sigla":"VI","esCultivo":true,"actividad":"GAN","especieId":null,"graminea":true,"default2da":true,"activo":true}'),
    ('ta_e1_mzp',   'e_1', '{"id":"ta_e1_mzp","empresaId":"e_1","nombre":"Maíz pastoreo","sigla":"MzP","esCultivo":true,"actividad":"GAN","especieId":null,"graminea":true,"default2da":false,"activo":true}'),
    ('ta_e1_sgf',   'e_1', '{"id":"ta_e1_sgf","empresaId":"e_1","nombre":"Sorgo forrajero","sigla":"SgF","esCultivo":true,"actividad":"GAN","especieId":null,"graminea":true,"default2da":false,"activo":true}'),
    ('ta_e1_mzd',   'e_1', '{"id":"ta_e1_mzd","empresaId":"e_1","nombre":"Maíz pastoreo diferido","sigla":"MzD","esCultivo":true,"actividad":"GAN","especieId":null,"graminea":true,"default2da":false,"activo":true}'),
    ('ta_e1_sgd',   'e_1', '{"id":"ta_e1_sgd","empresaId":"e_1","nombre":"Sorgo pastoreo diferido","sigla":"SgD","esCultivo":true,"actividad":"GAN","especieId":null,"graminea":true,"default2da":false,"activo":true}'),
    ('ta_e1_prg',   'e_1', '{"id":"ta_e1_prg","empresaId":"e_1","nombre":"Promoción Rye Grass","sigla":"PRG","esCultivo":true,"actividad":"GAN","especieId":null,"graminea":true,"default2da":false,"activo":true}'),
    ('ta_e1_pi',    'e_1', '{"id":"ta_e1_pi","empresaId":"e_1","nombre":"Pradera implantada","sigla":"PI","esCultivo":true,"actividad":"GAN","especieId":null,"graminea":true,"default2da":true,"activo":true}'),
    ('ta_e1_ppfe',  'e_1', '{"id":"ta_e1_ppfe","empresaId":"e_1","nombre":"Pradera Festuca","sigla":"PPFe","esCultivo":true,"actividad":"GAN","especieId":null,"graminea":true,"default2da":false,"activo":true}'),
    ('ta_e1_ppalf', 'e_1', '{"id":"ta_e1_ppalf","empresaId":"e_1","nombre":"Pradera Alfalfa","sigla":"PPAlf","esCultivo":true,"actividad":"GAN","especieId":null,"graminea":false,"default2da":false,"activo":true}'),
    ('ta_e1_ppag',  'e_1', '{"id":"ta_e1_ppag","empresaId":"e_1","nombre":"Pradera Agropiro","sigla":"PPAg","esCultivo":true,"actividad":"GAN","especieId":null,"graminea":true,"default2da":false,"activo":true}'),
    ('ta_e1_pd',    'e_1', '{"id":"ta_e1_pd","empresaId":"e_1","nombre":"Pradera degradada","sigla":"PD","esCultivo":true,"actividad":"GAN","especieId":null,"graminea":null,"default2da":false,"activo":true}'),
    ('ta_e1_cn',    'e_1', '{"id":"ta_e1_cn","empresaId":"e_1","nombre":"Campo natural","sigla":"CN","esCultivo":true,"actividad":"GAN","especieId":null,"graminea":null,"default2da":false,"activo":true}'),
    ('ta_e1_cnd',   'e_1', '{"id":"ta_e1_cnd","empresaId":"e_1","nombre":"Campo natural degradado","sigla":"CND","esCultivo":true,"actividad":"GAN","especieId":null,"graminea":null,"default2da":false,"activo":true}'),
    ('ta_e1_arrto', 'e_1', '{"id":"ta_e1_arrto","empresaId":"e_1","nombre":"Arrendamiento","sigla":"ARRTO","esCultivo":false,"actividad":null,"especieId":null,"graminea":null,"default2da":false,"activo":true}');

-- ─── CLIENTE / EMPRESA / CAMPOS / LOTES REALES: AGR. DON EDUARDO ───────────
-- Migrado desde docs/PlanUsoSuelo3.xlsx (planilla real del cliente) el 2026-08-18.
-- Ver historial de conversación para la metodología (fusión de lotes
-- subdivididos en la planilla, cálculo de superficies, etc.).

INSERT INTO clientes (id, nombre, activo) VALUES
    ('cli_don_eduardo', 'Agr. Don Eduardo', true);

INSERT INTO empresas (id, cliente_id, razon_social, activo) VALUES
    ('e_don_eduardo', 'cli_don_eduardo', 'Agroganadera Don Eduardo', true);

INSERT INTO campos (id, empresa_id, nombre, ha_totales) VALUES
    ('c_ec_deduardo', 'e_don_eduardo', 'EC', 1225.5),
    ('c_em_deduardo', 'e_don_eduardo', 'EM', 1437),
    ('c_lm_deduardo', 'e_don_eduardo', 'LM', 672),
    ('c_lr_deduardo', 'e_don_eduardo', 'LR', 1200);

-- Cultivos/usos del suelo: mismo catálogo default que cualquier empresa nueva
-- (ver sembrarCultivosDefault() en server.js) — se listan acá porque este alta
-- se hizo por SQL directo, no vía POST /api/empresas.
INSERT INTO tipos_actividad (id, empresa_id, datos) VALUES
    ('ta_e_don_eduardo_cd_arrto', 'e_don_eduardo', '{"id": "ta_e_don_eduardo_cd_arrto", "sigla": "ARRTO", "activo": true, "nombre": "Arrendamiento", "graminea": null, "actividad": null, "empresaId": "e_don_eduardo", "esCultivo": false, "especieId": null, "default2da": false}'),
    ('ta_e_don_eduardo_cd_av', 'e_don_eduardo', '{"id": "ta_e_don_eduardo_cd_av", "sigla": "Av", "activo": true, "nombre": "Avena", "graminea": null, "actividad": "AGR", "empresaId": "e_don_eduardo", "esCultivo": true, "especieId": "esp_6", "default2da": false}'),
    ('ta_e_don_eduardo_cd_cb', 'e_don_eduardo', '{"id": "ta_e_don_eduardo_cd_cb", "sigla": "Cb", "activo": true, "nombre": "Cebada", "graminea": null, "actividad": "AGR", "empresaId": "e_don_eduardo", "esCultivo": true, "especieId": "esp_5", "default2da": false}'),
    ('ta_e_don_eduardo_cd_cn', 'e_don_eduardo', '{"id": "ta_e_don_eduardo_cd_cn", "sigla": "CN", "activo": true, "nombre": "Campo natural", "graminea": null, "actividad": "GAN", "empresaId": "e_don_eduardo", "esCultivo": true, "especieId": null, "default2da": false}'),
    ('ta_e_don_eduardo_cd_cnd', 'e_don_eduardo', '{"id": "ta_e_don_eduardo_cd_cnd", "sigla": "CND", "activo": true, "nombre": "Campo natural degradado", "graminea": null, "actividad": "GAN", "empresaId": "e_don_eduardo", "esCultivo": true, "especieId": null, "default2da": false}'),
    ('ta_e_don_eduardo_cd_csg', 'e_don_eduardo', '{"id": "ta_e_don_eduardo_cd_csg", "sigla": "CS-G", "activo": true, "nombre": "Cv. Servicio Gramínea", "graminea": true, "actividad": "AGR", "empresaId": "e_don_eduardo", "esCultivo": true, "especieId": null, "default2da": false}'),
    ('ta_e_don_eduardo_cd_csvg', 'e_don_eduardo', '{"id": "ta_e_don_eduardo_cd_csvg", "sigla": "CS-VG", "activo": true, "nombre": "Cv. Servicio Vicia-Gram.", "graminea": null, "actividad": "AGR", "empresaId": "e_don_eduardo", "esCultivo": true, "especieId": null, "default2da": false}'),
    ('ta_e_don_eduardo_cd_g', 'e_don_eduardo', '{"id": "ta_e_don_eduardo_cd_g", "sigla": "G", "activo": true, "nombre": "Girasol", "graminea": null, "actividad": "AGR", "empresaId": "e_don_eduardo", "esCultivo": true, "especieId": "esp_4", "default2da": false}'),
    ('ta_e_don_eduardo_cd_mz', 'e_don_eduardo', '{"id": "ta_e_don_eduardo_cd_mz", "sigla": "Mz", "activo": true, "nombre": "Maíz", "graminea": null, "actividad": "AGR", "empresaId": "e_don_eduardo", "esCultivo": true, "especieId": "esp_1", "default2da": false}'),
    ('ta_e_don_eduardo_cd_mz2', 'e_don_eduardo', '{"id": "ta_e_don_eduardo_cd_mz2", "sigla": "Mz2ª", "activo": true, "nombre": "Maíz 2ª", "graminea": null, "actividad": "AGR", "empresaId": "e_don_eduardo", "esCultivo": true, "especieId": "esp_1", "default2da": true}'),
    ('ta_e_don_eduardo_cd_mzd', 'e_don_eduardo', '{"id": "ta_e_don_eduardo_cd_mzd", "sigla": "MzD", "activo": true, "nombre": "Maíz pastoreo diferido", "graminea": true, "actividad": "GAN", "empresaId": "e_don_eduardo", "esCultivo": true, "especieId": null, "default2da": false}'),
    ('ta_e_don_eduardo_cd_mzp', 'e_don_eduardo', '{"id": "ta_e_don_eduardo_cd_mzp", "sigla": "MzP", "activo": true, "nombre": "Maíz pastoreo", "graminea": true, "actividad": "GAN", "empresaId": "e_don_eduardo", "esCultivo": true, "especieId": null, "default2da": false}'),
    ('ta_e_don_eduardo_cd_mzspe', 'e_don_eduardo', '{"id": "ta_e_don_eduardo_cd_mzspe", "sigla": "MzSPE", "activo": true, "nombre": "Maíz Silo PE", "graminea": null, "actividad": "AGR", "empresaId": "e_don_eduardo", "esCultivo": true, "especieId": "esp_7", "default2da": false}'),
    ('ta_e_don_eduardo_cd_mzt', 'e_don_eduardo', '{"id": "ta_e_don_eduardo_cd_mzt", "sigla": "MzT", "activo": true, "nombre": "Maíz tardío", "graminea": null, "actividad": "AGR", "empresaId": "e_don_eduardo", "esCultivo": true, "especieId": "esp_1", "default2da": false}'),
    ('ta_e_don_eduardo_cd_pd', 'e_don_eduardo', '{"id": "ta_e_don_eduardo_cd_pd", "sigla": "PD", "activo": true, "nombre": "Pradera degradada", "graminea": null, "actividad": "GAN", "empresaId": "e_don_eduardo", "esCultivo": true, "especieId": null, "default2da": false}'),
    ('ta_e_don_eduardo_cd_pi', 'e_don_eduardo', '{"id": "ta_e_don_eduardo_cd_pi", "sigla": "PI", "activo": true, "nombre": "Pradera implantada", "graminea": true, "actividad": "GAN", "empresaId": "e_don_eduardo", "esCultivo": true, "especieId": null, "default2da": true}'),
    ('ta_e_don_eduardo_cd_ppag', 'e_don_eduardo', '{"id": "ta_e_don_eduardo_cd_ppag", "sigla": "PPAg", "activo": true, "nombre": "Pradera Agropiro", "graminea": true, "actividad": "GAN", "empresaId": "e_don_eduardo", "esCultivo": true, "especieId": null, "default2da": false}'),
    ('ta_e_don_eduardo_cd_ppalf', 'e_don_eduardo', '{"id": "ta_e_don_eduardo_cd_ppalf", "sigla": "PPAlf", "activo": true, "nombre": "Pradera Alfalfa", "graminea": false, "actividad": "GAN", "empresaId": "e_don_eduardo", "esCultivo": true, "especieId": null, "default2da": false}'),
    ('ta_e_don_eduardo_cd_ppfe', 'e_don_eduardo', '{"id": "ta_e_don_eduardo_cd_ppfe", "sigla": "PPFe", "activo": true, "nombre": "Pradera Festuca", "graminea": true, "actividad": "GAN", "empresaId": "e_don_eduardo", "esCultivo": true, "especieId": null, "default2da": false}'),
    ('ta_e_don_eduardo_cd_prg', 'e_don_eduardo', '{"id": "ta_e_don_eduardo_cd_prg", "sigla": "PRG", "activo": true, "nombre": "Promoción Rye Grass", "graminea": true, "actividad": "GAN", "empresaId": "e_don_eduardo", "esCultivo": true, "especieId": null, "default2da": false}'),
    ('ta_e_don_eduardo_cd_sg', 'e_don_eduardo', '{"id": "ta_e_don_eduardo_cd_sg", "sigla": "Sg", "activo": true, "nombre": "Sorgo", "graminea": true, "actividad": "AGR", "empresaId": "e_don_eduardo", "esCultivo": true, "especieId": "esp_3", "default2da": false}'),
    ('ta_e_don_eduardo_cd_sgd', 'e_don_eduardo', '{"id": "ta_e_don_eduardo_cd_sgd", "sigla": "SgD", "activo": true, "nombre": "Sorgo pastoreo diferido", "graminea": true, "actividad": "GAN", "empresaId": "e_don_eduardo", "esCultivo": true, "especieId": null, "default2da": false}'),
    ('ta_e_don_eduardo_cd_sgf', 'e_don_eduardo', '{"id": "ta_e_don_eduardo_cd_sgf", "sigla": "SgF", "activo": true, "nombre": "Sorgo forrajero", "graminea": true, "actividad": "GAN", "empresaId": "e_don_eduardo", "esCultivo": true, "especieId": null, "default2da": false}'),
    ('ta_e_don_eduardo_cd_sj1', 'e_don_eduardo', '{"id": "ta_e_don_eduardo_cd_sj1", "sigla": "Sj1ª", "activo": true, "nombre": "Soja 1ª", "graminea": false, "actividad": "AGR", "empresaId": "e_don_eduardo", "esCultivo": true, "especieId": "esp_0", "default2da": false}'),
    ('ta_e_don_eduardo_cd_sj2', 'e_don_eduardo', '{"id": "ta_e_don_eduardo_cd_sj2", "sigla": "Sj2ª", "activo": true, "nombre": "Soja 2ª", "graminea": false, "actividad": "AGR", "empresaId": "e_don_eduardo", "esCultivo": true, "especieId": "esp_0", "default2da": true}'),
    ('ta_e_don_eduardo_cd_tr', 'e_don_eduardo', '{"id": "ta_e_don_eduardo_cd_tr", "sigla": "Tr", "activo": true, "nombre": "Trigo", "graminea": null, "actividad": "AGR", "empresaId": "e_don_eduardo", "esCultivo": true, "especieId": "esp_2", "default2da": false}'),
    ('ta_e_don_eduardo_cd_vi', 'e_don_eduardo', '{"id": "ta_e_don_eduardo_cd_vi", "sigla": "VI", "activo": true, "nombre": "Verdeo invierno", "graminea": true, "actividad": "GAN", "empresaId": "e_don_eduardo", "esCultivo": true, "especieId": null, "default2da": true}');

-- Ambientes (catálogo de suelo/rotación de la solapa "Altas" de la planilla)
INSERT INTO ambientes (id, empresa_id, datos) VALUES
    ('amb_a1', 'e_don_eduardo', '{"id": "amb_a1", "tipo": "AGR", "activo": true, "codigo": "A1", "empresaId": "e_don_eduardo", "descripcion": "Rotación agrícola larga con PP (10 x 4)"}'),
    ('amb_a2', 'e_don_eduardo', '{"id": "amb_a2", "tipo": "AGR", "activo": true, "codigo": "A2", "empresaId": "e_don_eduardo", "descripcion": "Rotación agrícola corta con PP (4 x 4)"}'),
    ('amb_desp', 'e_don_eduardo', '{"id": "amb_desp", "tipo": "GAN", "activo": true, "codigo": "DESP", "empresaId": "e_don_eduardo", "descripcion": "Desperdicios"}'),
    ('amb_fap', 'e_don_eduardo', '{"id": "amb_fap", "tipo": "AGR", "activo": true, "codigo": "FAP", "empresaId": "e_don_eduardo", "descripcion": "Franco alto potencial"}'),
    ('amb_fap_lar', 'e_don_eduardo', '{"id": "amb_fap_lar", "tipo": "AGR", "activo": true, "codigo": "FAP-LAR", "empresaId": "e_don_eduardo", "descripcion": "Franco alto potencial c/Lomas arenosas"}'),
    ('amb_fap_rh', 'e_don_eduardo', '{"id": "amb_fap_rh", "tipo": "AGR", "activo": true, "codigo": "FAP-RH", "empresaId": "e_don_eduardo", "descripcion": "Franco alto potencial c/RH"}'),
    ('amb_g1', 'e_don_eduardo', '{"id": "amb_g1", "tipo": "GAN", "activo": true, "codigo": "G1", "empresaId": "e_don_eduardo", "descripcion": "PP en rotación agrícola limpieza (2 x 4)"}'),
    ('amb_g2', 'e_don_eduardo', '{"id": "amb_g2", "tipo": "GAN", "activo": true, "codigo": "G2", "empresaId": "e_don_eduardo", "descripcion": "CN degradados mejorables con PP con ciclo limpieza ganadera"}'),
    ('amb_g3', 'e_don_eduardo', '{"id": "amb_g3", "tipo": "GAN", "activo": true, "codigo": "G3", "empresaId": "e_don_eduardo", "descripcion": "Manejo campo natural dulce"}'),
    ('amb_g4', 'e_don_eduardo', '{"id": "amb_g4", "tipo": "GAN", "activo": true, "codigo": "G4", "empresaId": "e_don_eduardo", "descripcion": "Manejo campo natural salino"}'),
    ('amb_g5', 'e_don_eduardo', '{"id": "amb_g5", "tipo": "GAN", "activo": true, "codigo": "G5", "empresaId": "e_don_eduardo", "descripcion": "Espartos"}'),
    ('amb_g6', 'e_don_eduardo', '{"id": "amb_g6", "tipo": "GAN", "activo": true, "codigo": "G6", "empresaId": "e_don_eduardo", "descripcion": "Campo natural inundable"}'),
    ('amb_lar', 'e_don_eduardo', '{"id": "amb_lar", "tipo": "AGR", "activo": true, "codigo": "LAR", "empresaId": "e_don_eduardo", "descripcion": "Loma arenosa"}'),
    ('amb_pso', 'e_don_eduardo', '{"id": "amb_pso", "tipo": "AGR", "activo": true, "codigo": "PSO", "empresaId": "e_don_eduardo", "descripcion": "Plano somero"}'),
    ('amb_pus', 'e_don_eduardo', '{"id": "amb_pus", "tipo": "AGR", "activo": true, "codigo": "PUS", "empresaId": "e_don_eduardo", "descripcion": "Plano ultra somero"}'),
    ('amb_tip', 'e_don_eduardo', '{"id": "amb_tip", "tipo": "AGR", "activo": true, "codigo": "TIP", "empresaId": "e_don_eduardo", "descripcion": "Thapto potencial intermedio"}');

INSERT INTO lotes (id, campo_id, empresa_id, nombre, ha, ambiente, explotable, activo, tipo_override) VALUES
    ('lt_deduardo_ec_10_1', 'c_ec_deduardo', 'e_don_eduardo', 'EC 10-1', 26, 'G1', 26, true, NULL),
    ('lt_deduardo_ec_10_2', 'c_ec_deduardo', 'e_don_eduardo', 'EC 10-2', 27, 'G1', 27, true, NULL),
    ('lt_deduardo_ec_10_3', 'c_ec_deduardo', 'e_don_eduardo', 'EC 10-3', 20, 'G1', 20, true, NULL),
    ('lt_deduardo_ec_11_bajo', 'c_ec_deduardo', 'e_don_eduardo', 'EC 11 bajo', 33, 'G4', 33, true, NULL),
    ('lt_deduardo_ec_11_loma', 'c_ec_deduardo', 'e_don_eduardo', 'EC 11 loma', 25, 'G1', 25, true, NULL),
    ('lt_deduardo_ec_12', 'c_ec_deduardo', 'e_don_eduardo', 'EC 12', 54, 'G3', 54, true, NULL),
    ('lt_deduardo_ec_12_loma', 'c_ec_deduardo', 'e_don_eduardo', 'EC 12 loma', 4, 'A2', 4, true, NULL),
    ('lt_deduardo_ec_13_cn', 'c_ec_deduardo', 'e_don_eduardo', 'EC 13 CN', 40, 'G3', 40, true, NULL),
    ('lt_deduardo_ec_13_loma', 'c_ec_deduardo', 'e_don_eduardo', 'EC 13 loma', 35, 'A2', 35, true, NULL),
    ('lt_deduardo_ec_14', 'c_ec_deduardo', 'e_don_eduardo', 'EC 14', 65, 'A2', 65, true, NULL),
    ('lt_deduardo_ec_14_cn', 'c_ec_deduardo', 'e_don_eduardo', 'EC 14 CN', 13, 'G3', 13, true, NULL),
    ('lt_deduardo_ec_15', 'c_ec_deduardo', 'e_don_eduardo', 'EC 15', 17, 'A2', 17, true, NULL),
    ('lt_deduardo_ec_15_cn', 'c_ec_deduardo', 'e_don_eduardo', 'EC 15 CN', 42, 'G3', 42, true, NULL),
    ('lt_deduardo_ec_16', 'c_ec_deduardo', 'e_don_eduardo', 'EC 16', 29, 'A2', 29, true, NULL),
    ('lt_deduardo_ec_16_bajo', 'c_ec_deduardo', 'e_don_eduardo', 'EC 16 bajo', 20, 'G1', 20, true, NULL),
    ('lt_deduardo_ec_1a', 'c_ec_deduardo', 'e_don_eduardo', 'EC 1A', 28, 'G1', 28, true, NULL),
    ('lt_deduardo_ec_1a_cn', 'c_ec_deduardo', 'e_don_eduardo', 'EC 1A CN', 21, 'G2', 21, true, NULL),
    ('lt_deduardo_ec_1b', 'c_ec_deduardo', 'e_don_eduardo', 'EC 1B', 27, 'G1', 27, true, NULL),
    ('lt_deduardo_ec_1b_cn', 'c_ec_deduardo', 'e_don_eduardo', 'EC 1B CN', 20, 'G2', 20, true, NULL),
    ('lt_deduardo_ec_2a', 'c_ec_deduardo', 'e_don_eduardo', 'EC 2A', 27, 'G1', 27, true, NULL),
    ('lt_deduardo_ec_2a_cn', 'c_ec_deduardo', 'e_don_eduardo', 'EC 2A CN', 20, 'G2', 20, true, NULL),
    ('lt_deduardo_ec_2a_cn1', 'c_ec_deduardo', 'e_don_eduardo', 'EC 2A CN1', 9.5, 'G1', 9.5, true, NULL),
    ('lt_deduardo_ec_2b', 'c_ec_deduardo', 'e_don_eduardo', 'EC 2B', 45, 'G2', 45, true, NULL),
    ('lt_deduardo_ec_2b_cn1', 'c_ec_deduardo', 'e_don_eduardo', 'EC 2B CN1', 15, 'G1', 15, true, NULL),
    ('lt_deduardo_ec_3_cn', 'c_ec_deduardo', 'e_don_eduardo', 'EC 3 CN', 57, 'G2', 57, true, NULL),
    ('lt_deduardo_ec_3_loma', 'c_ec_deduardo', 'e_don_eduardo', 'EC 3 loma', 26, 'A2', 26, true, NULL),
    ('lt_deduardo_ec_4', 'c_ec_deduardo', 'e_don_eduardo', 'EC 4', 35, 'G1', 35, true, NULL),
    ('lt_deduardo_ec_4_loma', 'c_ec_deduardo', 'e_don_eduardo', 'EC 4 loma', 20, 'A2', 20, true, NULL),
    ('lt_deduardo_ec_5', 'c_ec_deduardo', 'e_don_eduardo', 'EC 5', 78, 'G1', 78, true, NULL),
    ('lt_deduardo_ec_6_bajo', 'c_ec_deduardo', 'e_don_eduardo', 'EC 6 bajo', 36, 'G4', 36, true, NULL),
    ('lt_deduardo_ec_6_loma', 'c_ec_deduardo', 'e_don_eduardo', 'EC 6 loma', 30, 'G1', 30, true, NULL),
    ('lt_deduardo_ec_7', 'c_ec_deduardo', 'e_don_eduardo', 'EC 7', 27, 'G1', 27, true, NULL),
    ('lt_deduardo_ec_8', 'c_ec_deduardo', 'e_don_eduardo', 'EC 8', 20, 'G1', 20, true, NULL),
    ('lt_deduardo_ec_dp1', 'c_ec_deduardo', 'e_don_eduardo', 'EC DP1', 47, 'A2', 47, true, NULL),
    ('lt_deduardo_ec_dp2_cn', 'c_ec_deduardo', 'e_don_eduardo', 'EC DP2 CN', 37, 'G2', 37, true, NULL),
    ('lt_deduardo_ec_dp2_cn1', 'c_ec_deduardo', 'e_don_eduardo', 'EC DP2 CN1', 7, 'G1', 7, true, NULL),
    ('lt_deduardo_ec_dp2_3_laguna', 'c_ec_deduardo', 'e_don_eduardo', 'EC DP2-3 laguna', 26, 'G6', 26, true, NULL),
    ('lt_deduardo_ec_dp3_cn', 'c_ec_deduardo', 'e_don_eduardo', 'EC DP3 CN', 66, 'G4', 66, true, NULL),
    ('lt_deduardo_ec_dp3_cn1', 'c_ec_deduardo', 'e_don_eduardo', 'EC DP3 CN1', 5, 'G1', 5, true, NULL),
    ('lt_deduardo_ec_desperdicios', 'c_ec_deduardo', 'e_don_eduardo', 'EC Desperdicios', 46, 'DESP', 46, true, NULL),
    ('lt_deduardo_em_18', 'c_em_deduardo', 'e_don_eduardo', 'EM 18', 44, 'A1', 44, true, NULL),
    ('lt_deduardo_em_19', 'c_em_deduardo', 'e_don_eduardo', 'EM 19', 46, 'A1', 46, true, NULL),
    ('lt_deduardo_em_20', 'c_em_deduardo', 'e_don_eduardo', 'EM 20', 38, 'A1', 38, true, NULL),
    ('lt_deduardo_em_21', 'c_em_deduardo', 'e_don_eduardo', 'EM 21', 45, 'A1', 45, true, NULL),
    ('lt_deduardo_em_50_51', 'c_em_deduardo', 'e_don_eduardo', 'EM 50/51', 90, 'A1', 90, true, NULL),
    ('lt_deduardo_em_50_51_cn', 'c_em_deduardo', 'e_don_eduardo', 'EM 50/51 CN', 18, 'G3', 18, true, NULL),
    ('lt_deduardo_em_52_cn', 'c_em_deduardo', 'e_don_eduardo', 'EM 52 CN', 4, 'G3', 4, true, NULL),
    ('lt_deduardo_em_52_loma', 'c_em_deduardo', 'e_don_eduardo', 'EM 52 loma', 22, 'G1', 22, true, NULL),
    ('lt_deduardo_em_53', 'c_em_deduardo', 'e_don_eduardo', 'EM 53', 28, 'G1', 28, true, NULL),
    ('lt_deduardo_em_53_cn', 'c_em_deduardo', 'e_don_eduardo', 'EM 53 CN', 10, 'G3', 10, true, NULL),
    ('lt_deduardo_em_54', 'c_em_deduardo', 'e_don_eduardo', 'EM 54', 167, 'G6', 167, true, NULL),
    ('lt_deduardo_em_56', 'c_em_deduardo', 'e_don_eduardo', 'EM 56', 67, 'G6', 67, true, NULL),
    ('lt_deduardo_em_57', 'c_em_deduardo', 'e_don_eduardo', 'EM 57', 23, 'G1', 23, true, NULL),
    ('lt_deduardo_em_57_bajo', 'c_em_deduardo', 'e_don_eduardo', 'EM 57 bajo', 24, 'G3', 24, true, NULL),
    ('lt_deduardo_em_58', 'c_em_deduardo', 'e_don_eduardo', 'EM 58', 10, 'G1', 10, true, NULL),
    ('lt_deduardo_em_58_cn', 'c_em_deduardo', 'e_don_eduardo', 'EM 58 CN', 53, 'G6', 53, true, NULL),
    ('lt_deduardo_em_59', 'c_em_deduardo', 'e_don_eduardo', 'EM 59', 26, 'A2', 26, true, NULL),
    ('lt_deduardo_em_59_cn', 'c_em_deduardo', 'e_don_eduardo', 'EM 59 CN', 6, 'G6', 6, true, NULL),
    ('lt_deduardo_em_60', 'c_em_deduardo', 'e_don_eduardo', 'EM 60', 25, 'G1', 25, true, NULL),
    ('lt_deduardo_em_60_cn', 'c_em_deduardo', 'e_don_eduardo', 'EM 60 CN', 11, 'G3', 11, true, NULL),
    ('lt_deduardo_em_61', 'c_em_deduardo', 'e_don_eduardo', 'EM 61', 32, 'A2', 32, true, NULL),
    ('lt_deduardo_em_62', 'c_em_deduardo', 'e_don_eduardo', 'EM 62', 39, 'G1', 39, true, NULL),
    ('lt_deduardo_em_62_cn', 'c_em_deduardo', 'e_don_eduardo', 'EM 62 CN', 8, 'G2', 8, true, NULL),
    ('lt_deduardo_em_63', 'c_em_deduardo', 'e_don_eduardo', 'EM 63', 45, 'A2', 45, true, NULL),
    ('lt_deduardo_em_64', 'c_em_deduardo', 'e_don_eduardo', 'EM 64', 43, 'A2', 43, true, NULL),
    ('lt_deduardo_em_64_cn', 'c_em_deduardo', 'e_don_eduardo', 'EM 64 CN', 8, 'G3', 8, true, NULL),
    ('lt_deduardo_em_65', 'c_em_deduardo', 'e_don_eduardo', 'EM 65', 12, 'G1', 12, true, NULL),
    ('lt_deduardo_em_65_cn', 'c_em_deduardo', 'e_don_eduardo', 'EM 65 CN', 43, 'G2', 43, true, NULL),
    ('lt_deduardo_em_65_cn1', 'c_em_deduardo', 'e_don_eduardo', 'EM 65 CN1', 10, 'G1', 10, true, NULL),
    ('lt_deduardo_em_66', 'c_em_deduardo', 'e_don_eduardo', 'EM 66', 50, 'A1', 50, true, NULL),
    ('lt_deduardo_em_66_cn', 'c_em_deduardo', 'e_don_eduardo', 'EM 66 CN', 3, 'G3', 3, true, NULL),
    ('lt_deduardo_em_67', 'c_em_deduardo', 'e_don_eduardo', 'EM 67', 12, 'G1', 12, true, NULL),
    ('lt_deduardo_em_67_cn', 'c_em_deduardo', 'e_don_eduardo', 'EM 67 CN', 7, 'G3', 7, true, NULL),
    ('lt_deduardo_em_68', 'c_em_deduardo', 'e_don_eduardo', 'EM 68', 25, 'G2', 25, true, NULL),
    ('lt_deduardo_em_69', 'c_em_deduardo', 'e_don_eduardo', 'EM 69', 16, 'G4', 16, true, NULL),
    ('lt_deduardo_em_69_cn', 'c_em_deduardo', 'e_don_eduardo', 'EM 69 CN', 9, 'G2', 9, true, NULL),
    ('lt_deduardo_em_69_laguna', 'c_em_deduardo', 'e_don_eduardo', 'EM 69 laguna', 18, 'G6', 18, true, NULL),
    ('lt_deduardo_em_70', 'c_em_deduardo', 'e_don_eduardo', 'EM 70', 59, 'G3', 59, true, NULL),
    ('lt_deduardo_em_70_73', 'c_em_deduardo', 'e_don_eduardo', 'EM 70/73', 56, 'A1', 56, true, NULL),
    ('lt_deduardo_em_72', 'c_em_deduardo', 'e_don_eduardo', 'EM 72', 57, 'G4', 57, true, NULL),
    ('lt_deduardo_em_72_cn1', 'c_em_deduardo', 'e_don_eduardo', 'EM 72 CN1', 7, 'G1', 7, true, NULL),
    ('lt_deduardo_em_72_laguna', 'c_em_deduardo', 'e_don_eduardo', 'EM 72 laguna', 36, 'G6', 36, true, NULL),
    ('lt_deduardo_em_73_cn', 'c_em_deduardo', 'e_don_eduardo', 'EM 73 CN', 5, 'G3', 5, true, NULL),
    ('lt_deduardo_em_73_laguna', 'c_em_deduardo', 'e_don_eduardo', 'EM 73 laguna', 25, 'G6', 25, true, NULL),
    ('lt_deduardo_em_73a', 'c_em_deduardo', 'e_don_eduardo', 'EM 73A', 20, 'G1', 20, true, NULL),
    ('lt_deduardo_em_desperdicios', 'c_em_deduardo', 'e_don_eduardo', 'EM Desperdicios', 35, 'DESP', 35, true, NULL),
    ('lt_deduardo_lm_1', 'c_lm_deduardo', 'e_don_eduardo', 'LM 1', 64, 'A1', 64, true, NULL),
    ('lt_deduardo_lm_1_cn_n', 'c_lm_deduardo', 'e_don_eduardo', 'LM 1 CN N', 15.3, 'G3', 15.3, true, NULL),
    ('lt_deduardo_lm_1_cni_s', 'c_lm_deduardo', 'e_don_eduardo', 'LM 1 CNI S', 5.8, 'G6', 5.8, true, NULL),
    ('lt_deduardo_lm_10', 'c_lm_deduardo', 'e_don_eduardo', 'LM 10', 12.1, 'A1', 12.1, true, NULL),
    ('lt_deduardo_lm_2', 'c_lm_deduardo', 'e_don_eduardo', 'LM 2', 36.3, 'A1', 36.3, true, NULL),
    ('lt_deduardo_lm_2_cn', 'c_lm_deduardo', 'e_don_eduardo', 'LM 2 CN', 31.3, 'G1', 31.3, true, NULL),
    ('lt_deduardo_lm_2_cni', 'c_lm_deduardo', 'e_don_eduardo', 'LM 2 CNI', 14.8, 'G6', 14.8, true, NULL),
    ('lt_deduardo_lm_3', 'c_lm_deduardo', 'e_don_eduardo', 'LM 3', 12.6, 'G1', 12.6, true, NULL),
    ('lt_deduardo_lm_3_4_cni', 'c_lm_deduardo', 'e_don_eduardo', 'LM 3-4 CNI', 107, 'G6', 107, true, NULL),
    ('lt_deduardo_lm_3_4_agropiro', 'c_lm_deduardo', 'e_don_eduardo', 'LM 3-4 agropiro', 14.8, 'G4', 14.8, true, NULL),
    ('lt_deduardo_lm_5_cn', 'c_lm_deduardo', 'e_don_eduardo', 'LM 5 CN', 28.2, 'G3', 28.2, true, NULL),
    ('lt_deduardo_lm_5_cni', 'c_lm_deduardo', 'e_don_eduardo', 'LM 5 CNI', 30.8, 'G6', 30.8, true, NULL),
    ('lt_deduardo_lm_6_cn_n', 'c_lm_deduardo', 'e_don_eduardo', 'LM 6 CN N', 30.2, 'G3', 30.2, true, NULL),
    ('lt_deduardo_lm_6_cn_s', 'c_lm_deduardo', 'e_don_eduardo', 'LM 6 CN S', 34.2, 'A2', 34.2, true, NULL),
    ('lt_deduardo_lm_6_cni', 'c_lm_deduardo', 'e_don_eduardo', 'LM 6 CNI', 73.9, 'G6', 73.9, true, NULL),
    ('lt_deduardo_lm_6_medio', 'c_lm_deduardo', 'e_don_eduardo', 'LM 6 medio', 49.7, 'A2', 49.7, true, NULL),
    ('lt_deduardo_lm_7_8_cn', 'c_lm_deduardo', 'e_don_eduardo', 'LM 7-8 CN', 28, 'G3', 28, true, NULL),
    ('lt_deduardo_lm_7_8_cni', 'c_lm_deduardo', 'e_don_eduardo', 'LM 7-8 CNI', 14.6, 'G6', 14.6, true, NULL),
    ('lt_deduardo_lm_7_9', 'c_lm_deduardo', 'e_don_eduardo', 'LM 7-9', 39.6, 'A1', 39.6, true, NULL),
    ('lt_deduardo_lm_8_n', 'c_lm_deduardo', 'e_don_eduardo', 'LM 8 N', 6.6, 'A1', 6.6, true, NULL),
    ('lt_deduardo_lm_8_s', 'c_lm_deduardo', 'e_don_eduardo', 'LM 8 S', 12.3, 'A2', 12.3, true, NULL),
    ('lt_deduardo_lm_desperdicios', 'c_lm_deduardo', 'e_don_eduardo', 'LM Desperdicios', 9.9, 'DESP', 9.9, true, NULL),
    ('lt_deduardo_lr_1', 'c_lr_deduardo', 'e_don_eduardo', 'LR 1', 117, 'G5', 117, true, NULL),
    ('lt_deduardo_lr_10a', 'c_lr_deduardo', 'e_don_eduardo', 'LR 10A', 7, 'A2', 7, true, NULL),
    ('lt_deduardo_lr_10b', 'c_lr_deduardo', 'e_don_eduardo', 'LR 10B', 15, 'A2', 15, true, NULL),
    ('lt_deduardo_lr_10c', 'c_lr_deduardo', 'e_don_eduardo', 'LR 10C', 13, 'A2', 13, true, NULL),
    ('lt_deduardo_lr_11', 'c_lr_deduardo', 'e_don_eduardo', 'LR 11', 24, 'A2', 24, true, NULL),
    ('lt_deduardo_lr_12', 'c_lr_deduardo', 'e_don_eduardo', 'LR 12', 26, 'A2', 26, true, NULL),
    ('lt_deduardo_lr_12_cn', 'c_lr_deduardo', 'e_don_eduardo', 'LR 12 CN', 19, 'G3', 19, true, NULL),
    ('lt_deduardo_lr_13', 'c_lr_deduardo', 'e_don_eduardo', 'LR 13', 33, 'A1', 33, true, NULL),
    ('lt_deduardo_lr_13_cn', 'c_lr_deduardo', 'e_don_eduardo', 'LR 13 CN', 5, 'G3', 5, true, NULL),
    ('lt_deduardo_lr_14', 'c_lr_deduardo', 'e_don_eduardo', 'LR 14', 34, 'G1', 34, true, NULL),
    ('lt_deduardo_lr_15', 'c_lr_deduardo', 'e_don_eduardo', 'LR 15', 30, 'A2', 30, true, NULL),
    ('lt_deduardo_lr_16', 'c_lr_deduardo', 'e_don_eduardo', 'LR 16', 24, 'A2', 24, true, NULL),
    ('lt_deduardo_lr_16_cn', 'c_lr_deduardo', 'e_don_eduardo', 'LR 16 CN', 6, 'G3', 6, true, NULL),
    ('lt_deduardo_lr_16_bajo', 'c_lr_deduardo', 'e_don_eduardo', 'LR 16 bajo', 10, 'G2', 10, true, NULL),
    ('lt_deduardo_lr_17', 'c_lr_deduardo', 'e_don_eduardo', 'LR 17', 17, 'G1', 17, true, NULL),
    ('lt_deduardo_lr_17_loma', 'c_lr_deduardo', 'e_don_eduardo', 'LR 17 loma', 16, 'G1', 16, true, NULL),
    ('lt_deduardo_lr_18', 'c_lr_deduardo', 'e_don_eduardo', 'LR 18', 40, 'A2', 40, true, NULL),
    ('lt_deduardo_lr_18_cn', 'c_lr_deduardo', 'e_don_eduardo', 'LR 18 CN', 10, 'G3', 10, true, NULL),
    ('lt_deduardo_lr_19', 'c_lr_deduardo', 'e_don_eduardo', 'LR 19', 39, 'A2', 39, true, NULL),
    ('lt_deduardo_lr_19_cn', 'c_lr_deduardo', 'e_don_eduardo', 'LR 19 CN', 11, 'G3', 11, true, NULL),
    ('lt_deduardo_lr_2', 'c_lr_deduardo', 'e_don_eduardo', 'LR 2', 76, 'G5', 76, true, NULL),
    ('lt_deduardo_lr_20', 'c_lr_deduardo', 'e_don_eduardo', 'LR 20', 35, 'G2', 35, true, NULL),
    ('lt_deduardo_lr_20_cn', 'c_lr_deduardo', 'e_don_eduardo', 'LR 20 CN', 43, 'G5', 43, true, NULL),
    ('lt_deduardo_lr_22', 'c_lr_deduardo', 'e_don_eduardo', 'LR 22', 35, 'G3', 35, true, NULL),
    ('lt_deduardo_lr_23', 'c_lr_deduardo', 'e_don_eduardo', 'LR 23', 37, 'G5', 37, true, NULL),
    ('lt_deduardo_lr_25_cn', 'c_lr_deduardo', 'e_don_eduardo', 'LR 25 CN', 106, 'G5', 106, true, NULL),
    ('lt_deduardo_lr_25_loma', 'c_lr_deduardo', 'e_don_eduardo', 'LR 25 loma', 10, 'A2', 10, true, NULL),
    ('lt_deduardo_lr_3_bajo', 'c_lr_deduardo', 'e_don_eduardo', 'LR 3 bajo', 22, 'G2', 22, true, NULL),
    ('lt_deduardo_lr_3_loma', 'c_lr_deduardo', 'e_don_eduardo', 'LR 3 loma', 40, 'A2', 40, true, NULL),
    ('lt_deduardo_lr_4', 'c_lr_deduardo', 'e_don_eduardo', 'LR 4', 12, 'G1', 12, true, NULL),
    ('lt_deduardo_lr_4_cn', 'c_lr_deduardo', 'e_don_eduardo', 'LR 4 CN', 38, 'G4', 38, true, NULL),
    ('lt_deduardo_lr_5', 'c_lr_deduardo', 'e_don_eduardo', 'LR 5', 38, 'G2', 38, true, NULL),
    ('lt_deduardo_lr_6_7', 'c_lr_deduardo', 'e_don_eduardo', 'LR 6/7', 45, 'G1', 45, true, NULL),
    ('lt_deduardo_lr_6_7_cn', 'c_lr_deduardo', 'e_don_eduardo', 'LR 6/7 CN', 75, 'G4', 75, true, NULL),
    ('lt_deduardo_lr_8', 'c_lr_deduardo', 'e_don_eduardo', 'LR 8', 7, 'A1', 7, true, NULL),
    ('lt_deduardo_lr_9', 'c_lr_deduardo', 'e_don_eduardo', 'LR 9', 41, 'A1', 41, true, NULL),
    ('lt_deduardo_lr_desperdicios', 'c_lr_deduardo', 'e_don_eduardo', 'LR Desperdicios', 39, 'DESP', 39, true, NULL),
    ('lt_deduardo_lr_monte_casco', 'c_lr_deduardo', 'e_don_eduardo', 'LR Monte casco', 5, 'A2', 5, true, NULL);

-- Plan de uso del suelo (867 filas: cultivo por lote y campaña, 22/23 a 27/28)
INSERT INTO actividades (id, empresa_id, lote_id, campania_id, tipo_actividad_id, ha, es_segunda, tenencia_id) VALUES
    ('act_lt_deduardo_ec_10_1_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_ec_10_1', 'camp_2223', 'ta_e_don_eduardo_cd_ppfe', 26, false, NULL),
    ('act_lt_deduardo_ec_10_1_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_ec_10_1', 'camp_2324', 'ta_e_don_eduardo_cd_mzt', 25, false, NULL),
    ('act_lt_deduardo_ec_10_1_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_ec_10_1', 'camp_2425', 'ta_e_don_eduardo_cd_g', 25, false, NULL),
    ('act_lt_deduardo_ec_10_1_camp_2425_1', 'e_don_eduardo', 'lt_deduardo_ec_10_1', 'camp_2425', 'ta_e_don_eduardo_cd_pi', 25, true, NULL),
    ('act_lt_deduardo_ec_10_1_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_ec_10_1', 'camp_2526', 'ta_e_don_eduardo_cd_ppalf', 25, false, NULL),
    ('act_lt_deduardo_ec_10_1_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_ec_10_1', 'camp_2627', 'ta_e_don_eduardo_cd_ppalf', 25, false, NULL),
    ('act_lt_deduardo_ec_10_2_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_ec_10_2', 'camp_2223', 'ta_e_don_eduardo_cd_cn', 27, false, NULL),
    ('act_lt_deduardo_ec_10_2_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_ec_10_2', 'camp_2324', 'ta_e_don_eduardo_cd_mzd', 25, false, NULL),
    ('act_lt_deduardo_ec_10_2_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_ec_10_2', 'camp_2425', 'ta_e_don_eduardo_cd_g', 25, false, NULL),
    ('act_lt_deduardo_ec_10_2_camp_2425_1', 'e_don_eduardo', 'lt_deduardo_ec_10_2', 'camp_2425', 'ta_e_don_eduardo_cd_pi', 25, true, NULL),
    ('act_lt_deduardo_ec_10_2_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_ec_10_2', 'camp_2526', 'ta_e_don_eduardo_cd_ppalf', 25, false, NULL),
    ('act_lt_deduardo_ec_10_2_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_ec_10_2', 'camp_2627', 'ta_e_don_eduardo_cd_ppalf', 25, false, NULL),
    ('act_lt_deduardo_ec_10_3_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_ec_10_3', 'camp_2223', 'ta_e_don_eduardo_cd_mzp', 20, false, NULL),
    ('act_lt_deduardo_ec_10_3_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_ec_10_3', 'camp_2324', 'ta_e_don_eduardo_cd_mzp', 20, false, NULL),
    ('act_lt_deduardo_ec_10_3_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_ec_10_3', 'camp_2425', 'ta_e_don_eduardo_cd_g', 20, false, NULL),
    ('act_lt_deduardo_ec_10_3_camp_2425_1', 'e_don_eduardo', 'lt_deduardo_ec_10_3', 'camp_2425', 'ta_e_don_eduardo_cd_pi', 20, true, NULL),
    ('act_lt_deduardo_ec_10_3_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_ec_10_3', 'camp_2526', 'ta_e_don_eduardo_cd_ppalf', 20, false, NULL),
    ('act_lt_deduardo_ec_10_3_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_ec_10_3', 'camp_2627', 'ta_e_don_eduardo_cd_ppalf', 20, false, NULL),
    ('act_lt_deduardo_ec_11_bajo_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_ec_11_bajo', 'camp_2223', 'ta_e_don_eduardo_cd_cn', 33, false, NULL),
    ('act_lt_deduardo_ec_11_bajo_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_ec_11_bajo', 'camp_2324', 'ta_e_don_eduardo_cd_cn', 33, false, NULL),
    ('act_lt_deduardo_ec_11_bajo_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_ec_11_bajo', 'camp_2425', 'ta_e_don_eduardo_cd_cn', 33, false, NULL),
    ('act_lt_deduardo_ec_11_bajo_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_ec_11_bajo', 'camp_2526', 'ta_e_don_eduardo_cd_cn', 33, false, NULL),
    ('act_lt_deduardo_ec_11_bajo_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_ec_11_bajo', 'camp_2627', 'ta_e_don_eduardo_cd_cn', 33, false, NULL),
    ('act_lt_deduardo_ec_11_loma_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_ec_11_loma', 'camp_2223', 'ta_e_don_eduardo_cd_ppfe', 25, false, NULL),
    ('act_lt_deduardo_ec_11_loma_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_ec_11_loma', 'camp_2324', 'ta_e_don_eduardo_cd_ppfe', 25, false, NULL),
    ('act_lt_deduardo_ec_11_loma_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_ec_11_loma', 'camp_2425', 'ta_e_don_eduardo_cd_ppfe', 25, false, NULL),
    ('act_lt_deduardo_ec_11_loma_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_ec_11_loma', 'camp_2526', 'ta_e_don_eduardo_cd_g', 25, false, NULL),
    ('act_lt_deduardo_ec_11_loma_camp_2526_1', 'e_don_eduardo', 'lt_deduardo_ec_11_loma', 'camp_2526', 'ta_e_don_eduardo_cd_pi', 25, true, NULL),
    ('act_lt_deduardo_ec_11_loma_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_ec_11_loma', 'camp_2627', 'ta_e_don_eduardo_cd_ppalf', 25, false, NULL),
    ('act_lt_deduardo_ec_12_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_ec_12', 'camp_2223', 'ta_e_don_eduardo_cd_cn', 54, false, NULL),
    ('act_lt_deduardo_ec_12_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_ec_12', 'camp_2324', 'ta_e_don_eduardo_cd_cn', 54, false, NULL),
    ('act_lt_deduardo_ec_12_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_ec_12', 'camp_2425', 'ta_e_don_eduardo_cd_cn', 54, false, NULL),
    ('act_lt_deduardo_ec_12_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_ec_12', 'camp_2526', 'ta_e_don_eduardo_cd_cn', 54, false, NULL),
    ('act_lt_deduardo_ec_12_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_ec_12', 'camp_2627', 'ta_e_don_eduardo_cd_cn', 54, false, NULL),
    ('act_lt_deduardo_ec_12_loma_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_ec_12_loma', 'camp_2223', 'ta_e_don_eduardo_cd_ppalf', 4, false, NULL),
    ('act_lt_deduardo_ec_12_loma_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_ec_12_loma', 'camp_2324', 'ta_e_don_eduardo_cd_ppalf', 4, false, NULL),
    ('act_lt_deduardo_ec_12_loma_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_ec_12_loma', 'camp_2425', 'ta_e_don_eduardo_cd_g', 4, false, NULL),
    ('act_lt_deduardo_ec_12_loma_camp_2425_1', 'e_don_eduardo', 'lt_deduardo_ec_12_loma', 'camp_2425', 'ta_e_don_eduardo_cd_vi', 4, true, NULL),
    ('act_lt_deduardo_ec_12_loma_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_ec_12_loma', 'camp_2526', 'ta_e_don_eduardo_cd_mz', 4, false, NULL),
    ('act_lt_deduardo_ec_12_loma_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_ec_12_loma', 'camp_2627', 'ta_e_don_eduardo_cd_sj1', 4, false, NULL),
    ('act_lt_deduardo_ec_12_loma_camp_2728_0', 'e_don_eduardo', 'lt_deduardo_ec_12_loma', 'camp_2728', 'ta_e_don_eduardo_cd_tr', 4, false, NULL),
    ('act_lt_deduardo_ec_12_loma_camp_2728_1', 'e_don_eduardo', 'lt_deduardo_ec_12_loma', 'camp_2728', 'ta_e_don_eduardo_cd_sj2', 4, true, NULL),
    ('act_lt_deduardo_ec_13_cn_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_ec_13_cn', 'camp_2223', 'ta_e_don_eduardo_cd_cn', 40, false, NULL),
    ('act_lt_deduardo_ec_13_cn_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_ec_13_cn', 'camp_2324', 'ta_e_don_eduardo_cd_cn', 40, false, NULL),
    ('act_lt_deduardo_ec_13_cn_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_ec_13_cn', 'camp_2425', 'ta_e_don_eduardo_cd_cn', 40, false, NULL),
    ('act_lt_deduardo_ec_13_cn_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_ec_13_cn', 'camp_2526', 'ta_e_don_eduardo_cd_cn', 40, false, NULL),
    ('act_lt_deduardo_ec_13_cn_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_ec_13_cn', 'camp_2627', 'ta_e_don_eduardo_cd_cn', 40, false, NULL),
    ('act_lt_deduardo_ec_13_loma_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_ec_13_loma', 'camp_2223', 'ta_e_don_eduardo_cd_tr', 35, false, NULL),
    ('act_lt_deduardo_ec_13_loma_camp_2223_1', 'e_don_eduardo', 'lt_deduardo_ec_13_loma', 'camp_2223', 'ta_e_don_eduardo_cd_sj2', 35, true, NULL),
    ('act_lt_deduardo_ec_13_loma_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_ec_13_loma', 'camp_2324', 'ta_e_don_eduardo_cd_g', 34, false, NULL),
    ('act_lt_deduardo_ec_13_loma_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_ec_13_loma', 'camp_2425', 'ta_e_don_eduardo_cd_tr', 34, false, NULL),
    ('act_lt_deduardo_ec_13_loma_camp_2425_1', 'e_don_eduardo', 'lt_deduardo_ec_13_loma', 'camp_2425', 'ta_e_don_eduardo_cd_sj2', 34, true, NULL),
    ('act_lt_deduardo_ec_13_loma_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_ec_13_loma', 'camp_2526', 'ta_e_don_eduardo_cd_mz', 34, false, NULL),
    ('act_lt_deduardo_ec_13_loma_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_ec_13_loma', 'camp_2627', 'ta_e_don_eduardo_cd_sj1', 34, false, NULL),
    ('act_lt_deduardo_ec_13_loma_camp_2728_0', 'e_don_eduardo', 'lt_deduardo_ec_13_loma', 'camp_2728', 'ta_e_don_eduardo_cd_tr', 34, false, NULL),
    ('act_lt_deduardo_ec_13_loma_camp_2728_1', 'e_don_eduardo', 'lt_deduardo_ec_13_loma', 'camp_2728', 'ta_e_don_eduardo_cd_sj2', 34, true, NULL),
    ('act_lt_deduardo_ec_14_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_ec_14', 'camp_2223', 'ta_e_don_eduardo_cd_g', 65, false, NULL),
    ('act_lt_deduardo_ec_14_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_ec_14', 'camp_2324', 'ta_e_don_eduardo_cd_tr', 65, false, NULL),
    ('act_lt_deduardo_ec_14_camp_2324_1', 'e_don_eduardo', 'lt_deduardo_ec_14', 'camp_2324', 'ta_e_don_eduardo_cd_sj2', 65, true, NULL),
    ('act_lt_deduardo_ec_14_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_ec_14', 'camp_2425', 'ta_e_don_eduardo_cd_mz', 64, false, NULL),
    ('act_lt_deduardo_ec_14_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_ec_14', 'camp_2526', 'ta_e_don_eduardo_cd_tr', 64, false, NULL),
    ('act_lt_deduardo_ec_14_camp_2526_1', 'e_don_eduardo', 'lt_deduardo_ec_14', 'camp_2526', 'ta_e_don_eduardo_cd_sj2', 64, true, NULL),
    ('act_lt_deduardo_ec_14_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_ec_14', 'camp_2627', 'ta_e_don_eduardo_cd_mz', 64, false, NULL),
    ('act_lt_deduardo_ec_14_camp_2728_0', 'e_don_eduardo', 'lt_deduardo_ec_14', 'camp_2728', 'ta_e_don_eduardo_cd_sj1', 64, false, NULL),
    ('act_lt_deduardo_ec_14_cn_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_ec_14_cn', 'camp_2223', 'ta_e_don_eduardo_cd_cn', 10, false, NULL),
    ('act_lt_deduardo_ec_14_cn_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_ec_14_cn', 'camp_2324', 'ta_e_don_eduardo_cd_cn', 10, false, NULL),
    ('act_lt_deduardo_ec_14_cn_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_ec_14_cn', 'camp_2425', 'ta_e_don_eduardo_cd_cn', 10, false, NULL),
    ('act_lt_deduardo_ec_14_cn_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_ec_14_cn', 'camp_2526', 'ta_e_don_eduardo_cd_cn', 10, false, NULL),
    ('act_lt_deduardo_ec_14_cn_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_ec_14_cn', 'camp_2627', 'ta_e_don_eduardo_cd_cn', 10, false, NULL),
    ('act_lt_deduardo_ec_15_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_ec_15', 'camp_2223', 'ta_e_don_eduardo_cd_g', 17, false, NULL),
    ('act_lt_deduardo_ec_15_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_ec_15', 'camp_2324', 'ta_e_don_eduardo_cd_pi', 17, false, NULL),
    ('act_lt_deduardo_ec_15_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_ec_15', 'camp_2425', 'ta_e_don_eduardo_cd_ppfe', 17, false, NULL),
    ('act_lt_deduardo_ec_15_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_ec_15', 'camp_2526', 'ta_e_don_eduardo_cd_ppfe', 17, false, NULL),
    ('act_lt_deduardo_ec_15_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_ec_15', 'camp_2627', 'ta_e_don_eduardo_cd_ppfe', 17, false, NULL),
    ('act_lt_deduardo_ec_15_cn_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_ec_15_cn', 'camp_2223', 'ta_e_don_eduardo_cd_cn', 40, false, NULL),
    ('act_lt_deduardo_ec_15_cn_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_ec_15_cn', 'camp_2324', 'ta_e_don_eduardo_cd_cn', 40, false, NULL),
    ('act_lt_deduardo_ec_15_cn_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_ec_15_cn', 'camp_2425', 'ta_e_don_eduardo_cd_cn', 40, false, NULL),
    ('act_lt_deduardo_ec_15_cn_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_ec_15_cn', 'camp_2526', 'ta_e_don_eduardo_cd_cn', 40, false, NULL),
    ('act_lt_deduardo_ec_15_cn_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_ec_15_cn', 'camp_2627', 'ta_e_don_eduardo_cd_cn', 40, false, NULL),
    ('act_lt_deduardo_ec_16_bajo_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_ec_16_bajo', 'camp_2223', 'ta_e_don_eduardo_cd_ppalf', 20, false, NULL),
    ('act_lt_deduardo_ec_16_bajo_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_ec_16_bajo', 'camp_2324', 'ta_e_don_eduardo_cd_ppalf', 20, false, NULL),
    ('act_lt_deduardo_ec_16_bajo_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_ec_16_bajo', 'camp_2425', 'ta_e_don_eduardo_cd_ppalf', 20, false, NULL),
    ('act_lt_deduardo_ec_16_bajo_camp_2425_1', 'e_don_eduardo', 'lt_deduardo_ec_16_bajo', 'camp_2425', 'ta_e_don_eduardo_cd_vi', 20, true, NULL),
    ('act_lt_deduardo_ec_16_bajo_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_ec_16_bajo', 'camp_2526', 'ta_e_don_eduardo_cd_g', 20, false, NULL),
    ('act_lt_deduardo_ec_16_bajo_camp_2526_1', 'e_don_eduardo', 'lt_deduardo_ec_16_bajo', 'camp_2526', 'ta_e_don_eduardo_cd_pi', 20, true, NULL),
    ('act_lt_deduardo_ec_16_bajo_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_ec_16_bajo', 'camp_2627', 'ta_e_don_eduardo_cd_ppfe', 20, false, NULL),
    ('act_lt_deduardo_ec_16_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_ec_16', 'camp_2223', 'ta_e_don_eduardo_cd_g', 29, false, NULL),
    ('act_lt_deduardo_ec_16_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_ec_16', 'camp_2324', 'ta_e_don_eduardo_cd_pi', 29, false, NULL),
    ('act_lt_deduardo_ec_16_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_ec_16', 'camp_2425', 'ta_e_don_eduardo_cd_ppalf', 29, false, NULL),
    ('act_lt_deduardo_ec_16_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_ec_16', 'camp_2526', 'ta_e_don_eduardo_cd_ppalf', 29, false, NULL),
    ('act_lt_deduardo_ec_16_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_ec_16', 'camp_2627', 'ta_e_don_eduardo_cd_ppalf', 29, false, NULL),
    ('act_lt_deduardo_ec_1a_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_ec_1a', 'camp_2223', 'ta_e_don_eduardo_cd_ppfe', 28, false, NULL),
    ('act_lt_deduardo_ec_1a_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_ec_1a', 'camp_2324', 'ta_e_don_eduardo_cd_ppfe', 28, false, NULL),
    ('act_lt_deduardo_ec_1a_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_ec_1a', 'camp_2425', 'ta_e_don_eduardo_cd_g', 28, false, NULL),
    ('act_lt_deduardo_ec_1a_camp_2425_1', 'e_don_eduardo', 'lt_deduardo_ec_1a', 'camp_2425', 'ta_e_don_eduardo_cd_pi', 28, true, NULL),
    ('act_lt_deduardo_ec_1a_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_ec_1a', 'camp_2526', 'ta_e_don_eduardo_cd_ppalf', 28, false, NULL),
    ('act_lt_deduardo_ec_1a_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_ec_1a', 'camp_2627', 'ta_e_don_eduardo_cd_ppalf', 28, false, NULL),
    ('act_lt_deduardo_ec_1a_cn_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_ec_1a_cn', 'camp_2223', 'ta_e_don_eduardo_cd_cn', 21, false, NULL),
    ('act_lt_deduardo_ec_1a_cn_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_ec_1a_cn', 'camp_2324', 'ta_e_don_eduardo_cd_cn', 21, false, NULL),
    ('act_lt_deduardo_ec_1a_cn_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_ec_1a_cn', 'camp_2425', 'ta_e_don_eduardo_cd_cn', 21, false, NULL),
    ('act_lt_deduardo_ec_1a_cn_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_ec_1a_cn', 'camp_2526', 'ta_e_don_eduardo_cd_cn', 21, false, NULL),
    ('act_lt_deduardo_ec_1a_cn_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_ec_1a_cn', 'camp_2627', 'ta_e_don_eduardo_cd_cn', 21, false, NULL),
    ('act_lt_deduardo_ec_1b_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_ec_1b', 'camp_2223', 'ta_e_don_eduardo_cd_ppfe', 27, false, NULL),
    ('act_lt_deduardo_ec_1b_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_ec_1b', 'camp_2324', 'ta_e_don_eduardo_cd_ppfe', 20, false, NULL),
    ('act_lt_deduardo_ec_1b_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_ec_1b', 'camp_2425', 'ta_e_don_eduardo_cd_g', 20, false, NULL),
    ('act_lt_deduardo_ec_1b_camp_2425_1', 'e_don_eduardo', 'lt_deduardo_ec_1b', 'camp_2425', 'ta_e_don_eduardo_cd_pi', 20, true, NULL),
    ('act_lt_deduardo_ec_1b_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_ec_1b', 'camp_2526', 'ta_e_don_eduardo_cd_ppfe', 20, false, NULL),
    ('act_lt_deduardo_ec_1b_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_ec_1b', 'camp_2627', 'ta_e_don_eduardo_cd_ppfe', 20, false, NULL),
    ('act_lt_deduardo_ec_1b_cn_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_ec_1b_cn', 'camp_2223', 'ta_e_don_eduardo_cd_cn', 20, false, NULL),
    ('act_lt_deduardo_ec_1b_cn_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_ec_1b_cn', 'camp_2324', 'ta_e_don_eduardo_cd_cn', 20, false, NULL),
    ('act_lt_deduardo_ec_1b_cn_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_ec_1b_cn', 'camp_2425', 'ta_e_don_eduardo_cd_cn', 20, false, NULL),
    ('act_lt_deduardo_ec_1b_cn_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_ec_1b_cn', 'camp_2526', 'ta_e_don_eduardo_cd_cn', 20, false, NULL),
    ('act_lt_deduardo_ec_1b_cn_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_ec_1b_cn', 'camp_2627', 'ta_e_don_eduardo_cd_cn', 20, false, NULL),
    ('act_lt_deduardo_ec_2a_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_ec_2a', 'camp_2223', 'ta_e_don_eduardo_cd_ppfe', 27, false, NULL),
    ('act_lt_deduardo_ec_2a_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_ec_2a', 'camp_2324', 'ta_e_don_eduardo_cd_ppfe', 19, false, NULL),
    ('act_lt_deduardo_ec_2a_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_ec_2a', 'camp_2425', 'ta_e_don_eduardo_cd_g', 19, false, NULL),
    ('act_lt_deduardo_ec_2a_camp_2425_1', 'e_don_eduardo', 'lt_deduardo_ec_2a', 'camp_2425', 'ta_e_don_eduardo_cd_pi', 19, true, NULL),
    ('act_lt_deduardo_ec_2a_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_ec_2a', 'camp_2526', 'ta_e_don_eduardo_cd_ppfe', 19, false, NULL),
    ('act_lt_deduardo_ec_2a_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_ec_2a', 'camp_2627', 'ta_e_don_eduardo_cd_ppfe', 19, false, NULL),
    ('act_lt_deduardo_ec_2a_cn1_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_ec_2a_cn1', 'camp_2526', 'ta_e_don_eduardo_cd_cn', 9.5, false, NULL),
    ('act_lt_deduardo_ec_2a_cn1_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_ec_2a_cn1', 'camp_2627', 'ta_e_don_eduardo_cd_cn', 9.5, false, NULL),
    ('act_lt_deduardo_ec_2a_cn1_camp_2627_1', 'e_don_eduardo', 'lt_deduardo_ec_2a_cn1', 'camp_2627', 'ta_e_don_eduardo_cd_vi', 9.5, true, NULL),
    ('act_lt_deduardo_ec_2a_cn1_camp_2728_0', 'e_don_eduardo', 'lt_deduardo_ec_2a_cn1', 'camp_2728', 'ta_e_don_eduardo_cd_mzp', 9.5, false, NULL),
    ('act_lt_deduardo_ec_2a_cn1_camp_2728_1', 'e_don_eduardo', 'lt_deduardo_ec_2a_cn1', 'camp_2728', 'ta_e_don_eduardo_cd_pi', 9.5, true, NULL),
    ('act_lt_deduardo_ec_2a_cn_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_ec_2a_cn', 'camp_2223', 'ta_e_don_eduardo_cd_cn', 20, false, NULL),
    ('act_lt_deduardo_ec_2a_cn_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_ec_2a_cn', 'camp_2324', 'ta_e_don_eduardo_cd_cn', 20, false, NULL),
    ('act_lt_deduardo_ec_2a_cn_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_ec_2a_cn', 'camp_2425', 'ta_e_don_eduardo_cd_cn', 20, false, NULL),
    ('act_lt_deduardo_ec_2a_cn_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_ec_2a_cn', 'camp_2526', 'ta_e_don_eduardo_cd_cn', 10.5, false, NULL),
    ('act_lt_deduardo_ec_2a_cn_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_ec_2a_cn', 'camp_2627', 'ta_e_don_eduardo_cd_cn', 10.5, false, NULL),
    ('act_lt_deduardo_ec_2b_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_ec_2b', 'camp_2223', 'ta_e_don_eduardo_cd_cn', 45, false, NULL),
    ('act_lt_deduardo_ec_2b_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_ec_2b', 'camp_2324', 'ta_e_don_eduardo_cd_cn', 45, false, NULL),
    ('act_lt_deduardo_ec_2b_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_ec_2b', 'camp_2425', 'ta_e_don_eduardo_cd_cn', 45, false, NULL),
    ('act_lt_deduardo_ec_2b_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_ec_2b', 'camp_2526', 'ta_e_don_eduardo_cd_cn', 30, false, NULL),
    ('act_lt_deduardo_ec_2b_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_ec_2b', 'camp_2627', 'ta_e_don_eduardo_cd_cn', 30, false, NULL),
    ('act_lt_deduardo_ec_2b_cn1_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_ec_2b_cn1', 'camp_2526', 'ta_e_don_eduardo_cd_cn', 15, false, NULL),
    ('act_lt_deduardo_ec_2b_cn1_camp_2526_1', 'e_don_eduardo', 'lt_deduardo_ec_2b_cn1', 'camp_2526', 'ta_e_don_eduardo_cd_vi', 15, true, NULL),
    ('act_lt_deduardo_ec_2b_cn1_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_ec_2b_cn1', 'camp_2627', 'ta_e_don_eduardo_cd_g', 15, false, NULL),
    ('act_lt_deduardo_ec_2b_cn1_camp_2627_1', 'e_don_eduardo', 'lt_deduardo_ec_2b_cn1', 'camp_2627', 'ta_e_don_eduardo_cd_vi', 15, true, NULL),
    ('act_lt_deduardo_ec_2b_cn1_camp_2728_0', 'e_don_eduardo', 'lt_deduardo_ec_2b_cn1', 'camp_2728', 'ta_e_don_eduardo_cd_mzp', 15, false, NULL),
    ('act_lt_deduardo_ec_2b_cn1_camp_2728_1', 'e_don_eduardo', 'lt_deduardo_ec_2b_cn1', 'camp_2728', 'ta_e_don_eduardo_cd_pi', 15, true, NULL),
    ('act_lt_deduardo_ec_3_cn_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_ec_3_cn', 'camp_2223', 'ta_e_don_eduardo_cd_cn', 57, false, NULL),
    ('act_lt_deduardo_ec_3_cn_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_ec_3_cn', 'camp_2324', 'ta_e_don_eduardo_cd_cn', 57, false, NULL),
    ('act_lt_deduardo_ec_3_cn_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_ec_3_cn', 'camp_2425', 'ta_e_don_eduardo_cd_cn', 57, false, NULL),
    ('act_lt_deduardo_ec_3_cn_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_ec_3_cn', 'camp_2526', 'ta_e_don_eduardo_cd_cn', 57, false, NULL),
    ('act_lt_deduardo_ec_3_cn_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_ec_3_cn', 'camp_2627', 'ta_e_don_eduardo_cd_cn', 57, false, NULL),
    ('act_lt_deduardo_ec_3_loma_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_ec_3_loma', 'camp_2223', 'ta_e_don_eduardo_cd_mz', 26, false, NULL),
    ('act_lt_deduardo_ec_3_loma_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_ec_3_loma', 'camp_2324', 'ta_e_don_eduardo_cd_g', 26, false, NULL),
    ('act_lt_deduardo_ec_3_loma_camp_2324_1', 'e_don_eduardo', 'lt_deduardo_ec_3_loma', 'camp_2324', 'ta_e_don_eduardo_cd_pi', 26, true, NULL),
    ('act_lt_deduardo_ec_3_loma_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_ec_3_loma', 'camp_2425', 'ta_e_don_eduardo_cd_ppalf', 26, false, NULL),
    ('act_lt_deduardo_ec_3_loma_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_ec_3_loma', 'camp_2526', 'ta_e_don_eduardo_cd_ppalf', 26, false, NULL),
    ('act_lt_deduardo_ec_3_loma_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_ec_3_loma', 'camp_2627', 'ta_e_don_eduardo_cd_ppalf', 26, false, NULL),
    ('act_lt_deduardo_ec_4_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_ec_4', 'camp_2223', 'ta_e_don_eduardo_cd_ppfe', 35, false, NULL),
    ('act_lt_deduardo_ec_4_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_ec_4', 'camp_2324', 'ta_e_don_eduardo_cd_ppfe', 35, false, NULL),
    ('act_lt_deduardo_ec_4_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_ec_4', 'camp_2425', 'ta_e_don_eduardo_cd_g', 35, false, NULL),
    ('act_lt_deduardo_ec_4_camp_2425_1', 'e_don_eduardo', 'lt_deduardo_ec_4', 'camp_2425', 'ta_e_don_eduardo_cd_vi', 35, true, NULL),
    ('act_lt_deduardo_ec_4_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_ec_4', 'camp_2526', 'ta_e_don_eduardo_cd_sj1', 35, false, NULL),
    ('act_lt_deduardo_ec_4_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_ec_4', 'camp_2627', 'ta_e_don_eduardo_cd_g', 35, false, NULL),
    ('act_lt_deduardo_ec_4_camp_2627_1', 'e_don_eduardo', 'lt_deduardo_ec_4', 'camp_2627', 'ta_e_don_eduardo_cd_pi', 35, true, NULL),
    ('act_lt_deduardo_ec_4_camp_2728_0', 'e_don_eduardo', 'lt_deduardo_ec_4', 'camp_2728', 'ta_e_don_eduardo_cd_ppalf', 35, false, NULL),
    ('act_lt_deduardo_ec_4_loma_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_ec_4_loma', 'camp_2223', 'ta_e_don_eduardo_cd_ppfe', 20, false, NULL),
    ('act_lt_deduardo_ec_4_loma_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_ec_4_loma', 'camp_2324', 'ta_e_don_eduardo_cd_ppfe', 20, false, NULL),
    ('act_lt_deduardo_ec_4_loma_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_ec_4_loma', 'camp_2425', 'ta_e_don_eduardo_cd_g', 20, false, NULL),
    ('act_lt_deduardo_ec_4_loma_camp_2425_1', 'e_don_eduardo', 'lt_deduardo_ec_4_loma', 'camp_2425', 'ta_e_don_eduardo_cd_vi', 20, true, NULL),
    ('act_lt_deduardo_ec_4_loma_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_ec_4_loma', 'camp_2526', 'ta_e_don_eduardo_cd_mz', 20, false, NULL),
    ('act_lt_deduardo_ec_4_loma_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_ec_4_loma', 'camp_2627', 'ta_e_don_eduardo_cd_sj1', 20, false, NULL),
    ('act_lt_deduardo_ec_4_loma_camp_2728_0', 'e_don_eduardo', 'lt_deduardo_ec_4_loma', 'camp_2728', 'ta_e_don_eduardo_cd_tr', 20, false, NULL),
    ('act_lt_deduardo_ec_4_loma_camp_2728_1', 'e_don_eduardo', 'lt_deduardo_ec_4_loma', 'camp_2728', 'ta_e_don_eduardo_cd_sj2', 20, true, NULL),
    ('act_lt_deduardo_ec_5_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_ec_5', 'camp_2223', 'ta_e_don_eduardo_cd_cn', 78, false, NULL),
    ('act_lt_deduardo_ec_5_camp_2223_1', 'e_don_eduardo', 'lt_deduardo_ec_5', 'camp_2223', 'ta_e_don_eduardo_cd_vi', 78, true, NULL),
    ('act_lt_deduardo_ec_5_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_ec_5', 'camp_2324', 'ta_e_don_eduardo_cd_vi', 78, false, NULL),
    ('act_lt_deduardo_ec_5_camp_2324_1', 'e_don_eduardo', 'lt_deduardo_ec_5', 'camp_2324', 'ta_e_don_eduardo_cd_pi', 78, true, NULL),
    ('act_lt_deduardo_ec_5_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_ec_5', 'camp_2425', 'ta_e_don_eduardo_cd_ppalf', 78, false, NULL),
    ('act_lt_deduardo_ec_5_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_ec_5', 'camp_2526', 'ta_e_don_eduardo_cd_ppalf', 78, false, NULL),
    ('act_lt_deduardo_ec_5_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_ec_5', 'camp_2627', 'ta_e_don_eduardo_cd_ppalf', 78, false, NULL),
    ('act_lt_deduardo_ec_6_bajo_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_ec_6_bajo', 'camp_2223', 'ta_e_don_eduardo_cd_cn', 36, false, NULL),
    ('act_lt_deduardo_ec_6_bajo_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_ec_6_bajo', 'camp_2324', 'ta_e_don_eduardo_cd_cn', 36, false, NULL),
    ('act_lt_deduardo_ec_6_bajo_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_ec_6_bajo', 'camp_2425', 'ta_e_don_eduardo_cd_cn', 36, false, NULL),
    ('act_lt_deduardo_ec_6_bajo_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_ec_6_bajo', 'camp_2526', 'ta_e_don_eduardo_cd_cn', 36, false, NULL),
    ('act_lt_deduardo_ec_6_bajo_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_ec_6_bajo', 'camp_2627', 'ta_e_don_eduardo_cd_cn', 36, false, NULL),
    ('act_lt_deduardo_ec_6_loma_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_ec_6_loma', 'camp_2223', 'ta_e_don_eduardo_cd_mzp', 30, false, NULL),
    ('act_lt_deduardo_ec_6_loma_camp_2223_1', 'e_don_eduardo', 'lt_deduardo_ec_6_loma', 'camp_2223', 'ta_e_don_eduardo_cd_vi', 30, true, NULL),
    ('act_lt_deduardo_ec_6_loma_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_ec_6_loma', 'camp_2324', 'ta_e_don_eduardo_cd_vi', 30, false, NULL),
    ('act_lt_deduardo_ec_6_loma_camp_2324_1', 'e_don_eduardo', 'lt_deduardo_ec_6_loma', 'camp_2324', 'ta_e_don_eduardo_cd_pi', 30, true, NULL),
    ('act_lt_deduardo_ec_6_loma_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_ec_6_loma', 'camp_2425', 'ta_e_don_eduardo_cd_ppalf', 30, false, NULL),
    ('act_lt_deduardo_ec_6_loma_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_ec_6_loma', 'camp_2526', 'ta_e_don_eduardo_cd_ppalf', 30, false, NULL),
    ('act_lt_deduardo_ec_6_loma_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_ec_6_loma', 'camp_2627', 'ta_e_don_eduardo_cd_ppalf', 30, false, NULL),
    ('act_lt_deduardo_ec_7_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_ec_7', 'camp_2223', 'ta_e_don_eduardo_cd_ppalf', 27, false, NULL),
    ('act_lt_deduardo_ec_7_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_ec_7', 'camp_2324', 'ta_e_don_eduardo_cd_ppalf', 27, false, NULL),
    ('act_lt_deduardo_ec_7_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_ec_7', 'camp_2425', 'ta_e_don_eduardo_cd_g', 27, false, NULL),
    ('act_lt_deduardo_ec_7_camp_2425_1', 'e_don_eduardo', 'lt_deduardo_ec_7', 'camp_2425', 'ta_e_don_eduardo_cd_vi', 27, true, NULL),
    ('act_lt_deduardo_ec_7_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_ec_7', 'camp_2526', 'ta_e_don_eduardo_cd_sj1', 27, false, NULL),
    ('act_lt_deduardo_ec_7_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_ec_7', 'camp_2627', 'ta_e_don_eduardo_cd_g', 27, false, NULL),
    ('act_lt_deduardo_ec_7_camp_2627_1', 'e_don_eduardo', 'lt_deduardo_ec_7', 'camp_2627', 'ta_e_don_eduardo_cd_pi', 27, true, NULL),
    ('act_lt_deduardo_ec_7_camp_2728_0', 'e_don_eduardo', 'lt_deduardo_ec_7', 'camp_2728', 'ta_e_don_eduardo_cd_ppalf', 27, false, NULL),
    ('act_lt_deduardo_ec_8_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_ec_8', 'camp_2223', 'ta_e_don_eduardo_cd_cn', 20, false, NULL),
    ('act_lt_deduardo_ec_8_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_ec_8', 'camp_2324', 'ta_e_don_eduardo_cd_mzspe', 18, false, NULL),
    ('act_lt_deduardo_ec_8_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_ec_8', 'camp_2425', 'ta_e_don_eduardo_cd_g', 18, false, NULL),
    ('act_lt_deduardo_ec_8_camp_2425_1', 'e_don_eduardo', 'lt_deduardo_ec_8', 'camp_2425', 'ta_e_don_eduardo_cd_pi', 18, true, NULL),
    ('act_lt_deduardo_ec_8_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_ec_8', 'camp_2526', 'ta_e_don_eduardo_cd_ppalf', 18, false, NULL),
    ('act_lt_deduardo_ec_8_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_ec_8', 'camp_2627', 'ta_e_don_eduardo_cd_ppalf', 18, false, NULL),
    ('act_lt_deduardo_ec_dp1_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_ec_dp1', 'camp_2223', 'ta_e_don_eduardo_cd_ppfe', 45, false, NULL),
    ('act_lt_deduardo_ec_dp1_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_ec_dp1', 'camp_2324', 'ta_e_don_eduardo_cd_mzt', 45, false, NULL),
    ('act_lt_deduardo_ec_dp1_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_ec_dp1', 'camp_2425', 'ta_e_don_eduardo_cd_g', 45, false, NULL),
    ('act_lt_deduardo_ec_dp1_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_ec_dp1', 'camp_2526', 'ta_e_don_eduardo_cd_tr', 45, false, NULL),
    ('act_lt_deduardo_ec_dp1_camp_2526_1', 'e_don_eduardo', 'lt_deduardo_ec_dp1', 'camp_2526', 'ta_e_don_eduardo_cd_sj2', 45, true, NULL),
    ('act_lt_deduardo_ec_dp1_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_ec_dp1', 'camp_2627', 'ta_e_don_eduardo_cd_g', 45, false, NULL),
    ('act_lt_deduardo_ec_dp1_camp_2627_1', 'e_don_eduardo', 'lt_deduardo_ec_dp1', 'camp_2627', 'ta_e_don_eduardo_cd_vi', 45, true, NULL),
    ('act_lt_deduardo_ec_dp1_camp_2728_0', 'e_don_eduardo', 'lt_deduardo_ec_dp1', 'camp_2728', 'ta_e_don_eduardo_cd_mzt', 45, false, NULL),
    ('act_lt_deduardo_ec_dp2_3_laguna_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_ec_dp2_3_laguna', 'camp_2223', 'ta_e_don_eduardo_cd_cnd', 26, false, NULL),
    ('act_lt_deduardo_ec_dp2_3_laguna_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_ec_dp2_3_laguna', 'camp_2324', 'ta_e_don_eduardo_cd_cnd', 26, false, NULL),
    ('act_lt_deduardo_ec_dp2_3_laguna_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_ec_dp2_3_laguna', 'camp_2425', 'ta_e_don_eduardo_cd_cnd', 26, false, NULL),
    ('act_lt_deduardo_ec_dp2_3_laguna_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_ec_dp2_3_laguna', 'camp_2526', 'ta_e_don_eduardo_cd_cnd', 26, false, NULL),
    ('act_lt_deduardo_ec_dp2_3_laguna_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_ec_dp2_3_laguna', 'camp_2627', 'ta_e_don_eduardo_cd_cnd', 26, false, NULL),
    ('act_lt_deduardo_ec_dp2_cn1_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_ec_dp2_cn1', 'camp_2526', 'ta_e_don_eduardo_cd_cn', 7, false, NULL),
    ('act_lt_deduardo_ec_dp2_cn1_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_ec_dp2_cn1', 'camp_2627', 'ta_e_don_eduardo_cd_cn', 7, false, NULL),
    ('act_lt_deduardo_ec_dp2_cn1_camp_2627_1', 'e_don_eduardo', 'lt_deduardo_ec_dp2_cn1', 'camp_2627', 'ta_e_don_eduardo_cd_vi', 7, true, NULL),
    ('act_lt_deduardo_ec_dp2_cn1_camp_2728_0', 'e_don_eduardo', 'lt_deduardo_ec_dp2_cn1', 'camp_2728', 'ta_e_don_eduardo_cd_mzp', 7, false, NULL),
    ('act_lt_deduardo_ec_dp2_cn1_camp_2728_1', 'e_don_eduardo', 'lt_deduardo_ec_dp2_cn1', 'camp_2728', 'ta_e_don_eduardo_cd_pi', 7, true, NULL),
    ('act_lt_deduardo_ec_dp2_cn_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_ec_dp2_cn', 'camp_2223', 'ta_e_don_eduardo_cd_cn', 37, false, NULL),
    ('act_lt_deduardo_ec_dp2_cn_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_ec_dp2_cn', 'camp_2324', 'ta_e_don_eduardo_cd_cn', 37, false, NULL),
    ('act_lt_deduardo_ec_dp2_cn_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_ec_dp2_cn', 'camp_2425', 'ta_e_don_eduardo_cd_cn', 37, false, NULL),
    ('act_lt_deduardo_ec_dp2_cn_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_ec_dp2_cn', 'camp_2526', 'ta_e_don_eduardo_cd_cn', 30, false, NULL),
    ('act_lt_deduardo_ec_dp2_cn_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_ec_dp2_cn', 'camp_2627', 'ta_e_don_eduardo_cd_cn', 30, false, NULL),
    ('act_lt_deduardo_ec_dp3_cn1_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_ec_dp3_cn1', 'camp_2526', 'ta_e_don_eduardo_cd_cn', 5, false, NULL),
    ('act_lt_deduardo_ec_dp3_cn1_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_ec_dp3_cn1', 'camp_2627', 'ta_e_don_eduardo_cd_cn', 5, false, NULL),
    ('act_lt_deduardo_ec_dp3_cn1_camp_2627_1', 'e_don_eduardo', 'lt_deduardo_ec_dp3_cn1', 'camp_2627', 'ta_e_don_eduardo_cd_vi', 5, true, NULL),
    ('act_lt_deduardo_ec_dp3_cn1_camp_2728_0', 'e_don_eduardo', 'lt_deduardo_ec_dp3_cn1', 'camp_2728', 'ta_e_don_eduardo_cd_mzp', 5, false, NULL),
    ('act_lt_deduardo_ec_dp3_cn1_camp_2728_1', 'e_don_eduardo', 'lt_deduardo_ec_dp3_cn1', 'camp_2728', 'ta_e_don_eduardo_cd_pi', 5, true, NULL),
    ('act_lt_deduardo_ec_dp3_cn_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_ec_dp3_cn', 'camp_2223', 'ta_e_don_eduardo_cd_cnd', 66, false, NULL),
    ('act_lt_deduardo_ec_dp3_cn_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_ec_dp3_cn', 'camp_2324', 'ta_e_don_eduardo_cd_cnd', 66, false, NULL),
    ('act_lt_deduardo_ec_dp3_cn_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_ec_dp3_cn', 'camp_2425', 'ta_e_don_eduardo_cd_cnd', 66, false, NULL),
    ('act_lt_deduardo_ec_dp3_cn_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_ec_dp3_cn', 'camp_2526', 'ta_e_don_eduardo_cd_cnd', 61, false, NULL),
    ('act_lt_deduardo_ec_dp3_cn_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_ec_dp3_cn', 'camp_2627', 'ta_e_don_eduardo_cd_cnd', 61, false, NULL),
    ('act_lt_deduardo_em_18_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_em_18', 'camp_2223', 'ta_e_don_eduardo_cd_mz', 44, false, NULL),
    ('act_lt_deduardo_em_18_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_em_18', 'camp_2324', 'ta_e_don_eduardo_cd_sj1', 44, false, NULL),
    ('act_lt_deduardo_em_18_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_em_18', 'camp_2425', 'ta_e_don_eduardo_cd_mz', 44, false, NULL),
    ('act_lt_deduardo_em_18_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_em_18', 'camp_2526', 'ta_e_don_eduardo_cd_sj1', 44, false, NULL),
    ('act_lt_deduardo_em_18_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_em_18', 'camp_2627', 'ta_e_don_eduardo_cd_tr', 44, false, NULL),
    ('act_lt_deduardo_em_18_camp_2627_1', 'e_don_eduardo', 'lt_deduardo_em_18', 'camp_2627', 'ta_e_don_eduardo_cd_sj2', 44, true, NULL),
    ('act_lt_deduardo_em_18_camp_2728_0', 'e_don_eduardo', 'lt_deduardo_em_18', 'camp_2728', 'ta_e_don_eduardo_cd_mz', 44, false, NULL),
    ('act_lt_deduardo_em_19_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_em_19', 'camp_2223', 'ta_e_don_eduardo_cd_mz', 45, false, NULL),
    ('act_lt_deduardo_em_19_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_em_19', 'camp_2324', 'ta_e_don_eduardo_cd_sj1', 45, false, NULL),
    ('act_lt_deduardo_em_19_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_em_19', 'camp_2425', 'ta_e_don_eduardo_cd_tr', 45, false, NULL),
    ('act_lt_deduardo_em_19_camp_2425_1', 'e_don_eduardo', 'lt_deduardo_em_19', 'camp_2425', 'ta_e_don_eduardo_cd_sj2', 45, true, NULL),
    ('act_lt_deduardo_em_19_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_em_19', 'camp_2526', 'ta_e_don_eduardo_cd_mz', 45, false, NULL),
    ('act_lt_deduardo_em_19_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_em_19', 'camp_2627', 'ta_e_don_eduardo_cd_sj1', 45, false, NULL),
    ('act_lt_deduardo_em_19_camp_2728_0', 'e_don_eduardo', 'lt_deduardo_em_19', 'camp_2728', 'ta_e_don_eduardo_cd_tr', 45, false, NULL),
    ('act_lt_deduardo_em_19_camp_2728_1', 'e_don_eduardo', 'lt_deduardo_em_19', 'camp_2728', 'ta_e_don_eduardo_cd_sj2', 45, true, NULL),
    ('act_lt_deduardo_em_20_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_em_20', 'camp_2223', 'ta_e_don_eduardo_cd_tr', 38, false, NULL),
    ('act_lt_deduardo_em_20_camp_2223_1', 'e_don_eduardo', 'lt_deduardo_em_20', 'camp_2223', 'ta_e_don_eduardo_cd_sj2', 38, true, NULL),
    ('act_lt_deduardo_em_20_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_em_20', 'camp_2324', 'ta_e_don_eduardo_cd_mz', 38, false, NULL),
    ('act_lt_deduardo_em_20_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_em_20', 'camp_2425', 'ta_e_don_eduardo_cd_sj1', 38, false, NULL),
    ('act_lt_deduardo_em_20_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_em_20', 'camp_2526', 'ta_e_don_eduardo_cd_tr', 38, false, NULL),
    ('act_lt_deduardo_em_20_camp_2526_1', 'e_don_eduardo', 'lt_deduardo_em_20', 'camp_2526', 'ta_e_don_eduardo_cd_sj2', 38, true, NULL),
    ('act_lt_deduardo_em_20_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_em_20', 'camp_2627', 'ta_e_don_eduardo_cd_sj1', 38, false, NULL),
    ('act_lt_deduardo_em_20_camp_2728_0', 'e_don_eduardo', 'lt_deduardo_em_20', 'camp_2728', 'ta_e_don_eduardo_cd_tr', 38, false, NULL),
    ('act_lt_deduardo_em_20_camp_2728_1', 'e_don_eduardo', 'lt_deduardo_em_20', 'camp_2728', 'ta_e_don_eduardo_cd_sj2', 38, true, NULL),
    ('act_lt_deduardo_em_21_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_em_21', 'camp_2223', 'ta_e_don_eduardo_cd_sj1', 45, false, NULL),
    ('act_lt_deduardo_em_21_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_em_21', 'camp_2324', 'ta_e_don_eduardo_cd_tr', 45, false, NULL),
    ('act_lt_deduardo_em_21_camp_2324_1', 'e_don_eduardo', 'lt_deduardo_em_21', 'camp_2324', 'ta_e_don_eduardo_cd_sj2', 45, true, NULL),
    ('act_lt_deduardo_em_21_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_em_21', 'camp_2425', 'ta_e_don_eduardo_cd_mzspe', 45, false, NULL),
    ('act_lt_deduardo_em_21_camp_2425_1', 'e_don_eduardo', 'lt_deduardo_em_21', 'camp_2425', 'ta_e_don_eduardo_cd_vi', 45, true, NULL),
    ('act_lt_deduardo_em_21_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_em_21', 'camp_2526', 'ta_e_don_eduardo_cd_sj1', 45, false, NULL),
    ('act_lt_deduardo_em_21_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_em_21', 'camp_2627', 'ta_e_don_eduardo_cd_tr', 45, false, NULL),
    ('act_lt_deduardo_em_21_camp_2627_1', 'e_don_eduardo', 'lt_deduardo_em_21', 'camp_2627', 'ta_e_don_eduardo_cd_sj2', 45, true, NULL),
    ('act_lt_deduardo_em_21_camp_2728_0', 'e_don_eduardo', 'lt_deduardo_em_21', 'camp_2728', 'ta_e_don_eduardo_cd_mz', 45, false, NULL),
    ('act_lt_deduardo_em_50_51_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_em_50_51', 'camp_2223', 'ta_e_don_eduardo_cd_sj1', 95, false, NULL),
    ('act_lt_deduardo_em_50_51_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_em_50_51', 'camp_2324', 'ta_e_don_eduardo_cd_mz', 95, false, NULL),
    ('act_lt_deduardo_em_50_51_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_em_50_51', 'camp_2425', 'ta_e_don_eduardo_cd_sj1', 95, false, NULL),
    ('act_lt_deduardo_em_50_51_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_em_50_51', 'camp_2526', 'ta_e_don_eduardo_cd_tr', 95, false, NULL),
    ('act_lt_deduardo_em_50_51_camp_2526_1', 'e_don_eduardo', 'lt_deduardo_em_50_51', 'camp_2526', 'ta_e_don_eduardo_cd_sj2', 95, true, NULL),
    ('act_lt_deduardo_em_50_51_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_em_50_51', 'camp_2627', 'ta_e_don_eduardo_cd_mz', 95, false, NULL),
    ('act_lt_deduardo_em_50_51_camp_2728_0', 'e_don_eduardo', 'lt_deduardo_em_50_51', 'camp_2728', 'ta_e_don_eduardo_cd_sj1', 95, false, NULL),
    ('act_lt_deduardo_em_50_51_cn_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_em_50_51_cn', 'camp_2223', 'ta_e_don_eduardo_cd_cn', 14, false, NULL),
    ('act_lt_deduardo_em_50_51_cn_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_em_50_51_cn', 'camp_2324', 'ta_e_don_eduardo_cd_cn', 14, false, NULL),
    ('act_lt_deduardo_em_50_51_cn_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_em_50_51_cn', 'camp_2425', 'ta_e_don_eduardo_cd_cn', 14, false, NULL),
    ('act_lt_deduardo_em_50_51_cn_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_em_50_51_cn', 'camp_2526', 'ta_e_don_eduardo_cd_cn', 14, false, NULL),
    ('act_lt_deduardo_em_50_51_cn_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_em_50_51_cn', 'camp_2627', 'ta_e_don_eduardo_cd_cn', 14, false, NULL),
    ('act_lt_deduardo_em_52_cn_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_em_52_cn', 'camp_2223', 'ta_e_don_eduardo_cd_cn', 4, false, NULL),
    ('act_lt_deduardo_em_52_cn_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_em_52_cn', 'camp_2324', 'ta_e_don_eduardo_cd_cn', 4, false, NULL),
    ('act_lt_deduardo_em_52_cn_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_em_52_cn', 'camp_2425', 'ta_e_don_eduardo_cd_cn', 4, false, NULL),
    ('act_lt_deduardo_em_52_cn_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_em_52_cn', 'camp_2526', 'ta_e_don_eduardo_cd_cn', 4, false, NULL),
    ('act_lt_deduardo_em_52_cn_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_em_52_cn', 'camp_2627', 'ta_e_don_eduardo_cd_cn', 4, false, NULL),
    ('act_lt_deduardo_em_52_loma_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_em_52_loma', 'camp_2223', 'ta_e_don_eduardo_cd_ppfe', 22, false, NULL),
    ('act_lt_deduardo_em_52_loma_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_em_52_loma', 'camp_2324', 'ta_e_don_eduardo_cd_ppfe', 22, false, NULL),
    ('act_lt_deduardo_em_52_loma_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_em_52_loma', 'camp_2425', 'ta_e_don_eduardo_cd_g', 22, false, NULL),
    ('act_lt_deduardo_em_52_loma_camp_2425_1', 'e_don_eduardo', 'lt_deduardo_em_52_loma', 'camp_2425', 'ta_e_don_eduardo_cd_vi', 22, true, NULL),
    ('act_lt_deduardo_em_52_loma_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_em_52_loma', 'camp_2526', 'ta_e_don_eduardo_cd_sj1', 22, false, NULL),
    ('act_lt_deduardo_em_52_loma_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_em_52_loma', 'camp_2627', 'ta_e_don_eduardo_cd_g', 22, false, NULL),
    ('act_lt_deduardo_em_52_loma_camp_2627_1', 'e_don_eduardo', 'lt_deduardo_em_52_loma', 'camp_2627', 'ta_e_don_eduardo_cd_pi', 22, true, NULL),
    ('act_lt_deduardo_em_52_loma_camp_2728_0', 'e_don_eduardo', 'lt_deduardo_em_52_loma', 'camp_2728', 'ta_e_don_eduardo_cd_ppalf', 22, false, NULL),
    ('act_lt_deduardo_em_53_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_em_53', 'camp_2223', 'ta_e_don_eduardo_cd_ppfe', 28, false, NULL),
    ('act_lt_deduardo_em_53_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_em_53', 'camp_2324', 'ta_e_don_eduardo_cd_ppfe', 28, false, NULL),
    ('act_lt_deduardo_em_53_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_em_53', 'camp_2425', 'ta_e_don_eduardo_cd_g', 28, false, NULL),
    ('act_lt_deduardo_em_53_camp_2425_1', 'e_don_eduardo', 'lt_deduardo_em_53', 'camp_2425', 'ta_e_don_eduardo_cd_vi', 28, true, NULL),
    ('act_lt_deduardo_em_53_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_em_53', 'camp_2526', 'ta_e_don_eduardo_cd_sj1', 28, false, NULL),
    ('act_lt_deduardo_em_53_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_em_53', 'camp_2627', 'ta_e_don_eduardo_cd_g', 28, false, NULL),
    ('act_lt_deduardo_em_53_camp_2627_1', 'e_don_eduardo', 'lt_deduardo_em_53', 'camp_2627', 'ta_e_don_eduardo_cd_pi', 28, true, NULL),
    ('act_lt_deduardo_em_53_camp_2728_0', 'e_don_eduardo', 'lt_deduardo_em_53', 'camp_2728', 'ta_e_don_eduardo_cd_ppalf', 28, false, NULL),
    ('act_lt_deduardo_em_53_cn_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_em_53_cn', 'camp_2223', 'ta_e_don_eduardo_cd_cn', 10, false, NULL),
    ('act_lt_deduardo_em_53_cn_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_em_53_cn', 'camp_2324', 'ta_e_don_eduardo_cd_cn', 10, false, NULL),
    ('act_lt_deduardo_em_53_cn_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_em_53_cn', 'camp_2425', 'ta_e_don_eduardo_cd_cn', 10, false, NULL),
    ('act_lt_deduardo_em_53_cn_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_em_53_cn', 'camp_2526', 'ta_e_don_eduardo_cd_cn', 10, false, NULL),
    ('act_lt_deduardo_em_53_cn_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_em_53_cn', 'camp_2627', 'ta_e_don_eduardo_cd_cn', 10, false, NULL),
    ('act_lt_deduardo_em_54_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_em_54', 'camp_2223', 'ta_e_don_eduardo_cd_cnd', 126, false, NULL),
    ('act_lt_deduardo_em_54_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_em_54', 'camp_2324', 'ta_e_don_eduardo_cd_cnd', 126, false, NULL),
    ('act_lt_deduardo_em_54_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_em_54', 'camp_2425', 'ta_e_don_eduardo_cd_cnd', 126, false, NULL),
    ('act_lt_deduardo_em_54_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_em_54', 'camp_2526', 'ta_e_don_eduardo_cd_cnd', 126, false, NULL),
    ('act_lt_deduardo_em_54_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_em_54', 'camp_2627', 'ta_e_don_eduardo_cd_cnd', 126, false, NULL),
    ('act_lt_deduardo_em_56_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_em_56', 'camp_2223', 'ta_e_don_eduardo_cd_cnd', 67, false, NULL),
    ('act_lt_deduardo_em_56_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_em_56', 'camp_2324', 'ta_e_don_eduardo_cd_cnd', 67, false, NULL),
    ('act_lt_deduardo_em_56_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_em_56', 'camp_2425', 'ta_e_don_eduardo_cd_cnd', 67, false, NULL),
    ('act_lt_deduardo_em_56_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_em_56', 'camp_2526', 'ta_e_don_eduardo_cd_cnd', 67, false, NULL),
    ('act_lt_deduardo_em_56_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_em_56', 'camp_2627', 'ta_e_don_eduardo_cd_cnd', 67, false, NULL),
    ('act_lt_deduardo_em_57_bajo_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_em_57_bajo', 'camp_2223', 'ta_e_don_eduardo_cd_cn', 24, false, NULL),
    ('act_lt_deduardo_em_57_bajo_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_em_57_bajo', 'camp_2324', 'ta_e_don_eduardo_cd_cn', 24, false, NULL),
    ('act_lt_deduardo_em_57_bajo_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_em_57_bajo', 'camp_2425', 'ta_e_don_eduardo_cd_cn', 24, false, NULL),
    ('act_lt_deduardo_em_57_bajo_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_em_57_bajo', 'camp_2526', 'ta_e_don_eduardo_cd_cn', 24, false, NULL),
    ('act_lt_deduardo_em_57_bajo_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_em_57_bajo', 'camp_2627', 'ta_e_don_eduardo_cd_cn', 24, false, NULL),
    ('act_lt_deduardo_em_57_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_em_57', 'camp_2223', 'ta_e_don_eduardo_cd_mzp', 18, false, NULL),
    ('act_lt_deduardo_em_57_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_em_57', 'camp_2324', 'ta_e_don_eduardo_cd_mzp', 16, false, NULL),
    ('act_lt_deduardo_em_57_camp_2324_1', 'e_don_eduardo', 'lt_deduardo_em_57', 'camp_2324', 'ta_e_don_eduardo_cd_pi', 16, true, NULL),
    ('act_lt_deduardo_em_57_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_em_57', 'camp_2425', 'ta_e_don_eduardo_cd_ppfe', 16, false, NULL),
    ('act_lt_deduardo_em_57_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_em_57', 'camp_2526', 'ta_e_don_eduardo_cd_ppfe', 16, false, NULL),
    ('act_lt_deduardo_em_57_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_em_57', 'camp_2627', 'ta_e_don_eduardo_cd_ppfe', 16, false, NULL),
    ('act_lt_deduardo_em_58_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_em_58', 'camp_2223', 'ta_e_don_eduardo_cd_mzp', 7, false, NULL),
    ('act_lt_deduardo_em_58_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_em_58', 'camp_2324', 'ta_e_don_eduardo_cd_mzp', 7, false, NULL),
    ('act_lt_deduardo_em_58_camp_2324_1', 'e_don_eduardo', 'lt_deduardo_em_58', 'camp_2324', 'ta_e_don_eduardo_cd_pi', 7, true, NULL),
    ('act_lt_deduardo_em_58_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_em_58', 'camp_2425', 'ta_e_don_eduardo_cd_ppfe', 7, false, NULL),
    ('act_lt_deduardo_em_58_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_em_58', 'camp_2526', 'ta_e_don_eduardo_cd_ppfe', 7, false, NULL),
    ('act_lt_deduardo_em_58_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_em_58', 'camp_2627', 'ta_e_don_eduardo_cd_ppfe', 7, false, NULL),
    ('act_lt_deduardo_em_58_cn_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_em_58_cn', 'camp_2223', 'ta_e_don_eduardo_cd_cnd', 53, false, NULL),
    ('act_lt_deduardo_em_58_cn_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_em_58_cn', 'camp_2324', 'ta_e_don_eduardo_cd_cnd', 53, false, NULL),
    ('act_lt_deduardo_em_58_cn_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_em_58_cn', 'camp_2425', 'ta_e_don_eduardo_cd_cnd', 53, false, NULL),
    ('act_lt_deduardo_em_58_cn_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_em_58_cn', 'camp_2526', 'ta_e_don_eduardo_cd_cnd', 53, false, NULL),
    ('act_lt_deduardo_em_58_cn_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_em_58_cn', 'camp_2627', 'ta_e_don_eduardo_cd_cnd', 53, false, NULL),
    ('act_lt_deduardo_em_59_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_em_59', 'camp_2223', 'ta_e_don_eduardo_cd_mzp', 25, false, NULL),
    ('act_lt_deduardo_em_59_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_em_59', 'camp_2324', 'ta_e_don_eduardo_cd_g', 26, false, NULL),
    ('act_lt_deduardo_em_59_camp_2324_1', 'e_don_eduardo', 'lt_deduardo_em_59', 'camp_2324', 'ta_e_don_eduardo_cd_pi', 26, true, NULL),
    ('act_lt_deduardo_em_59_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_em_59', 'camp_2425', 'ta_e_don_eduardo_cd_ppfe', 26, false, NULL),
    ('act_lt_deduardo_em_59_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_em_59', 'camp_2526', 'ta_e_don_eduardo_cd_ppfe', 26, false, NULL),
    ('act_lt_deduardo_em_59_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_em_59', 'camp_2627', 'ta_e_don_eduardo_cd_ppfe', 26, false, NULL),
    ('act_lt_deduardo_em_59_cn_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_em_59_cn', 'camp_2223', 'ta_e_don_eduardo_cd_cn', 6, false, NULL),
    ('act_lt_deduardo_em_59_cn_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_em_59_cn', 'camp_2324', 'ta_e_don_eduardo_cd_cn', 6, false, NULL),
    ('act_lt_deduardo_em_59_cn_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_em_59_cn', 'camp_2425', 'ta_e_don_eduardo_cd_cn', 6, false, NULL),
    ('act_lt_deduardo_em_59_cn_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_em_59_cn', 'camp_2526', 'ta_e_don_eduardo_cd_cn', 6, false, NULL),
    ('act_lt_deduardo_em_59_cn_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_em_59_cn', 'camp_2627', 'ta_e_don_eduardo_cd_cn', 6, false, NULL),
    ('act_lt_deduardo_em_60_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_em_60', 'camp_2223', 'ta_e_don_eduardo_cd_ppfe', 25, false, NULL),
    ('act_lt_deduardo_em_60_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_em_60', 'camp_2324', 'ta_e_don_eduardo_cd_ppfe', 25, false, NULL),
    ('act_lt_deduardo_em_60_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_em_60', 'camp_2425', 'ta_e_don_eduardo_cd_g', 25, false, NULL),
    ('act_lt_deduardo_em_60_camp_2425_1', 'e_don_eduardo', 'lt_deduardo_em_60', 'camp_2425', 'ta_e_don_eduardo_cd_pi', 25, true, NULL),
    ('act_lt_deduardo_em_60_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_em_60', 'camp_2526', 'ta_e_don_eduardo_cd_ppalf', 25, false, NULL),
    ('act_lt_deduardo_em_60_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_em_60', 'camp_2627', 'ta_e_don_eduardo_cd_ppalf', 25, false, NULL),
    ('act_lt_deduardo_em_60_cn_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_em_60_cn', 'camp_2223', 'ta_e_don_eduardo_cd_cn', 11, false, NULL),
    ('act_lt_deduardo_em_60_cn_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_em_60_cn', 'camp_2324', 'ta_e_don_eduardo_cd_cn', 11, false, NULL),
    ('act_lt_deduardo_em_60_cn_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_em_60_cn', 'camp_2425', 'ta_e_don_eduardo_cd_cn', 11, false, NULL),
    ('act_lt_deduardo_em_60_cn_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_em_60_cn', 'camp_2526', 'ta_e_don_eduardo_cd_cn', 11, false, NULL),
    ('act_lt_deduardo_em_60_cn_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_em_60_cn', 'camp_2627', 'ta_e_don_eduardo_cd_cn', 11, false, NULL),
    ('act_lt_deduardo_em_61_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_em_61', 'camp_2223', 'ta_e_don_eduardo_cd_mzt', 28, false, NULL),
    ('act_lt_deduardo_em_61_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_em_61', 'camp_2324', 'ta_e_don_eduardo_cd_sj1', 28, false, NULL),
    ('act_lt_deduardo_em_61_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_em_61', 'camp_2425', 'ta_e_don_eduardo_cd_tr', 28, false, NULL),
    ('act_lt_deduardo_em_61_camp_2425_1', 'e_don_eduardo', 'lt_deduardo_em_61', 'camp_2425', 'ta_e_don_eduardo_cd_sj2', 28, true, NULL),
    ('act_lt_deduardo_em_61_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_em_61', 'camp_2526', 'ta_e_don_eduardo_cd_mzt', 28, false, NULL),
    ('act_lt_deduardo_em_61_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_em_61', 'camp_2627', 'ta_e_don_eduardo_cd_sj1', 28, false, NULL),
    ('act_lt_deduardo_em_61_camp_2728_0', 'e_don_eduardo', 'lt_deduardo_em_61', 'camp_2728', 'ta_e_don_eduardo_cd_tr', 28, false, NULL),
    ('act_lt_deduardo_em_61_camp_2728_1', 'e_don_eduardo', 'lt_deduardo_em_61', 'camp_2728', 'ta_e_don_eduardo_cd_sj2', 28, true, NULL),
    ('act_lt_deduardo_em_62_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_em_62', 'camp_2223', 'ta_e_don_eduardo_cd_ppfe', 39, false, NULL),
    ('act_lt_deduardo_em_62_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_em_62', 'camp_2324', 'ta_e_don_eduardo_cd_ppfe', 39, false, NULL),
    ('act_lt_deduardo_em_62_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_em_62', 'camp_2425', 'ta_e_don_eduardo_cd_ppfe', 39, false, NULL),
    ('act_lt_deduardo_em_62_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_em_62', 'camp_2526', 'ta_e_don_eduardo_cd_ppfe', 39, false, NULL),
    ('act_lt_deduardo_em_62_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_em_62', 'camp_2627', 'ta_e_don_eduardo_cd_g', 39, false, NULL),
    ('act_lt_deduardo_em_62_camp_2627_1', 'e_don_eduardo', 'lt_deduardo_em_62', 'camp_2627', 'ta_e_don_eduardo_cd_vi', 39, true, NULL),
    ('act_lt_deduardo_em_62_camp_2728_0', 'e_don_eduardo', 'lt_deduardo_em_62', 'camp_2728', 'ta_e_don_eduardo_cd_mzt', 39, false, NULL),
    ('act_lt_deduardo_em_62_cn_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_em_62_cn', 'camp_2223', 'ta_e_don_eduardo_cd_cn', 8, false, NULL),
    ('act_lt_deduardo_em_62_cn_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_em_62_cn', 'camp_2324', 'ta_e_don_eduardo_cd_cn', 8, false, NULL),
    ('act_lt_deduardo_em_62_cn_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_em_62_cn', 'camp_2425', 'ta_e_don_eduardo_cd_cn', 8, false, NULL),
    ('act_lt_deduardo_em_62_cn_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_em_62_cn', 'camp_2526', 'ta_e_don_eduardo_cd_cn', 8, false, NULL),
    ('act_lt_deduardo_em_62_cn_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_em_62_cn', 'camp_2627', 'ta_e_don_eduardo_cd_cn', 8, false, NULL),
    ('act_lt_deduardo_em_63_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_em_63', 'camp_2223', 'ta_e_don_eduardo_cd_tr', 45, false, NULL),
    ('act_lt_deduardo_em_63_camp_2223_1', 'e_don_eduardo', 'lt_deduardo_em_63', 'camp_2223', 'ta_e_don_eduardo_cd_sj2', 45, true, NULL),
    ('act_lt_deduardo_em_63_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_em_63', 'camp_2324', 'ta_e_don_eduardo_cd_g', 43, false, NULL),
    ('act_lt_deduardo_em_63_camp_2324_1', 'e_don_eduardo', 'lt_deduardo_em_63', 'camp_2324', 'ta_e_don_eduardo_cd_pi', 43, true, NULL),
    ('act_lt_deduardo_em_63_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_em_63', 'camp_2425', 'ta_e_don_eduardo_cd_ppalf', 43, false, NULL),
    ('act_lt_deduardo_em_63_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_em_63', 'camp_2526', 'ta_e_don_eduardo_cd_ppalf', 43, false, NULL),
    ('act_lt_deduardo_em_63_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_em_63', 'camp_2627', 'ta_e_don_eduardo_cd_ppalf', 43, false, NULL),
    ('act_lt_deduardo_em_64_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_em_64', 'camp_2223', 'ta_e_don_eduardo_cd_mzt', 42, false, NULL),
    ('act_lt_deduardo_em_64_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_em_64', 'camp_2324', 'ta_e_don_eduardo_cd_sj1', 43, false, NULL),
    ('act_lt_deduardo_em_64_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_em_64', 'camp_2425', 'ta_e_don_eduardo_cd_tr', 43, false, NULL),
    ('act_lt_deduardo_em_64_camp_2425_1', 'e_don_eduardo', 'lt_deduardo_em_64', 'camp_2425', 'ta_e_don_eduardo_cd_sj2', 43, true, NULL),
    ('act_lt_deduardo_em_64_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_em_64', 'camp_2526', 'ta_e_don_eduardo_cd_mzt', 43, false, NULL),
    ('act_lt_deduardo_em_64_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_em_64', 'camp_2627', 'ta_e_don_eduardo_cd_sj1', 43, false, NULL),
    ('act_lt_deduardo_em_64_camp_2728_0', 'e_don_eduardo', 'lt_deduardo_em_64', 'camp_2728', 'ta_e_don_eduardo_cd_tr', 43, false, NULL),
    ('act_lt_deduardo_em_64_camp_2728_1', 'e_don_eduardo', 'lt_deduardo_em_64', 'camp_2728', 'ta_e_don_eduardo_cd_sj2', 43, true, NULL),
    ('act_lt_deduardo_em_64_cn_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_em_64_cn', 'camp_2223', 'ta_e_don_eduardo_cd_cnd', 8, false, NULL),
    ('act_lt_deduardo_em_64_cn_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_em_64_cn', 'camp_2324', 'ta_e_don_eduardo_cd_cnd', 8, false, NULL),
    ('act_lt_deduardo_em_64_cn_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_em_64_cn', 'camp_2425', 'ta_e_don_eduardo_cd_cnd', 8, false, NULL),
    ('act_lt_deduardo_em_64_cn_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_em_64_cn', 'camp_2526', 'ta_e_don_eduardo_cd_cnd', 8, false, NULL),
    ('act_lt_deduardo_em_64_cn_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_em_64_cn', 'camp_2627', 'ta_e_don_eduardo_cd_cnd', 8, false, NULL),
    ('act_lt_deduardo_em_65_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_em_65', 'camp_2223', 'ta_e_don_eduardo_cd_ppfe', 12, false, NULL),
    ('act_lt_deduardo_em_65_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_em_65', 'camp_2324', 'ta_e_don_eduardo_cd_ppfe', 12, false, NULL),
    ('act_lt_deduardo_em_65_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_em_65', 'camp_2425', 'ta_e_don_eduardo_cd_ppfe', 12, false, NULL),
    ('act_lt_deduardo_em_65_camp_2425_1', 'e_don_eduardo', 'lt_deduardo_em_65', 'camp_2425', 'ta_e_don_eduardo_cd_vi', 12, true, NULL),
    ('act_lt_deduardo_em_65_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_em_65', 'camp_2526', 'ta_e_don_eduardo_cd_g', 12, false, NULL),
    ('act_lt_deduardo_em_65_camp_2526_1', 'e_don_eduardo', 'lt_deduardo_em_65', 'camp_2526', 'ta_e_don_eduardo_cd_pi', 12, true, NULL),
    ('act_lt_deduardo_em_65_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_em_65', 'camp_2627', 'ta_e_don_eduardo_cd_ppalf', 12, false, NULL),
    ('act_lt_deduardo_em_65_cn1_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_em_65_cn1', 'camp_2526', 'ta_e_don_eduardo_cd_cn', 10, false, NULL),
    ('act_lt_deduardo_em_65_cn1_camp_2526_1', 'e_don_eduardo', 'lt_deduardo_em_65_cn1', 'camp_2526', 'ta_e_don_eduardo_cd_vi', 10, true, NULL),
    ('act_lt_deduardo_em_65_cn1_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_em_65_cn1', 'camp_2627', 'ta_e_don_eduardo_cd_g', 10, false, NULL),
    ('act_lt_deduardo_em_65_cn1_camp_2627_1', 'e_don_eduardo', 'lt_deduardo_em_65_cn1', 'camp_2627', 'ta_e_don_eduardo_cd_vi', 10, true, NULL),
    ('act_lt_deduardo_em_65_cn1_camp_2728_0', 'e_don_eduardo', 'lt_deduardo_em_65_cn1', 'camp_2728', 'ta_e_don_eduardo_cd_mzp', 10, false, NULL),
    ('act_lt_deduardo_em_65_cn1_camp_2728_1', 'e_don_eduardo', 'lt_deduardo_em_65_cn1', 'camp_2728', 'ta_e_don_eduardo_cd_pi', 10, true, NULL),
    ('act_lt_deduardo_em_65_cn_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_em_65_cn', 'camp_2223', 'ta_e_don_eduardo_cd_cn', 43, false, NULL),
    ('act_lt_deduardo_em_65_cn_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_em_65_cn', 'camp_2324', 'ta_e_don_eduardo_cd_cn', 43, false, NULL),
    ('act_lt_deduardo_em_65_cn_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_em_65_cn', 'camp_2425', 'ta_e_don_eduardo_cd_cn', 43, false, NULL),
    ('act_lt_deduardo_em_65_cn_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_em_65_cn', 'camp_2526', 'ta_e_don_eduardo_cd_cn', 33, false, NULL),
    ('act_lt_deduardo_em_65_cn_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_em_65_cn', 'camp_2627', 'ta_e_don_eduardo_cd_cn', 33, false, NULL),
    ('act_lt_deduardo_em_66_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_em_66', 'camp_2223', 'ta_e_don_eduardo_cd_mz', 50, false, NULL),
    ('act_lt_deduardo_em_66_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_em_66', 'camp_2324', 'ta_e_don_eduardo_cd_sj1', 50, false, NULL),
    ('act_lt_deduardo_em_66_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_em_66', 'camp_2425', 'ta_e_don_eduardo_cd_mz', 36, false, NULL),
    ('act_lt_deduardo_em_66_camp_2425_1', 'e_don_eduardo', 'lt_deduardo_em_66', 'camp_2425', 'ta_e_don_eduardo_cd_mzspe', 14, false, NULL),
    ('act_lt_deduardo_em_66_camp_2425_2', 'e_don_eduardo', 'lt_deduardo_em_66', 'camp_2425', 'ta_e_don_eduardo_cd_vi', 14, true, NULL),
    ('act_lt_deduardo_em_66_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_em_66', 'camp_2526', 'ta_e_don_eduardo_cd_sj1', 36, false, NULL),
    ('act_lt_deduardo_em_66_camp_2526_1', 'e_don_eduardo', 'lt_deduardo_em_66', 'camp_2526', 'ta_e_don_eduardo_cd_sj1', 14, false, NULL),
    ('act_lt_deduardo_em_66_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_em_66', 'camp_2627', 'ta_e_don_eduardo_cd_tr', 36, false, NULL),
    ('act_lt_deduardo_em_66_camp_2627_1', 'e_don_eduardo', 'lt_deduardo_em_66', 'camp_2627', 'ta_e_don_eduardo_cd_sj2', 36, true, NULL),
    ('act_lt_deduardo_em_66_camp_2627_2', 'e_don_eduardo', 'lt_deduardo_em_66', 'camp_2627', 'ta_e_don_eduardo_cd_tr', 14, false, NULL),
    ('act_lt_deduardo_em_66_camp_2627_3', 'e_don_eduardo', 'lt_deduardo_em_66', 'camp_2627', 'ta_e_don_eduardo_cd_sj2', 14, true, NULL),
    ('act_lt_deduardo_em_66_camp_2728_0', 'e_don_eduardo', 'lt_deduardo_em_66', 'camp_2728', 'ta_e_don_eduardo_cd_mz', 36, false, NULL),
    ('act_lt_deduardo_em_66_camp_2728_1', 'e_don_eduardo', 'lt_deduardo_em_66', 'camp_2728', 'ta_e_don_eduardo_cd_mz', 14, false, NULL),
    ('act_lt_deduardo_em_66_cn_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_em_66_cn', 'camp_2223', 'ta_e_don_eduardo_cd_cnd', 3, false, NULL),
    ('act_lt_deduardo_em_66_cn_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_em_66_cn', 'camp_2324', 'ta_e_don_eduardo_cd_cnd', 3, false, NULL),
    ('act_lt_deduardo_em_66_cn_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_em_66_cn', 'camp_2425', 'ta_e_don_eduardo_cd_cnd', 3, false, NULL),
    ('act_lt_deduardo_em_66_cn_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_em_66_cn', 'camp_2526', 'ta_e_don_eduardo_cd_cnd', 3, false, NULL),
    ('act_lt_deduardo_em_66_cn_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_em_66_cn', 'camp_2627', 'ta_e_don_eduardo_cd_cnd', 3, false, NULL),
    ('act_lt_deduardo_em_67_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_em_67', 'camp_2223', 'ta_e_don_eduardo_cd_ppfe', 12, false, NULL),
    ('act_lt_deduardo_em_67_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_em_67', 'camp_2324', 'ta_e_don_eduardo_cd_ppfe', 12, false, NULL),
    ('act_lt_deduardo_em_67_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_em_67', 'camp_2425', 'ta_e_don_eduardo_cd_ppfe', 12, false, NULL),
    ('act_lt_deduardo_em_67_camp_2425_1', 'e_don_eduardo', 'lt_deduardo_em_67', 'camp_2425', 'ta_e_don_eduardo_cd_vi', 12, true, NULL),
    ('act_lt_deduardo_em_67_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_em_67', 'camp_2526', 'ta_e_don_eduardo_cd_g', 12, false, NULL),
    ('act_lt_deduardo_em_67_camp_2526_1', 'e_don_eduardo', 'lt_deduardo_em_67', 'camp_2526', 'ta_e_don_eduardo_cd_pi', 12, true, NULL),
    ('act_lt_deduardo_em_67_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_em_67', 'camp_2627', 'ta_e_don_eduardo_cd_ppalf', 12, false, NULL),
    ('act_lt_deduardo_em_67_cn_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_em_67_cn', 'camp_2223', 'ta_e_don_eduardo_cd_cnd', 7, false, NULL),
    ('act_lt_deduardo_em_67_cn_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_em_67_cn', 'camp_2324', 'ta_e_don_eduardo_cd_cnd', 7, false, NULL),
    ('act_lt_deduardo_em_67_cn_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_em_67_cn', 'camp_2425', 'ta_e_don_eduardo_cd_cnd', 7, false, NULL),
    ('act_lt_deduardo_em_67_cn_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_em_67_cn', 'camp_2526', 'ta_e_don_eduardo_cd_cnd', 7, false, NULL),
    ('act_lt_deduardo_em_67_cn_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_em_67_cn', 'camp_2627', 'ta_e_don_eduardo_cd_cnd', 7, false, NULL),
    ('act_lt_deduardo_em_68_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_em_68', 'camp_2223', 'ta_e_don_eduardo_cd_cn', 25, false, NULL),
    ('act_lt_deduardo_em_68_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_em_68', 'camp_2324', 'ta_e_don_eduardo_cd_cn', 25, false, NULL),
    ('act_lt_deduardo_em_68_camp_2324_1', 'e_don_eduardo', 'lt_deduardo_em_68', 'camp_2324', 'ta_e_don_eduardo_cd_vi', 25, true, NULL),
    ('act_lt_deduardo_em_68_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_em_68', 'camp_2425', 'ta_e_don_eduardo_cd_mzd', 25, false, NULL),
    ('act_lt_deduardo_em_68_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_em_68', 'camp_2526', 'ta_e_don_eduardo_cd_cn', 25, false, NULL),
    ('act_lt_deduardo_em_68_camp_2526_1', 'e_don_eduardo', 'lt_deduardo_em_68', 'camp_2526', 'ta_e_don_eduardo_cd_vi', 25, true, NULL),
    ('act_lt_deduardo_em_68_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_em_68', 'camp_2627', 'ta_e_don_eduardo_cd_g', 25, false, NULL),
    ('act_lt_deduardo_em_68_camp_2627_1', 'e_don_eduardo', 'lt_deduardo_em_68', 'camp_2627', 'ta_e_don_eduardo_cd_pi', 25, true, NULL),
    ('act_lt_deduardo_em_68_camp_2728_0', 'e_don_eduardo', 'lt_deduardo_em_68', 'camp_2728', 'ta_e_don_eduardo_cd_ppfe', 25, false, NULL),
    ('act_lt_deduardo_em_69_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_em_69', 'camp_2223', 'ta_e_don_eduardo_cd_cn', 16, false, NULL),
    ('act_lt_deduardo_em_69_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_em_69', 'camp_2324', 'ta_e_don_eduardo_cd_cn', 16, false, NULL),
    ('act_lt_deduardo_em_69_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_em_69', 'camp_2425', 'ta_e_don_eduardo_cd_cn', 16, false, NULL),
    ('act_lt_deduardo_em_69_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_em_69', 'camp_2526', 'ta_e_don_eduardo_cd_cn', 16, false, NULL),
    ('act_lt_deduardo_em_69_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_em_69', 'camp_2627', 'ta_e_don_eduardo_cd_cn', 16, false, NULL),
    ('act_lt_deduardo_em_69_cn_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_em_69_cn', 'camp_2223', 'ta_e_don_eduardo_cd_cnd', 9, false, NULL),
    ('act_lt_deduardo_em_69_cn_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_em_69_cn', 'camp_2324', 'ta_e_don_eduardo_cd_cnd', 9, false, NULL),
    ('act_lt_deduardo_em_69_cn_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_em_69_cn', 'camp_2425', 'ta_e_don_eduardo_cd_cnd', 9, false, NULL),
    ('act_lt_deduardo_em_69_cn_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_em_69_cn', 'camp_2526', 'ta_e_don_eduardo_cd_cnd', 9, false, NULL),
    ('act_lt_deduardo_em_69_cn_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_em_69_cn', 'camp_2627', 'ta_e_don_eduardo_cd_cnd', 9, false, NULL),
    ('act_lt_deduardo_em_69_laguna_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_em_69_laguna', 'camp_2223', 'ta_e_don_eduardo_cd_cn', 18, false, NULL),
    ('act_lt_deduardo_em_69_laguna_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_em_69_laguna', 'camp_2324', 'ta_e_don_eduardo_cd_cn', 18, false, NULL),
    ('act_lt_deduardo_em_69_laguna_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_em_69_laguna', 'camp_2425', 'ta_e_don_eduardo_cd_cn', 18, false, NULL),
    ('act_lt_deduardo_em_69_laguna_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_em_69_laguna', 'camp_2526', 'ta_e_don_eduardo_cd_cn', 18, false, NULL),
    ('act_lt_deduardo_em_69_laguna_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_em_69_laguna', 'camp_2627', 'ta_e_don_eduardo_cd_cn', 18, false, NULL),
    ('act_lt_deduardo_em_70_73_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_em_70_73', 'camp_2223', 'ta_e_don_eduardo_cd_sj1', 56, false, NULL),
    ('act_lt_deduardo_em_70_73_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_em_70_73', 'camp_2324', 'ta_e_don_eduardo_cd_mz', 56, false, NULL),
    ('act_lt_deduardo_em_70_73_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_em_70_73', 'camp_2425', 'ta_e_don_eduardo_cd_sj1', 56, false, NULL),
    ('act_lt_deduardo_em_70_73_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_em_70_73', 'camp_2526', 'ta_e_don_eduardo_cd_tr', 56, false, NULL),
    ('act_lt_deduardo_em_70_73_camp_2526_1', 'e_don_eduardo', 'lt_deduardo_em_70_73', 'camp_2526', 'ta_e_don_eduardo_cd_sj2', 56, true, NULL),
    ('act_lt_deduardo_em_70_73_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_em_70_73', 'camp_2627', 'ta_e_don_eduardo_cd_mz', 56, false, NULL),
    ('act_lt_deduardo_em_70_73_camp_2728_0', 'e_don_eduardo', 'lt_deduardo_em_70_73', 'camp_2728', 'ta_e_don_eduardo_cd_sj1', 56, false, NULL),
    ('act_lt_deduardo_em_70_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_em_70', 'camp_2223', 'ta_e_don_eduardo_cd_cn', 59, false, NULL),
    ('act_lt_deduardo_em_70_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_em_70', 'camp_2324', 'ta_e_don_eduardo_cd_cn', 59, false, NULL),
    ('act_lt_deduardo_em_70_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_em_70', 'camp_2425', 'ta_e_don_eduardo_cd_cn', 59, false, NULL),
    ('act_lt_deduardo_em_70_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_em_70', 'camp_2526', 'ta_e_don_eduardo_cd_cn', 59, false, NULL),
    ('act_lt_deduardo_em_70_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_em_70', 'camp_2627', 'ta_e_don_eduardo_cd_cn', 59, false, NULL),
    ('act_lt_deduardo_em_72_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_em_72', 'camp_2223', 'ta_e_don_eduardo_cd_cn', 57, false, NULL),
    ('act_lt_deduardo_em_72_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_em_72', 'camp_2324', 'ta_e_don_eduardo_cd_cn', 57, false, NULL),
    ('act_lt_deduardo_em_72_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_em_72', 'camp_2425', 'ta_e_don_eduardo_cd_cn', 57, false, NULL),
    ('act_lt_deduardo_em_72_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_em_72', 'camp_2526', 'ta_e_don_eduardo_cd_cn', 50, false, NULL),
    ('act_lt_deduardo_em_72_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_em_72', 'camp_2627', 'ta_e_don_eduardo_cd_cn', 50, false, NULL),
    ('act_lt_deduardo_em_72_cn1_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_em_72_cn1', 'camp_2526', 'ta_e_don_eduardo_cd_cn', 7, false, NULL),
    ('act_lt_deduardo_em_72_cn1_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_em_72_cn1', 'camp_2627', 'ta_e_don_eduardo_cd_cn', 7, false, NULL),
    ('act_lt_deduardo_em_72_laguna_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_em_72_laguna', 'camp_2223', 'ta_e_don_eduardo_cd_cn', 36, false, NULL),
    ('act_lt_deduardo_em_72_laguna_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_em_72_laguna', 'camp_2324', 'ta_e_don_eduardo_cd_cn', 36, false, NULL),
    ('act_lt_deduardo_em_72_laguna_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_em_72_laguna', 'camp_2425', 'ta_e_don_eduardo_cd_cn', 36, false, NULL),
    ('act_lt_deduardo_em_72_laguna_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_em_72_laguna', 'camp_2526', 'ta_e_don_eduardo_cd_cn', 36, false, NULL),
    ('act_lt_deduardo_em_72_laguna_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_em_72_laguna', 'camp_2627', 'ta_e_don_eduardo_cd_cn', 36, false, NULL),
    ('act_lt_deduardo_em_73_cn_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_em_73_cn', 'camp_2223', 'ta_e_don_eduardo_cd_cn', 5, false, NULL),
    ('act_lt_deduardo_em_73_cn_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_em_73_cn', 'camp_2324', 'ta_e_don_eduardo_cd_cn', 5, false, NULL),
    ('act_lt_deduardo_em_73_cn_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_em_73_cn', 'camp_2425', 'ta_e_don_eduardo_cd_cn', 5, false, NULL),
    ('act_lt_deduardo_em_73_cn_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_em_73_cn', 'camp_2526', 'ta_e_don_eduardo_cd_ppalf', 5, false, NULL),
    ('act_lt_deduardo_em_73_cn_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_em_73_cn', 'camp_2627', 'ta_e_don_eduardo_cd_ppalf', 5, false, NULL),
    ('act_lt_deduardo_em_73_laguna_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_em_73_laguna', 'camp_2223', 'ta_e_don_eduardo_cd_cn', 25, false, NULL),
    ('act_lt_deduardo_em_73_laguna_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_em_73_laguna', 'camp_2324', 'ta_e_don_eduardo_cd_cn', 25, false, NULL),
    ('act_lt_deduardo_em_73_laguna_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_em_73_laguna', 'camp_2425', 'ta_e_don_eduardo_cd_cn', 25, false, NULL),
    ('act_lt_deduardo_em_73_laguna_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_em_73_laguna', 'camp_2526', 'ta_e_don_eduardo_cd_cn', 25, false, NULL),
    ('act_lt_deduardo_em_73_laguna_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_em_73_laguna', 'camp_2627', 'ta_e_don_eduardo_cd_cn', 25, false, NULL),
    ('act_lt_deduardo_em_73a_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_em_73a', 'camp_2223', 'ta_e_don_eduardo_cd_ppfe', 20, false, NULL),
    ('act_lt_deduardo_em_73a_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_em_73a', 'camp_2324', 'ta_e_don_eduardo_cd_ppfe', 20, false, NULL),
    ('act_lt_deduardo_em_73a_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_em_73a', 'camp_2425', 'ta_e_don_eduardo_cd_g', 20, false, NULL),
    ('act_lt_deduardo_em_73a_camp_2425_1', 'e_don_eduardo', 'lt_deduardo_em_73a', 'camp_2425', 'ta_e_don_eduardo_cd_pi', 20, true, NULL),
    ('act_lt_deduardo_em_73a_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_em_73a', 'camp_2526', 'ta_e_don_eduardo_cd_ppalf', 20, false, NULL),
    ('act_lt_deduardo_em_73a_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_em_73a', 'camp_2627', 'ta_e_don_eduardo_cd_ppalf', 20, false, NULL),
    ('act_lt_deduardo_lm_10_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_lm_10', 'camp_2223', 'ta_e_don_eduardo_cd_mz', 10, false, NULL),
    ('act_lt_deduardo_lm_10_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_lm_10', 'camp_2324', 'ta_e_don_eduardo_cd_g', 10, false, NULL),
    ('act_lt_deduardo_lm_10_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_lm_10', 'camp_2425', 'ta_e_don_eduardo_cd_av', 10, false, NULL),
    ('act_lt_deduardo_lm_10_camp_2425_1', 'e_don_eduardo', 'lt_deduardo_lm_10', 'camp_2425', 'ta_e_don_eduardo_cd_mz2', 10, true, NULL),
    ('act_lt_deduardo_lm_10_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_lm_10', 'camp_2526', 'ta_e_don_eduardo_cd_g', 10, false, NULL),
    ('act_lt_deduardo_lm_10_camp_2526_1', 'e_don_eduardo', 'lt_deduardo_lm_10', 'camp_2526', 'ta_e_don_eduardo_cd_pi', 10, true, NULL),
    ('act_lt_deduardo_lm_10_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_lm_10', 'camp_2627', 'ta_e_don_eduardo_cd_ppalf', 10, false, NULL),
    ('act_lt_deduardo_lm_1_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_lm_1', 'camp_2223', 'ta_e_don_eduardo_cd_g', 62, false, NULL),
    ('act_lt_deduardo_lm_1_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_lm_1', 'camp_2324', 'ta_e_don_eduardo_cd_sj1', 62, false, NULL),
    ('act_lt_deduardo_lm_1_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_lm_1', 'camp_2425', 'ta_e_don_eduardo_cd_tr', 62, false, NULL),
    ('act_lt_deduardo_lm_1_camp_2425_1', 'e_don_eduardo', 'lt_deduardo_lm_1', 'camp_2425', 'ta_e_don_eduardo_cd_sj2', 62, true, NULL),
    ('act_lt_deduardo_lm_1_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_lm_1', 'camp_2526', 'ta_e_don_eduardo_cd_mzt', 62, false, NULL),
    ('act_lt_deduardo_lm_1_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_lm_1', 'camp_2627', 'ta_e_don_eduardo_cd_sj1', 62, false, NULL),
    ('act_lt_deduardo_lm_1_camp_2728_0', 'e_don_eduardo', 'lt_deduardo_lm_1', 'camp_2728', 'ta_e_don_eduardo_cd_tr', 62, false, NULL),
    ('act_lt_deduardo_lm_1_camp_2728_1', 'e_don_eduardo', 'lt_deduardo_lm_1', 'camp_2728', 'ta_e_don_eduardo_cd_sj2', 62, true, NULL),
    ('act_lt_deduardo_lm_1_cn_n_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_lm_1_cn_n', 'camp_2223', 'ta_e_don_eduardo_cd_cn', 15.3, false, NULL),
    ('act_lt_deduardo_lm_1_cn_n_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_lm_1_cn_n', 'camp_2324', 'ta_e_don_eduardo_cd_cn', 15.3, false, NULL),
    ('act_lt_deduardo_lm_1_cn_n_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_lm_1_cn_n', 'camp_2425', 'ta_e_don_eduardo_cd_cn', 15.3, false, NULL),
    ('act_lt_deduardo_lm_1_cn_n_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_lm_1_cn_n', 'camp_2526', 'ta_e_don_eduardo_cd_cn', 15.3, false, NULL),
    ('act_lt_deduardo_lm_1_cn_n_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_lm_1_cn_n', 'camp_2627', 'ta_e_don_eduardo_cd_cn', 15.3, false, NULL),
    ('act_lt_deduardo_lm_1_cni_s_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_lm_1_cni_s', 'camp_2223', 'ta_e_don_eduardo_cd_cnd', 5.8, false, NULL),
    ('act_lt_deduardo_lm_1_cni_s_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_lm_1_cni_s', 'camp_2324', 'ta_e_don_eduardo_cd_cnd', 5.8, false, NULL),
    ('act_lt_deduardo_lm_1_cni_s_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_lm_1_cni_s', 'camp_2425', 'ta_e_don_eduardo_cd_cnd', 5.8, false, NULL),
    ('act_lt_deduardo_lm_1_cni_s_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_lm_1_cni_s', 'camp_2526', 'ta_e_don_eduardo_cd_cnd', 5.8, false, NULL),
    ('act_lt_deduardo_lm_1_cni_s_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_lm_1_cni_s', 'camp_2627', 'ta_e_don_eduardo_cd_cnd', 5.8, false, NULL),
    ('act_lt_deduardo_lm_2_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_lm_2', 'camp_2223', 'ta_e_don_eduardo_cd_sj1', 32, false, NULL),
    ('act_lt_deduardo_lm_2_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_lm_2', 'camp_2324', 'ta_e_don_eduardo_cd_sj1', 35, false, NULL),
    ('act_lt_deduardo_lm_2_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_lm_2', 'camp_2425', 'ta_e_don_eduardo_cd_tr', 35, false, NULL),
    ('act_lt_deduardo_lm_2_camp_2425_1', 'e_don_eduardo', 'lt_deduardo_lm_2', 'camp_2425', 'ta_e_don_eduardo_cd_sj2', 35, true, NULL),
    ('act_lt_deduardo_lm_2_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_lm_2', 'camp_2526', 'ta_e_don_eduardo_cd_mzt', 35, false, NULL),
    ('act_lt_deduardo_lm_2_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_lm_2', 'camp_2627', 'ta_e_don_eduardo_cd_sj1', 35, false, NULL),
    ('act_lt_deduardo_lm_2_camp_2728_0', 'e_don_eduardo', 'lt_deduardo_lm_2', 'camp_2728', 'ta_e_don_eduardo_cd_tr', 35, false, NULL),
    ('act_lt_deduardo_lm_2_camp_2728_1', 'e_don_eduardo', 'lt_deduardo_lm_2', 'camp_2728', 'ta_e_don_eduardo_cd_sj2', 35, true, NULL),
    ('act_lt_deduardo_lm_2_cn_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_lm_2_cn', 'camp_2223', 'ta_e_don_eduardo_cd_cn', 31.3, false, NULL),
    ('act_lt_deduardo_lm_2_cn_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_lm_2_cn', 'camp_2324', 'ta_e_don_eduardo_cd_cn', 31.3, false, NULL),
    ('act_lt_deduardo_lm_2_cn_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_lm_2_cn', 'camp_2425', 'ta_e_don_eduardo_cd_cn', 31.3, false, NULL),
    ('act_lt_deduardo_lm_2_cn_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_lm_2_cn', 'camp_2526', 'ta_e_don_eduardo_cd_cn', 31.3, false, NULL),
    ('act_lt_deduardo_lm_2_cn_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_lm_2_cn', 'camp_2627', 'ta_e_don_eduardo_cd_cn', 31.3, false, NULL),
    ('act_lt_deduardo_lm_2_cn_camp_2627_1', 'e_don_eduardo', 'lt_deduardo_lm_2_cn', 'camp_2627', 'ta_e_don_eduardo_cd_vi', 31.3, true, NULL),
    ('act_lt_deduardo_lm_2_cni_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_lm_2_cni', 'camp_2223', 'ta_e_don_eduardo_cd_cnd', 14.8, false, NULL),
    ('act_lt_deduardo_lm_2_cni_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_lm_2_cni', 'camp_2324', 'ta_e_don_eduardo_cd_cnd', 14.8, false, NULL),
    ('act_lt_deduardo_lm_2_cni_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_lm_2_cni', 'camp_2425', 'ta_e_don_eduardo_cd_cnd', 14.8, false, NULL),
    ('act_lt_deduardo_lm_2_cni_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_lm_2_cni', 'camp_2526', 'ta_e_don_eduardo_cd_cnd', 14.8, false, NULL),
    ('act_lt_deduardo_lm_2_cni_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_lm_2_cni', 'camp_2627', 'ta_e_don_eduardo_cd_cnd', 14.8, false, NULL),
    ('act_lt_deduardo_lm_3_4_agropiro_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_lm_3_4_agropiro', 'camp_2223', 'ta_e_don_eduardo_cd_ppag', 14.8, false, NULL),
    ('act_lt_deduardo_lm_3_4_agropiro_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_lm_3_4_agropiro', 'camp_2324', 'ta_e_don_eduardo_cd_ppag', 14.8, false, NULL),
    ('act_lt_deduardo_lm_3_4_agropiro_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_lm_3_4_agropiro', 'camp_2425', 'ta_e_don_eduardo_cd_ppag', 14.8, false, NULL),
    ('act_lt_deduardo_lm_3_4_agropiro_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_lm_3_4_agropiro', 'camp_2526', 'ta_e_don_eduardo_cd_ppag', 14.8, false, NULL),
    ('act_lt_deduardo_lm_3_4_agropiro_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_lm_3_4_agropiro', 'camp_2627', 'ta_e_don_eduardo_cd_ppag', 14.8, false, NULL),
    ('act_lt_deduardo_lm_3_4_cni_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_lm_3_4_cni', 'camp_2223', 'ta_e_don_eduardo_cd_cnd', 107, false, NULL),
    ('act_lt_deduardo_lm_3_4_cni_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_lm_3_4_cni', 'camp_2324', 'ta_e_don_eduardo_cd_cnd', 107, false, NULL),
    ('act_lt_deduardo_lm_3_4_cni_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_lm_3_4_cni', 'camp_2425', 'ta_e_don_eduardo_cd_cnd', 107, false, NULL),
    ('act_lt_deduardo_lm_3_4_cni_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_lm_3_4_cni', 'camp_2526', 'ta_e_don_eduardo_cd_cnd', 107, false, NULL),
    ('act_lt_deduardo_lm_3_4_cni_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_lm_3_4_cni', 'camp_2627', 'ta_e_don_eduardo_cd_cnd', 107, false, NULL),
    ('act_lt_deduardo_lm_3_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_lm_3', 'camp_2223', 'ta_e_don_eduardo_cd_mzp', 12, false, NULL),
    ('act_lt_deduardo_lm_3_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_lm_3', 'camp_2324', 'ta_e_don_eduardo_cd_mzp', 12, false, NULL),
    ('act_lt_deduardo_lm_3_camp_2324_1', 'e_don_eduardo', 'lt_deduardo_lm_3', 'camp_2324', 'ta_e_don_eduardo_cd_vi', 12, true, NULL),
    ('act_lt_deduardo_lm_3_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_lm_3', 'camp_2425', 'ta_e_don_eduardo_cd_mzp', 12, false, NULL),
    ('act_lt_deduardo_lm_3_camp_2425_1', 'e_don_eduardo', 'lt_deduardo_lm_3', 'camp_2425', 'ta_e_don_eduardo_cd_vi', 12, true, NULL),
    ('act_lt_deduardo_lm_3_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_lm_3', 'camp_2526', 'ta_e_don_eduardo_cd_g', 12, false, NULL),
    ('act_lt_deduardo_lm_3_camp_2526_1', 'e_don_eduardo', 'lt_deduardo_lm_3', 'camp_2526', 'ta_e_don_eduardo_cd_pi', 12, true, NULL),
    ('act_lt_deduardo_lm_3_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_lm_3', 'camp_2627', 'ta_e_don_eduardo_cd_ppalf', 12, false, NULL),
    ('act_lt_deduardo_lm_5_cn_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_lm_5_cn', 'camp_2223', 'ta_e_don_eduardo_cd_cn', 28.2, false, NULL),
    ('act_lt_deduardo_lm_5_cn_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_lm_5_cn', 'camp_2324', 'ta_e_don_eduardo_cd_cn', 28.2, false, NULL),
    ('act_lt_deduardo_lm_5_cn_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_lm_5_cn', 'camp_2425', 'ta_e_don_eduardo_cd_cn', 28.2, false, NULL),
    ('act_lt_deduardo_lm_5_cn_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_lm_5_cn', 'camp_2526', 'ta_e_don_eduardo_cd_cn', 28.2, false, NULL),
    ('act_lt_deduardo_lm_5_cn_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_lm_5_cn', 'camp_2627', 'ta_e_don_eduardo_cd_cn', 28.2, false, NULL),
    ('act_lt_deduardo_lm_5_cni_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_lm_5_cni', 'camp_2223', 'ta_e_don_eduardo_cd_cnd', 30.8, false, NULL),
    ('act_lt_deduardo_lm_5_cni_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_lm_5_cni', 'camp_2324', 'ta_e_don_eduardo_cd_cnd', 30.8, false, NULL),
    ('act_lt_deduardo_lm_5_cni_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_lm_5_cni', 'camp_2425', 'ta_e_don_eduardo_cd_cnd', 30.8, false, NULL),
    ('act_lt_deduardo_lm_5_cni_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_lm_5_cni', 'camp_2526', 'ta_e_don_eduardo_cd_cnd', 30.8, false, NULL),
    ('act_lt_deduardo_lm_5_cni_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_lm_5_cni', 'camp_2627', 'ta_e_don_eduardo_cd_cnd', 30.8, false, NULL),
    ('act_lt_deduardo_lm_6_cn_n_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_lm_6_cn_n', 'camp_2223', 'ta_e_don_eduardo_cd_cn', 30.2, false, NULL),
    ('act_lt_deduardo_lm_6_cn_n_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_lm_6_cn_n', 'camp_2324', 'ta_e_don_eduardo_cd_cn', 30.2, false, NULL),
    ('act_lt_deduardo_lm_6_cn_n_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_lm_6_cn_n', 'camp_2425', 'ta_e_don_eduardo_cd_cn', 30.2, false, NULL),
    ('act_lt_deduardo_lm_6_cn_n_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_lm_6_cn_n', 'camp_2526', 'ta_e_don_eduardo_cd_cn', 30.2, false, NULL),
    ('act_lt_deduardo_lm_6_cn_n_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_lm_6_cn_n', 'camp_2627', 'ta_e_don_eduardo_cd_cn', 30.2, false, NULL),
    ('act_lt_deduardo_lm_6_cn_s_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_lm_6_cn_s', 'camp_2223', 'ta_e_don_eduardo_cd_cn', 34.2, false, NULL),
    ('act_lt_deduardo_lm_6_cn_s_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_lm_6_cn_s', 'camp_2324', 'ta_e_don_eduardo_cd_cn', 34.2, false, NULL),
    ('act_lt_deduardo_lm_6_cn_s_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_lm_6_cn_s', 'camp_2425', 'ta_e_don_eduardo_cd_cn', 34.2, false, NULL),
    ('act_lt_deduardo_lm_6_cn_s_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_lm_6_cn_s', 'camp_2526', 'ta_e_don_eduardo_cd_cn', 34.2, false, NULL),
    ('act_lt_deduardo_lm_6_cn_s_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_lm_6_cn_s', 'camp_2627', 'ta_e_don_eduardo_cd_cn', 34.2, false, NULL),
    ('act_lt_deduardo_lm_6_cn_s_camp_2627_1', 'e_don_eduardo', 'lt_deduardo_lm_6_cn_s', 'camp_2627', 'ta_e_don_eduardo_cd_vi', 34.2, true, NULL),
    ('act_lt_deduardo_lm_6_cni_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_lm_6_cni', 'camp_2223', 'ta_e_don_eduardo_cd_cnd', 73.9, false, NULL),
    ('act_lt_deduardo_lm_6_cni_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_lm_6_cni', 'camp_2324', 'ta_e_don_eduardo_cd_cnd', 73.9, false, NULL),
    ('act_lt_deduardo_lm_6_cni_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_lm_6_cni', 'camp_2425', 'ta_e_don_eduardo_cd_cnd', 73.9, false, NULL),
    ('act_lt_deduardo_lm_6_cni_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_lm_6_cni', 'camp_2526', 'ta_e_don_eduardo_cd_cnd', 73.9, false, NULL),
    ('act_lt_deduardo_lm_6_cni_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_lm_6_cni', 'camp_2627', 'ta_e_don_eduardo_cd_cnd', 73.9, false, NULL),
    ('act_lt_deduardo_lm_6_medio_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_lm_6_medio', 'camp_2223', 'ta_e_don_eduardo_cd_ppfe', 40, false, NULL),
    ('act_lt_deduardo_lm_6_medio_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_lm_6_medio', 'camp_2324', 'ta_e_don_eduardo_cd_ppfe', 40, false, NULL),
    ('act_lt_deduardo_lm_6_medio_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_lm_6_medio', 'camp_2425', 'ta_e_don_eduardo_cd_ppfe', 40, false, NULL),
    ('act_lt_deduardo_lm_6_medio_camp_2425_1', 'e_don_eduardo', 'lt_deduardo_lm_6_medio', 'camp_2425', 'ta_e_don_eduardo_cd_vi', 40, true, NULL),
    ('act_lt_deduardo_lm_6_medio_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_lm_6_medio', 'camp_2526', 'ta_e_don_eduardo_cd_sj1', 32, false, NULL),
    ('act_lt_deduardo_lm_6_medio_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_lm_6_medio', 'camp_2627', 'ta_e_don_eduardo_cd_mzt', 32, false, NULL),
    ('act_lt_deduardo_lm_6_medio_camp_2728_0', 'e_don_eduardo', 'lt_deduardo_lm_6_medio', 'camp_2728', 'ta_e_don_eduardo_cd_g', 32, false, NULL),
    ('act_lt_deduardo_lm_6_medio_camp_2728_1', 'e_don_eduardo', 'lt_deduardo_lm_6_medio', 'camp_2728', 'ta_e_don_eduardo_cd_pi', 32, true, NULL),
    ('act_lt_deduardo_lm_7_8_cn_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_lm_7_8_cn', 'camp_2223', 'ta_e_don_eduardo_cd_cn', 28, false, NULL),
    ('act_lt_deduardo_lm_7_8_cn_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_lm_7_8_cn', 'camp_2324', 'ta_e_don_eduardo_cd_cn', 28, false, NULL),
    ('act_lt_deduardo_lm_7_8_cn_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_lm_7_8_cn', 'camp_2425', 'ta_e_don_eduardo_cd_cn', 28, false, NULL),
    ('act_lt_deduardo_lm_7_8_cn_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_lm_7_8_cn', 'camp_2526', 'ta_e_don_eduardo_cd_cn', 28, false, NULL),
    ('act_lt_deduardo_lm_7_8_cn_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_lm_7_8_cn', 'camp_2627', 'ta_e_don_eduardo_cd_cn', 28, false, NULL),
    ('act_lt_deduardo_lm_7_8_cni_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_lm_7_8_cni', 'camp_2223', 'ta_e_don_eduardo_cd_cnd', 14.6, false, NULL),
    ('act_lt_deduardo_lm_7_8_cni_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_lm_7_8_cni', 'camp_2324', 'ta_e_don_eduardo_cd_cnd', 14.6, false, NULL),
    ('act_lt_deduardo_lm_7_8_cni_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_lm_7_8_cni', 'camp_2425', 'ta_e_don_eduardo_cd_cnd', 14.6, false, NULL),
    ('act_lt_deduardo_lm_7_8_cni_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_lm_7_8_cni', 'camp_2526', 'ta_e_don_eduardo_cd_cnd', 14.6, false, NULL),
    ('act_lt_deduardo_lm_7_8_cni_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_lm_7_8_cni', 'camp_2627', 'ta_e_don_eduardo_cd_cnd', 14.6, false, NULL),
    ('act_lt_deduardo_lm_7_9_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_lm_7_9', 'camp_2223', 'ta_e_don_eduardo_cd_mz', 39, false, NULL),
    ('act_lt_deduardo_lm_7_9_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_lm_7_9', 'camp_2324', 'ta_e_don_eduardo_cd_g', 37, false, NULL),
    ('act_lt_deduardo_lm_7_9_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_lm_7_9', 'camp_2425', 'ta_e_don_eduardo_cd_tr', 37, false, NULL),
    ('act_lt_deduardo_lm_7_9_camp_2425_1', 'e_don_eduardo', 'lt_deduardo_lm_7_9', 'camp_2425', 'ta_e_don_eduardo_cd_sj2', 37, true, NULL),
    ('act_lt_deduardo_lm_7_9_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_lm_7_9', 'camp_2526', 'ta_e_don_eduardo_cd_mz', 37, false, NULL),
    ('act_lt_deduardo_lm_7_9_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_lm_7_9', 'camp_2627', 'ta_e_don_eduardo_cd_sj1', 37, false, NULL),
    ('act_lt_deduardo_lm_7_9_camp_2728_0', 'e_don_eduardo', 'lt_deduardo_lm_7_9', 'camp_2728', 'ta_e_don_eduardo_cd_tr', 37, false, NULL),
    ('act_lt_deduardo_lm_7_9_camp_2728_1', 'e_don_eduardo', 'lt_deduardo_lm_7_9', 'camp_2728', 'ta_e_don_eduardo_cd_sj2', 37, true, NULL),
    ('act_lt_deduardo_lm_8_n_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_lm_8_n', 'camp_2223', 'ta_e_don_eduardo_cd_mz', 6, false, NULL),
    ('act_lt_deduardo_lm_8_n_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_lm_8_n', 'camp_2324', 'ta_e_don_eduardo_cd_g', 6, false, NULL),
    ('act_lt_deduardo_lm_8_n_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_lm_8_n', 'camp_2425', 'ta_e_don_eduardo_cd_tr', 6, false, NULL),
    ('act_lt_deduardo_lm_8_n_camp_2425_1', 'e_don_eduardo', 'lt_deduardo_lm_8_n', 'camp_2425', 'ta_e_don_eduardo_cd_sj2', 6, true, NULL),
    ('act_lt_deduardo_lm_8_n_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_lm_8_n', 'camp_2526', 'ta_e_don_eduardo_cd_mzt', 6, false, NULL),
    ('act_lt_deduardo_lm_8_n_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_lm_8_n', 'camp_2627', 'ta_e_don_eduardo_cd_sj1', 6, false, NULL),
    ('act_lt_deduardo_lm_8_n_camp_2728_0', 'e_don_eduardo', 'lt_deduardo_lm_8_n', 'camp_2728', 'ta_e_don_eduardo_cd_tr', 6, false, NULL),
    ('act_lt_deduardo_lm_8_n_camp_2728_1', 'e_don_eduardo', 'lt_deduardo_lm_8_n', 'camp_2728', 'ta_e_don_eduardo_cd_sj2', 6, true, NULL),
    ('act_lt_deduardo_lm_8_s_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_lm_8_s', 'camp_2223', 'ta_e_don_eduardo_cd_mz', 11, false, NULL),
    ('act_lt_deduardo_lm_8_s_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_lm_8_s', 'camp_2324', 'ta_e_don_eduardo_cd_g', 11, false, NULL),
    ('act_lt_deduardo_lm_8_s_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_lm_8_s', 'camp_2425', 'ta_e_don_eduardo_cd_tr', 11, false, NULL),
    ('act_lt_deduardo_lm_8_s_camp_2425_1', 'e_don_eduardo', 'lt_deduardo_lm_8_s', 'camp_2425', 'ta_e_don_eduardo_cd_sj2', 11, true, NULL),
    ('act_lt_deduardo_lm_8_s_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_lm_8_s', 'camp_2526', 'ta_e_don_eduardo_cd_mz', 11, false, NULL),
    ('act_lt_deduardo_lm_8_s_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_lm_8_s', 'camp_2627', 'ta_e_don_eduardo_cd_sj1', 11, false, NULL),
    ('act_lt_deduardo_lm_8_s_camp_2728_0', 'e_don_eduardo', 'lt_deduardo_lm_8_s', 'camp_2728', 'ta_e_don_eduardo_cd_tr', 11, false, NULL),
    ('act_lt_deduardo_lm_8_s_camp_2728_1', 'e_don_eduardo', 'lt_deduardo_lm_8_s', 'camp_2728', 'ta_e_don_eduardo_cd_sj2', 11, true, NULL),
    ('act_lt_deduardo_lr_10a_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_lr_10a', 'camp_2223', 'ta_e_don_eduardo_cd_sj1', 7, false, NULL),
    ('act_lt_deduardo_lr_10a_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_lr_10a', 'camp_2324', 'ta_e_don_eduardo_cd_mzspe', 7, false, NULL),
    ('act_lt_deduardo_lr_10a_camp_2324_1', 'e_don_eduardo', 'lt_deduardo_lr_10a', 'camp_2324', 'ta_e_don_eduardo_cd_pi', 7, true, NULL),
    ('act_lt_deduardo_lr_10a_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_lr_10a', 'camp_2425', 'ta_e_don_eduardo_cd_ppfe', 7, false, NULL),
    ('act_lt_deduardo_lr_10a_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_lr_10a', 'camp_2526', 'ta_e_don_eduardo_cd_ppfe', 7, false, NULL),
    ('act_lt_deduardo_lr_10a_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_lr_10a', 'camp_2627', 'ta_e_don_eduardo_cd_ppfe', 7, false, NULL),
    ('act_lt_deduardo_lr_10b_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_lr_10b', 'camp_2223', 'ta_e_don_eduardo_cd_sj1', 15, false, NULL),
    ('act_lt_deduardo_lr_10b_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_lr_10b', 'camp_2324', 'ta_e_don_eduardo_cd_mzspe', 16, false, NULL),
    ('act_lt_deduardo_lr_10b_camp_2324_1', 'e_don_eduardo', 'lt_deduardo_lr_10b', 'camp_2324', 'ta_e_don_eduardo_cd_pi', 16, true, NULL),
    ('act_lt_deduardo_lr_10b_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_lr_10b', 'camp_2425', 'ta_e_don_eduardo_cd_ppfe', 16, false, NULL),
    ('act_lt_deduardo_lr_10b_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_lr_10b', 'camp_2526', 'ta_e_don_eduardo_cd_ppfe', 16, false, NULL),
    ('act_lt_deduardo_lr_10b_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_lr_10b', 'camp_2627', 'ta_e_don_eduardo_cd_ppfe', 16, false, NULL),
    ('act_lt_deduardo_lr_10c_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_lr_10c', 'camp_2223', 'ta_e_don_eduardo_cd_sj1', 13, false, NULL),
    ('act_lt_deduardo_lr_10c_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_lr_10c', 'camp_2324', 'ta_e_don_eduardo_cd_mzspe', 13, false, NULL),
    ('act_lt_deduardo_lr_10c_camp_2324_1', 'e_don_eduardo', 'lt_deduardo_lr_10c', 'camp_2324', 'ta_e_don_eduardo_cd_pi', 13, true, NULL),
    ('act_lt_deduardo_lr_10c_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_lr_10c', 'camp_2425', 'ta_e_don_eduardo_cd_ppfe', 13, false, NULL),
    ('act_lt_deduardo_lr_10c_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_lr_10c', 'camp_2526', 'ta_e_don_eduardo_cd_ppfe', 13, false, NULL),
    ('act_lt_deduardo_lr_10c_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_lr_10c', 'camp_2627', 'ta_e_don_eduardo_cd_ppfe', 13, false, NULL),
    ('act_lt_deduardo_lr_11_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_lr_11', 'camp_2223', 'ta_e_don_eduardo_cd_tr', 24, false, NULL),
    ('act_lt_deduardo_lr_11_camp_2223_1', 'e_don_eduardo', 'lt_deduardo_lr_11', 'camp_2223', 'ta_e_don_eduardo_cd_sj2', 24, true, NULL),
    ('act_lt_deduardo_lr_11_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_lr_11', 'camp_2324', 'ta_e_don_eduardo_cd_mzt', 24, false, NULL),
    ('act_lt_deduardo_lr_11_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_lr_11', 'camp_2425', 'ta_e_don_eduardo_cd_g', 24, false, NULL),
    ('act_lt_deduardo_lr_11_camp_2425_1', 'e_don_eduardo', 'lt_deduardo_lr_11', 'camp_2425', 'ta_e_don_eduardo_cd_pi', 24, true, NULL),
    ('act_lt_deduardo_lr_11_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_lr_11', 'camp_2526', 'ta_e_don_eduardo_cd_ppalf', 24, false, NULL),
    ('act_lt_deduardo_lr_11_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_lr_11', 'camp_2627', 'ta_e_don_eduardo_cd_ppalf', 24, false, NULL),
    ('act_lt_deduardo_lr_12_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_lr_12', 'camp_2223', 'ta_e_don_eduardo_cd_mzspe', 26, false, NULL),
    ('act_lt_deduardo_lr_12_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_lr_12', 'camp_2324', 'ta_e_don_eduardo_cd_pi', 26, false, NULL),
    ('act_lt_deduardo_lr_12_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_lr_12', 'camp_2425', 'ta_e_don_eduardo_cd_ppalf', 26, false, NULL),
    ('act_lt_deduardo_lr_12_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_lr_12', 'camp_2526', 'ta_e_don_eduardo_cd_ppalf', 26, false, NULL),
    ('act_lt_deduardo_lr_12_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_lr_12', 'camp_2627', 'ta_e_don_eduardo_cd_ppalf', 26, false, NULL),
    ('act_lt_deduardo_lr_12_cn_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_lr_12_cn', 'camp_2223', 'ta_e_don_eduardo_cd_cnd', 19, false, NULL),
    ('act_lt_deduardo_lr_12_cn_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_lr_12_cn', 'camp_2324', 'ta_e_don_eduardo_cd_cnd', 19, false, NULL),
    ('act_lt_deduardo_lr_12_cn_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_lr_12_cn', 'camp_2425', 'ta_e_don_eduardo_cd_cnd', 19, false, NULL),
    ('act_lt_deduardo_lr_12_cn_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_lr_12_cn', 'camp_2526', 'ta_e_don_eduardo_cd_cnd', 19, false, NULL),
    ('act_lt_deduardo_lr_12_cn_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_lr_12_cn', 'camp_2627', 'ta_e_don_eduardo_cd_cnd', 19, false, NULL),
    ('act_lt_deduardo_lr_13_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_lr_13', 'camp_2223', 'ta_e_don_eduardo_cd_tr', 33, false, NULL),
    ('act_lt_deduardo_lr_13_camp_2223_1', 'e_don_eduardo', 'lt_deduardo_lr_13', 'camp_2223', 'ta_e_don_eduardo_cd_sj2', 33, true, NULL),
    ('act_lt_deduardo_lr_13_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_lr_13', 'camp_2324', 'ta_e_don_eduardo_cd_mzt', 32, false, NULL),
    ('act_lt_deduardo_lr_13_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_lr_13', 'camp_2425', 'ta_e_don_eduardo_cd_sj1', 32, false, NULL),
    ('act_lt_deduardo_lr_13_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_lr_13', 'camp_2526', 'ta_e_don_eduardo_cd_tr', 32, false, NULL),
    ('act_lt_deduardo_lr_13_camp_2526_1', 'e_don_eduardo', 'lt_deduardo_lr_13', 'camp_2526', 'ta_e_don_eduardo_cd_sj2', 32, true, NULL),
    ('act_lt_deduardo_lr_13_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_lr_13', 'camp_2627', 'ta_e_don_eduardo_cd_mz', 32, false, NULL),
    ('act_lt_deduardo_lr_13_camp_2728_0', 'e_don_eduardo', 'lt_deduardo_lr_13', 'camp_2728', 'ta_e_don_eduardo_cd_sj1', 32, false, NULL),
    ('act_lt_deduardo_lr_13_cn_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_lr_13_cn', 'camp_2223', 'ta_e_don_eduardo_cd_cn', 5, false, NULL),
    ('act_lt_deduardo_lr_13_cn_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_lr_13_cn', 'camp_2324', 'ta_e_don_eduardo_cd_cn', 5, false, NULL),
    ('act_lt_deduardo_lr_13_cn_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_lr_13_cn', 'camp_2425', 'ta_e_don_eduardo_cd_cn', 5, false, NULL),
    ('act_lt_deduardo_lr_13_cn_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_lr_13_cn', 'camp_2526', 'ta_e_don_eduardo_cd_cn', 5, false, NULL),
    ('act_lt_deduardo_lr_13_cn_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_lr_13_cn', 'camp_2627', 'ta_e_don_eduardo_cd_cn', 5, false, NULL),
    ('act_lt_deduardo_lr_14_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_lr_14', 'camp_2223', 'ta_e_don_eduardo_cd_sj1', 34, false, NULL),
    ('act_lt_deduardo_lr_14_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_lr_14', 'camp_2324', 'ta_e_don_eduardo_cd_g', 34, false, NULL),
    ('act_lt_deduardo_lr_14_camp_2324_1', 'e_don_eduardo', 'lt_deduardo_lr_14', 'camp_2324', 'ta_e_don_eduardo_cd_pi', 34, true, NULL),
    ('act_lt_deduardo_lr_14_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_lr_14', 'camp_2425', 'ta_e_don_eduardo_cd_ppfe', 34, false, NULL),
    ('act_lt_deduardo_lr_14_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_lr_14', 'camp_2526', 'ta_e_don_eduardo_cd_ppfe', 34, false, NULL),
    ('act_lt_deduardo_lr_14_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_lr_14', 'camp_2627', 'ta_e_don_eduardo_cd_ppfe', 34, false, NULL),
    ('act_lt_deduardo_lr_15_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_lr_15', 'camp_2223', 'ta_e_don_eduardo_cd_ppalf', 30, false, NULL),
    ('act_lt_deduardo_lr_15_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_lr_15', 'camp_2324', 'ta_e_don_eduardo_cd_ppalf', 30, false, NULL),
    ('act_lt_deduardo_lr_15_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_lr_15', 'camp_2425', 'ta_e_don_eduardo_cd_ppalf', 30, false, NULL),
    ('act_lt_deduardo_lr_15_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_lr_15', 'camp_2526', 'ta_e_don_eduardo_cd_ppalf', 30, false, NULL),
    ('act_lt_deduardo_lr_15_camp_2526_1', 'e_don_eduardo', 'lt_deduardo_lr_15', 'camp_2526', 'ta_e_don_eduardo_cd_vi', 30, true, NULL),
    ('act_lt_deduardo_lr_15_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_lr_15', 'camp_2627', 'ta_e_don_eduardo_cd_sj1', 30, false, NULL),
    ('act_lt_deduardo_lr_15_camp_2728_0', 'e_don_eduardo', 'lt_deduardo_lr_15', 'camp_2728', 'ta_e_don_eduardo_cd_mz', 30, false, NULL),
    ('act_lt_deduardo_lr_16_bajo_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_lr_16_bajo', 'camp_2223', 'ta_e_don_eduardo_cd_ppalf', 10, false, NULL),
    ('act_lt_deduardo_lr_16_bajo_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_lr_16_bajo', 'camp_2324', 'ta_e_don_eduardo_cd_mzt', 10, false, NULL),
    ('act_lt_deduardo_lr_16_bajo_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_lr_16_bajo', 'camp_2425', 'ta_e_don_eduardo_cd_g', 10, false, NULL),
    ('act_lt_deduardo_lr_16_bajo_camp_2425_1', 'e_don_eduardo', 'lt_deduardo_lr_16_bajo', 'camp_2425', 'ta_e_don_eduardo_cd_pi', 10, true, NULL),
    ('act_lt_deduardo_lr_16_bajo_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_lr_16_bajo', 'camp_2526', 'ta_e_don_eduardo_cd_ppag', 10, false, NULL),
    ('act_lt_deduardo_lr_16_bajo_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_lr_16_bajo', 'camp_2627', 'ta_e_don_eduardo_cd_ppag', 10, false, NULL),
    ('act_lt_deduardo_lr_16_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_lr_16', 'camp_2223', 'ta_e_don_eduardo_cd_ppalf', 24, false, NULL),
    ('act_lt_deduardo_lr_16_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_lr_16', 'camp_2324', 'ta_e_don_eduardo_cd_mzt', 24, false, NULL),
    ('act_lt_deduardo_lr_16_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_lr_16', 'camp_2425', 'ta_e_don_eduardo_cd_g', 24, false, NULL),
    ('act_lt_deduardo_lr_16_camp_2425_1', 'e_don_eduardo', 'lt_deduardo_lr_16', 'camp_2425', 'ta_e_don_eduardo_cd_pi', 24, true, NULL),
    ('act_lt_deduardo_lr_16_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_lr_16', 'camp_2526', 'ta_e_don_eduardo_cd_ppalf', 24, false, NULL),
    ('act_lt_deduardo_lr_16_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_lr_16', 'camp_2627', 'ta_e_don_eduardo_cd_ppalf', 24, false, NULL),
    ('act_lt_deduardo_lr_16_cn_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_lr_16_cn', 'camp_2223', 'ta_e_don_eduardo_cd_cn', 6, false, NULL),
    ('act_lt_deduardo_lr_16_cn_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_lr_16_cn', 'camp_2324', 'ta_e_don_eduardo_cd_cn', 6, false, NULL),
    ('act_lt_deduardo_lr_16_cn_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_lr_16_cn', 'camp_2425', 'ta_e_don_eduardo_cd_cn', 6, false, NULL),
    ('act_lt_deduardo_lr_16_cn_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_lr_16_cn', 'camp_2526', 'ta_e_don_eduardo_cd_cn', 6, false, NULL),
    ('act_lt_deduardo_lr_16_cn_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_lr_16_cn', 'camp_2627', 'ta_e_don_eduardo_cd_cn', 6, false, NULL),
    ('act_lt_deduardo_lr_17_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_lr_17', 'camp_2223', 'ta_e_don_eduardo_cd_mzp', 17, false, NULL),
    ('act_lt_deduardo_lr_17_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_lr_17', 'camp_2324', 'ta_e_don_eduardo_cd_mzp', 17, false, NULL),
    ('act_lt_deduardo_lr_17_camp_2324_1', 'e_don_eduardo', 'lt_deduardo_lr_17', 'camp_2324', 'ta_e_don_eduardo_cd_pi', 17, true, NULL),
    ('act_lt_deduardo_lr_17_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_lr_17', 'camp_2425', 'ta_e_don_eduardo_cd_ppfe', 17, false, NULL),
    ('act_lt_deduardo_lr_17_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_lr_17', 'camp_2526', 'ta_e_don_eduardo_cd_ppfe', 17, false, NULL),
    ('act_lt_deduardo_lr_17_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_lr_17', 'camp_2627', 'ta_e_don_eduardo_cd_ppfe', 17, false, NULL),
    ('act_lt_deduardo_lr_17_loma_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_lr_17_loma', 'camp_2223', 'ta_e_don_eduardo_cd_ppfe', 16, false, NULL),
    ('act_lt_deduardo_lr_17_loma_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_lr_17_loma', 'camp_2324', 'ta_e_don_eduardo_cd_ppfe', 16, false, NULL),
    ('act_lt_deduardo_lr_17_loma_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_lr_17_loma', 'camp_2425', 'ta_e_don_eduardo_cd_ppfe', 16, false, NULL),
    ('act_lt_deduardo_lr_17_loma_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_lr_17_loma', 'camp_2526', 'ta_e_don_eduardo_cd_mzt', 16, false, NULL),
    ('act_lt_deduardo_lr_17_loma_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_lr_17_loma', 'camp_2627', 'ta_e_don_eduardo_cd_sj1', 16, false, NULL),
    ('act_lt_deduardo_lr_17_loma_camp_2728_0', 'e_don_eduardo', 'lt_deduardo_lr_17_loma', 'camp_2728', 'ta_e_don_eduardo_cd_g', 16, false, NULL),
    ('act_lt_deduardo_lr_17_loma_camp_2728_1', 'e_don_eduardo', 'lt_deduardo_lr_17_loma', 'camp_2728', 'ta_e_don_eduardo_cd_pi', 16, true, NULL),
    ('act_lt_deduardo_lr_18_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_lr_18', 'camp_2223', 'ta_e_don_eduardo_cd_ppalf', 40, false, NULL),
    ('act_lt_deduardo_lr_18_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_lr_18', 'camp_2324', 'ta_e_don_eduardo_cd_ppalf', 40, false, NULL),
    ('act_lt_deduardo_lr_18_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_lr_18', 'camp_2425', 'ta_e_don_eduardo_cd_mz', 35, false, NULL),
    ('act_lt_deduardo_lr_18_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_lr_18', 'camp_2526', 'ta_e_don_eduardo_cd_sj1', 35, false, NULL),
    ('act_lt_deduardo_lr_18_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_lr_18', 'camp_2627', 'ta_e_don_eduardo_cd_mz', 35, false, NULL),
    ('act_lt_deduardo_lr_18_camp_2728_0', 'e_don_eduardo', 'lt_deduardo_lr_18', 'camp_2728', 'ta_e_don_eduardo_cd_sj1', 35, false, NULL),
    ('act_lt_deduardo_lr_18_cn_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_lr_18_cn', 'camp_2223', 'ta_e_don_eduardo_cd_cn', 10, false, NULL),
    ('act_lt_deduardo_lr_18_cn_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_lr_18_cn', 'camp_2324', 'ta_e_don_eduardo_cd_cn', 10, false, NULL),
    ('act_lt_deduardo_lr_18_cn_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_lr_18_cn', 'camp_2425', 'ta_e_don_eduardo_cd_cn', 10, false, NULL),
    ('act_lt_deduardo_lr_18_cn_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_lr_18_cn', 'camp_2526', 'ta_e_don_eduardo_cd_cn', 10, false, NULL),
    ('act_lt_deduardo_lr_18_cn_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_lr_18_cn', 'camp_2627', 'ta_e_don_eduardo_cd_cn', 10, false, NULL),
    ('act_lt_deduardo_lr_19_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_lr_19', 'camp_2223', 'ta_e_don_eduardo_cd_ppfe', 34, false, NULL),
    ('act_lt_deduardo_lr_19_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_lr_19', 'camp_2324', 'ta_e_don_eduardo_cd_ppfe', 34, false, NULL),
    ('act_lt_deduardo_lr_19_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_lr_19', 'camp_2425', 'ta_e_don_eduardo_cd_mz', 44, false, NULL),
    ('act_lt_deduardo_lr_19_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_lr_19', 'camp_2526', 'ta_e_don_eduardo_cd_sj1', 44, false, NULL),
    ('act_lt_deduardo_lr_19_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_lr_19', 'camp_2627', 'ta_e_don_eduardo_cd_g', 44, false, NULL),
    ('act_lt_deduardo_lr_19_camp_2627_1', 'e_don_eduardo', 'lt_deduardo_lr_19', 'camp_2627', 'ta_e_don_eduardo_cd_pi', 44, true, NULL),
    ('act_lt_deduardo_lr_19_camp_2728_0', 'e_don_eduardo', 'lt_deduardo_lr_19', 'camp_2728', 'ta_e_don_eduardo_cd_ppalf', 44, false, NULL),
    ('act_lt_deduardo_lr_19_cn_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_lr_19_cn', 'camp_2223', 'ta_e_don_eduardo_cd_cn', 11, false, NULL),
    ('act_lt_deduardo_lr_19_cn_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_lr_19_cn', 'camp_2324', 'ta_e_don_eduardo_cd_cn', 11, false, NULL),
    ('act_lt_deduardo_lr_19_cn_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_lr_19_cn', 'camp_2425', 'ta_e_don_eduardo_cd_cn', 11, false, NULL),
    ('act_lt_deduardo_lr_19_cn_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_lr_19_cn', 'camp_2526', 'ta_e_don_eduardo_cd_cn', 11, false, NULL),
    ('act_lt_deduardo_lr_19_cn_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_lr_19_cn', 'camp_2627', 'ta_e_don_eduardo_cd_cn', 11, false, NULL),
    ('act_lt_deduardo_lr_1_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_lr_1', 'camp_2223', 'ta_e_don_eduardo_cd_cnd', 87, false, NULL),
    ('act_lt_deduardo_lr_1_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_lr_1', 'camp_2324', 'ta_e_don_eduardo_cd_cnd', 87, false, NULL),
    ('act_lt_deduardo_lr_1_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_lr_1', 'camp_2425', 'ta_e_don_eduardo_cd_cnd', 87, false, NULL),
    ('act_lt_deduardo_lr_1_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_lr_1', 'camp_2526', 'ta_e_don_eduardo_cd_cnd', 87, false, NULL),
    ('act_lt_deduardo_lr_1_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_lr_1', 'camp_2627', 'ta_e_don_eduardo_cd_cnd', 87, false, NULL),
    ('act_lt_deduardo_lr_20_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_lr_20', 'camp_2223', 'ta_e_don_eduardo_cd_mzp', 35, false, NULL),
    ('act_lt_deduardo_lr_20_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_lr_20', 'camp_2324', 'ta_e_don_eduardo_cd_cn', 40, false, NULL),
    ('act_lt_deduardo_lr_20_camp_2324_1', 'e_don_eduardo', 'lt_deduardo_lr_20', 'camp_2324', 'ta_e_don_eduardo_cd_vi', 40, true, NULL),
    ('act_lt_deduardo_lr_20_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_lr_20', 'camp_2425', 'ta_e_don_eduardo_cd_mzd', 40, false, NULL),
    ('act_lt_deduardo_lr_20_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_lr_20', 'camp_2526', 'ta_e_don_eduardo_cd_cn', 36, false, NULL),
    ('act_lt_deduardo_lr_20_camp_2526_1', 'e_don_eduardo', 'lt_deduardo_lr_20', 'camp_2526', 'ta_e_don_eduardo_cd_prg', 36, true, NULL),
    ('act_lt_deduardo_lr_20_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_lr_20', 'camp_2627', 'ta_e_don_eduardo_cd_prg', 36, false, NULL),
    ('act_lt_deduardo_lr_20_cn_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_lr_20_cn', 'camp_2223', 'ta_e_don_eduardo_cd_cnd', 43, false, NULL),
    ('act_lt_deduardo_lr_20_cn_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_lr_20_cn', 'camp_2324', 'ta_e_don_eduardo_cd_cnd', 43, false, NULL),
    ('act_lt_deduardo_lr_20_cn_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_lr_20_cn', 'camp_2425', 'ta_e_don_eduardo_cd_cnd', 43, false, NULL),
    ('act_lt_deduardo_lr_20_cn_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_lr_20_cn', 'camp_2526', 'ta_e_don_eduardo_cd_cnd', 43, false, NULL),
    ('act_lt_deduardo_lr_20_cn_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_lr_20_cn', 'camp_2627', 'ta_e_don_eduardo_cd_cnd', 43, false, NULL),
    ('act_lt_deduardo_lr_22_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_lr_22', 'camp_2223', 'ta_e_don_eduardo_cd_cn', 35, false, NULL),
    ('act_lt_deduardo_lr_22_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_lr_22', 'camp_2324', 'ta_e_don_eduardo_cd_cn', 35, false, NULL),
    ('act_lt_deduardo_lr_22_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_lr_22', 'camp_2425', 'ta_e_don_eduardo_cd_cn', 35, false, NULL),
    ('act_lt_deduardo_lr_22_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_lr_22', 'camp_2526', 'ta_e_don_eduardo_cd_cn', 35, false, NULL),
    ('act_lt_deduardo_lr_22_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_lr_22', 'camp_2627', 'ta_e_don_eduardo_cd_cn', 35, false, NULL),
    ('act_lt_deduardo_lr_23_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_lr_23', 'camp_2223', 'ta_e_don_eduardo_cd_cnd', 29, false, NULL),
    ('act_lt_deduardo_lr_23_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_lr_23', 'camp_2324', 'ta_e_don_eduardo_cd_cnd', 29, false, NULL),
    ('act_lt_deduardo_lr_23_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_lr_23', 'camp_2425', 'ta_e_don_eduardo_cd_cnd', 29, false, NULL),
    ('act_lt_deduardo_lr_23_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_lr_23', 'camp_2526', 'ta_e_don_eduardo_cd_cnd', 29, false, NULL),
    ('act_lt_deduardo_lr_23_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_lr_23', 'camp_2627', 'ta_e_don_eduardo_cd_cnd', 29, false, NULL),
    ('act_lt_deduardo_lr_25_cn_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_lr_25_cn', 'camp_2223', 'ta_e_don_eduardo_cd_cnd', 93, false, NULL),
    ('act_lt_deduardo_lr_25_cn_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_lr_25_cn', 'camp_2324', 'ta_e_don_eduardo_cd_cnd', 93, false, NULL),
    ('act_lt_deduardo_lr_25_cn_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_lr_25_cn', 'camp_2425', 'ta_e_don_eduardo_cd_cnd', 93, false, NULL),
    ('act_lt_deduardo_lr_25_cn_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_lr_25_cn', 'camp_2526', 'ta_e_don_eduardo_cd_cnd', 93, false, NULL),
    ('act_lt_deduardo_lr_25_cn_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_lr_25_cn', 'camp_2627', 'ta_e_don_eduardo_cd_cnd', 93, false, NULL),
    ('act_lt_deduardo_lr_25_loma_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_lr_25_loma', 'camp_2223', 'ta_e_don_eduardo_cd_tr', 10, false, NULL),
    ('act_lt_deduardo_lr_25_loma_camp_2223_1', 'e_don_eduardo', 'lt_deduardo_lr_25_loma', 'camp_2223', 'ta_e_don_eduardo_cd_sj2', 10, true, NULL),
    ('act_lt_deduardo_lr_25_loma_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_lr_25_loma', 'camp_2324', 'ta_e_don_eduardo_cd_g', 10, false, NULL),
    ('act_lt_deduardo_lr_25_loma_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_lr_25_loma', 'camp_2425', 'ta_e_don_eduardo_cd_av', 10, false, NULL),
    ('act_lt_deduardo_lr_25_loma_camp_2425_1', 'e_don_eduardo', 'lt_deduardo_lr_25_loma', 'camp_2425', 'ta_e_don_eduardo_cd_mz2', 10, true, NULL),
    ('act_lt_deduardo_lr_25_loma_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_lr_25_loma', 'camp_2526', 'ta_e_don_eduardo_cd_sj1', 10, false, NULL),
    ('act_lt_deduardo_lr_25_loma_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_lr_25_loma', 'camp_2627', 'ta_e_don_eduardo_cd_av', 10, false, NULL),
    ('act_lt_deduardo_lr_25_loma_camp_2627_1', 'e_don_eduardo', 'lt_deduardo_lr_25_loma', 'camp_2627', 'ta_e_don_eduardo_cd_sj2', 10, true, NULL),
    ('act_lt_deduardo_lr_25_loma_camp_2728_0', 'e_don_eduardo', 'lt_deduardo_lr_25_loma', 'camp_2728', 'ta_e_don_eduardo_cd_mz', 10, false, NULL),
    ('act_lt_deduardo_lr_2_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_lr_2', 'camp_2223', 'ta_e_don_eduardo_cd_cnd', 46, false, NULL),
    ('act_lt_deduardo_lr_2_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_lr_2', 'camp_2324', 'ta_e_don_eduardo_cd_cnd', 46, false, NULL),
    ('act_lt_deduardo_lr_2_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_lr_2', 'camp_2425', 'ta_e_don_eduardo_cd_cnd', 46, false, NULL),
    ('act_lt_deduardo_lr_2_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_lr_2', 'camp_2526', 'ta_e_don_eduardo_cd_cnd', 46, false, NULL),
    ('act_lt_deduardo_lr_2_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_lr_2', 'camp_2627', 'ta_e_don_eduardo_cd_cnd', 46, false, NULL),
    ('act_lt_deduardo_lr_3_bajo_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_lr_3_bajo', 'camp_2223', 'ta_e_don_eduardo_cd_cn', 22, false, NULL),
    ('act_lt_deduardo_lr_3_bajo_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_lr_3_bajo', 'camp_2324', 'ta_e_don_eduardo_cd_cn', 22, false, NULL),
    ('act_lt_deduardo_lr_3_bajo_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_lr_3_bajo', 'camp_2425', 'ta_e_don_eduardo_cd_g', 22, false, NULL),
    ('act_lt_deduardo_lr_3_bajo_camp_2425_1', 'e_don_eduardo', 'lt_deduardo_lr_3_bajo', 'camp_2425', 'ta_e_don_eduardo_cd_cn', 22, true, NULL),
    ('act_lt_deduardo_lr_3_bajo_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_lr_3_bajo', 'camp_2526', 'ta_e_don_eduardo_cd_cn', 22, false, NULL),
    ('act_lt_deduardo_lr_3_bajo_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_lr_3_bajo', 'camp_2627', 'ta_e_don_eduardo_cd_cn', 22, false, NULL),
    ('act_lt_deduardo_lr_3_loma_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_lr_3_loma', 'camp_2223', 'ta_e_don_eduardo_cd_ppalf', 40, false, NULL),
    ('act_lt_deduardo_lr_3_loma_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_lr_3_loma', 'camp_2324', 'ta_e_don_eduardo_cd_ppalf', 40, false, NULL),
    ('act_lt_deduardo_lr_3_loma_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_lr_3_loma', 'camp_2425', 'ta_e_don_eduardo_cd_g', 40, false, NULL),
    ('act_lt_deduardo_lr_3_loma_camp_2425_1', 'e_don_eduardo', 'lt_deduardo_lr_3_loma', 'camp_2425', 'ta_e_don_eduardo_cd_pi', 40, true, NULL),
    ('act_lt_deduardo_lr_3_loma_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_lr_3_loma', 'camp_2526', 'ta_e_don_eduardo_cd_ppfe', 40, false, NULL),
    ('act_lt_deduardo_lr_3_loma_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_lr_3_loma', 'camp_2627', 'ta_e_don_eduardo_cd_ppfe', 40, false, NULL),
    ('act_lt_deduardo_lr_4_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_lr_4', 'camp_2223', 'ta_e_don_eduardo_cd_ppfe', 10, false, NULL),
    ('act_lt_deduardo_lr_4_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_lr_4', 'camp_2324', 'ta_e_don_eduardo_cd_ppfe', 10, false, NULL),
    ('act_lt_deduardo_lr_4_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_lr_4', 'camp_2425', 'ta_e_don_eduardo_cd_g', 10, false, NULL),
    ('act_lt_deduardo_lr_4_camp_2425_1', 'e_don_eduardo', 'lt_deduardo_lr_4', 'camp_2425', 'ta_e_don_eduardo_cd_pi', 10, true, NULL),
    ('act_lt_deduardo_lr_4_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_lr_4', 'camp_2526', 'ta_e_don_eduardo_cd_ppfe', 10, false, NULL),
    ('act_lt_deduardo_lr_4_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_lr_4', 'camp_2627', 'ta_e_don_eduardo_cd_ppfe', 10, false, NULL),
    ('act_lt_deduardo_lr_4_cn_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_lr_4_cn', 'camp_2223', 'ta_e_don_eduardo_cd_cnd', 38, false, NULL),
    ('act_lt_deduardo_lr_4_cn_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_lr_4_cn', 'camp_2324', 'ta_e_don_eduardo_cd_cnd', 38, false, NULL),
    ('act_lt_deduardo_lr_4_cn_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_lr_4_cn', 'camp_2425', 'ta_e_don_eduardo_cd_cnd', 38, false, NULL),
    ('act_lt_deduardo_lr_4_cn_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_lr_4_cn', 'camp_2526', 'ta_e_don_eduardo_cd_cnd', 38, false, NULL),
    ('act_lt_deduardo_lr_4_cn_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_lr_4_cn', 'camp_2627', 'ta_e_don_eduardo_cd_cnd', 38, false, NULL),
    ('act_lt_deduardo_lr_5_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_lr_5', 'camp_2223', 'ta_e_don_eduardo_cd_cn', 28, false, NULL),
    ('act_lt_deduardo_lr_5_camp_2223_1', 'e_don_eduardo', 'lt_deduardo_lr_5', 'camp_2223', 'ta_e_don_eduardo_cd_cn', 10, false, NULL),
    ('act_lt_deduardo_lr_5_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_lr_5', 'camp_2324', 'ta_e_don_eduardo_cd_cn', 28, false, NULL),
    ('act_lt_deduardo_lr_5_camp_2324_1', 'e_don_eduardo', 'lt_deduardo_lr_5', 'camp_2324', 'ta_e_don_eduardo_cd_cn', 10, false, NULL),
    ('act_lt_deduardo_lr_5_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_lr_5', 'camp_2425', 'ta_e_don_eduardo_cd_cn', 28, false, NULL),
    ('act_lt_deduardo_lr_5_camp_2425_1', 'e_don_eduardo', 'lt_deduardo_lr_5', 'camp_2425', 'ta_e_don_eduardo_cd_cn', 10, false, NULL),
    ('act_lt_deduardo_lr_5_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_lr_5', 'camp_2526', 'ta_e_don_eduardo_cd_cn', 28, false, NULL),
    ('act_lt_deduardo_lr_5_camp_2526_1', 'e_don_eduardo', 'lt_deduardo_lr_5', 'camp_2526', 'ta_e_don_eduardo_cd_cn', 10, false, NULL),
    ('act_lt_deduardo_lr_5_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_lr_5', 'camp_2627', 'ta_e_don_eduardo_cd_cn', 28, false, NULL),
    ('act_lt_deduardo_lr_5_camp_2627_1', 'e_don_eduardo', 'lt_deduardo_lr_5', 'camp_2627', 'ta_e_don_eduardo_cd_cn', 10, false, NULL),
    ('act_lt_deduardo_lr_6_7_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_lr_6_7', 'camp_2223', 'ta_e_don_eduardo_cd_tr', 42, false, NULL),
    ('act_lt_deduardo_lr_6_7_camp_2223_1', 'e_don_eduardo', 'lt_deduardo_lr_6_7', 'camp_2223', 'ta_e_don_eduardo_cd_sj2', 42, true, NULL),
    ('act_lt_deduardo_lr_6_7_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_lr_6_7', 'camp_2324', 'ta_e_don_eduardo_cd_g', 39, false, NULL),
    ('act_lt_deduardo_lr_6_7_camp_2324_1', 'e_don_eduardo', 'lt_deduardo_lr_6_7', 'camp_2324', 'ta_e_don_eduardo_cd_pi', 39, true, NULL),
    ('act_lt_deduardo_lr_6_7_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_lr_6_7', 'camp_2425', 'ta_e_don_eduardo_cd_ppalf', 39, false, NULL),
    ('act_lt_deduardo_lr_6_7_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_lr_6_7', 'camp_2526', 'ta_e_don_eduardo_cd_ppalf', 39, false, NULL),
    ('act_lt_deduardo_lr_6_7_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_lr_6_7', 'camp_2627', 'ta_e_don_eduardo_cd_ppalf', 39, false, NULL),
    ('act_lt_deduardo_lr_6_7_cn_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_lr_6_7_cn', 'camp_2223', 'ta_e_don_eduardo_cd_cn', 75, false, NULL),
    ('act_lt_deduardo_lr_6_7_cn_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_lr_6_7_cn', 'camp_2324', 'ta_e_don_eduardo_cd_cn', 75, false, NULL),
    ('act_lt_deduardo_lr_6_7_cn_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_lr_6_7_cn', 'camp_2425', 'ta_e_don_eduardo_cd_cn', 75, false, NULL),
    ('act_lt_deduardo_lr_6_7_cn_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_lr_6_7_cn', 'camp_2526', 'ta_e_don_eduardo_cd_cn', 75, false, NULL),
    ('act_lt_deduardo_lr_6_7_cn_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_lr_6_7_cn', 'camp_2627', 'ta_e_don_eduardo_cd_cn', 75, false, NULL),
    ('act_lt_deduardo_lr_8_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_lr_8', 'camp_2223', 'ta_e_don_eduardo_cd_sj1', 7, false, NULL),
    ('act_lt_deduardo_lr_8_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_lr_8', 'camp_2324', 'ta_e_don_eduardo_cd_mzspe', 6, false, NULL),
    ('act_lt_deduardo_lr_8_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_lr_8', 'camp_2425', 'ta_e_don_eduardo_cd_av', 6, false, NULL),
    ('act_lt_deduardo_lr_8_camp_2425_1', 'e_don_eduardo', 'lt_deduardo_lr_8', 'camp_2425', 'ta_e_don_eduardo_cd_mz2', 6, true, NULL),
    ('act_lt_deduardo_lr_8_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_lr_8', 'camp_2526', 'ta_e_don_eduardo_cd_sj1', 6, false, NULL),
    ('act_lt_deduardo_lr_8_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_lr_8', 'camp_2627', 'ta_e_don_eduardo_cd_av', 6, false, NULL),
    ('act_lt_deduardo_lr_8_camp_2627_1', 'e_don_eduardo', 'lt_deduardo_lr_8', 'camp_2627', 'ta_e_don_eduardo_cd_sj2', 6, true, NULL),
    ('act_lt_deduardo_lr_8_camp_2728_0', 'e_don_eduardo', 'lt_deduardo_lr_8', 'camp_2728', 'ta_e_don_eduardo_cd_mz', 6, false, NULL),
    ('act_lt_deduardo_lr_9_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_lr_9', 'camp_2223', 'ta_e_don_eduardo_cd_tr', 41, false, NULL),
    ('act_lt_deduardo_lr_9_camp_2223_1', 'e_don_eduardo', 'lt_deduardo_lr_9', 'camp_2223', 'ta_e_don_eduardo_cd_sj2', 41, true, NULL),
    ('act_lt_deduardo_lr_9_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_lr_9', 'camp_2324', 'ta_e_don_eduardo_cd_mzt', 41, false, NULL),
    ('act_lt_deduardo_lr_9_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_lr_9', 'camp_2425', 'ta_e_don_eduardo_cd_sj1', 41, false, NULL),
    ('act_lt_deduardo_lr_9_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_lr_9', 'camp_2526', 'ta_e_don_eduardo_cd_mz', 41, false, NULL),
    ('act_lt_deduardo_lr_9_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_lr_9', 'camp_2627', 'ta_e_don_eduardo_cd_sj1', 41, false, NULL),
    ('act_lt_deduardo_lr_9_camp_2728_0', 'e_don_eduardo', 'lt_deduardo_lr_9', 'camp_2728', 'ta_e_don_eduardo_cd_tr', 41, false, NULL),
    ('act_lt_deduardo_lr_9_camp_2728_1', 'e_don_eduardo', 'lt_deduardo_lr_9', 'camp_2728', 'ta_e_don_eduardo_cd_sj2', 41, true, NULL),
    ('act_lt_deduardo_lr_monte_casco_camp_2223_0', 'e_don_eduardo', 'lt_deduardo_lr_monte_casco', 'camp_2223', 'ta_e_don_eduardo_cd_cn', 5, false, NULL),
    ('act_lt_deduardo_lr_monte_casco_camp_2324_0', 'e_don_eduardo', 'lt_deduardo_lr_monte_casco', 'camp_2324', 'ta_e_don_eduardo_cd_cn', 5, false, NULL),
    ('act_lt_deduardo_lr_monte_casco_camp_2425_0', 'e_don_eduardo', 'lt_deduardo_lr_monte_casco', 'camp_2425', 'ta_e_don_eduardo_cd_cn', 5, false, NULL),
    ('act_lt_deduardo_lr_monte_casco_camp_2526_0', 'e_don_eduardo', 'lt_deduardo_lr_monte_casco', 'camp_2526', 'ta_e_don_eduardo_cd_mzp', 5, false, NULL),
    ('act_lt_deduardo_lr_monte_casco_camp_2526_1', 'e_don_eduardo', 'lt_deduardo_lr_monte_casco', 'camp_2526', 'ta_e_don_eduardo_cd_vi', 5, true, NULL),
    ('act_lt_deduardo_lr_monte_casco_camp_2627_0', 'e_don_eduardo', 'lt_deduardo_lr_monte_casco', 'camp_2627', 'ta_e_don_eduardo_cd_mzp', 5, false, NULL);

-- Usuarios seed — contraseña por defecto: demo1234
-- (hash generado con crypto.scrypt, salt:key)
INSERT INTO usuarios (id, nombre, email, rol, cliente_id, activo, password_hash) VALUES
    ('u_admin',        'Admin Demo',  'demo@puntalagro.com', 'admin_general', null, true,
     'f9d96ba1bb52f529519548307fe46d75:05bfad622333d9e7c64127c73a3f4182a4def4b7a708a2d58276903873d080f63e48aa433bab45710ec9b194bcd0b42cf498305436327a9f619a818fc5b78e58'),
    ('u_admin_puntal', 'Admin Puntal','admin@puntal.com',    'admin_general', null, true,
     'f9d96ba1bb52f529519548307fe46d75:05bfad622333d9e7c64127c73a3f4182a4def4b7a708a2d58276903873d080f63e48aa433bab45710ec9b194bcd0b42cf498305436327a9f619a818fc5b78e58'),
    -- cliente_id de María fijado a cli_demo: es una 'usuario' del cliente demo
    -- (su único permiso, sobre e_1, pertenece a ese cliente).
    ('u_maria',        'María Albor', 'maria@albor.com',     'usuario',       'cli_demo', true,
     'f9d96ba1bb52f529519548307fe46d75:05bfad622333d9e7c64127c73a3f4182a4def4b7a708a2d58276903873d080f63e48aa433bab45710ec9b194bcd0b42cf498305436327a9f619a818fc5b78e58'),
    -- admin_cliente de prueba: NO necesita fila propia en `permisos` — ya tiene
    -- acceso administrar pleno sobre todas las empresas de su cliente (ver
    -- obtenerPermiso() en server.js). Sirve para probar el scoping por cliente.
    ('u_rosario',      'Rosario Cliente','rosario@albor.com', 'admin_cliente', 'cli_demo', true,
     'f9d96ba1bb52f529519548307fe46d75:05bfad622333d9e7c64127c73a3f4182a4def4b7a708a2d58276903873d080f63e48aa433bab45710ec9b194bcd0b42cf498305436327a9f619a818fc5b78e58');

INSERT INTO permisos (usuario_id, empresa_id, campo_ids, herramientas, nivel) VALUES
    ('u_admin',        'e_1', '{}', '{}', 'administrar'),
    ('u_admin',        'e_2', '{}', '{}', 'administrar'),
    ('u_admin_puntal', 'e_1', '{}', '{}', 'administrar'),
    ('u_admin_puntal', 'e_2', '{}', '{}', 'administrar'),
    ('u_maria',        'e_1', '{}', '{}', 'ver');

-- Sesión demo con token fijo (para desarrollo local sin login)
INSERT INTO sesiones (token, usuario_id, expira_en) VALUES
    ('token-demo', 'u_admin', NOW() + INTERVAL '10 years');

-- ─────────────────────────────────────────────────────────────────────────────
-- FIN DEL SCRIPT
-- =============================================================================
