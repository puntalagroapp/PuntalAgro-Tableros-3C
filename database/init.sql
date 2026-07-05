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
    id         TEXT PRIMARY KEY,
    nombre     TEXT NOT NULL,
    precio_ref NUMERIC(12,2) DEFAULT 0,
    activo     BOOLEAN NOT NULL DEFAULT true
);
CREATE UNIQUE INDEX uq_labores_nombre ON labores (trim(lower(nombre)));

CREATE TABLE herramientas (
    id          TEXT PRIMARY KEY,
    nombre      TEXT NOT NULL,
    descripcion TEXT,
    tipo        TEXT NOT NULL DEFAULT 'propia' CHECK (tipo IN ('propia','externa')),
    url         TEXT,
    dominio     TEXT,
    activa      BOOLEAN NOT NULL DEFAULT true,
    asignable   BOOLEAN NOT NULL DEFAULT true
);

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
    id         TEXT PRIMARY KEY,
    campo_id   TEXT REFERENCES campos(id) ON DELETE CASCADE,
    empresa_id TEXT NOT NULL REFERENCES empresas(id),
    nombre     TEXT,
    ha         NUMERIC(10,2)
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
    tc_mensual  JSONB NOT NULL DEFAULT '{}',
    tc_apertura NUMERIC(12,2) DEFAULT 0,
    tc_cierre   NUMERIC(12,2) DEFAULT 0
);

-- ─────────────────────────────────────────────────────────────────────────────
-- SECCIÓN 6: TABLEROS (JSON blob — compatibilidad con tableros legacy)
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE tableros (
    id            SERIAL PRIMARY KEY,
    nombre_clave  TEXT NOT NULL UNIQUE,
    data_json     JSONB NOT NULL DEFAULT '{}',
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ─────────────────────────────────────────────────────────────────────────────
-- SECCIÓN 7: DATOS INICIALES (SEED)
-- ─────────────────────────────────────────────────────────────────────────────

-- Campañas
INSERT INTO campanias (id, nombre, orden, activa) VALUES
    ('camp_2324', '23/24', 1, false),
    ('camp_2425', '24/25', 2, false),
    ('camp_2526', '25/26', 3, true);

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

-- Usuarios seed — contraseña por defecto: demo1234
-- (hash generado con crypto.scrypt, salt:key)
INSERT INTO usuarios (id, nombre, email, rol, cliente_id, activo, password_hash) VALUES
    ('u_admin',        'Admin Demo',  'demo@puntalagro.com', 'admin_general', null, true,
     '5bee884e2c573755ecdf91f3222e8ef3:0cebb07c3dd38ebf349176a8e71570c6cf71df0815d4e3d6b30e7ac8221083ed2e6655e4518316276a02145196f52b420f30d27a50cbad2af83cf73eb28af6fb'),
    ('u_admin_puntal', 'Admin Puntal','admin@puntal.com',    'admin_general', null, true,
     '5bee884e2c573755ecdf91f3222e8ef3:0cebb07c3dd38ebf349176a8e71570c6cf71df0815d4e3d6b30e7ac8221083ed2e6655e4518316276a02145196f52b420f30d27a50cbad2af83cf73eb28af6fb'),
    ('u_maria',        'María Albor', 'maria@albor.com',     'usuario',       null, true,
     '5bee884e2c573755ecdf91f3222e8ef3:0cebb07c3dd38ebf349176a8e71570c6cf71df0815d4e3d6b30e7ac8221083ed2e6655e4518316276a02145196f52b420f30d27a50cbad2af83cf73eb28af6fb');

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
