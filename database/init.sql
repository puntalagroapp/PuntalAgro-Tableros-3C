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

-- Usos (cultivo / unidad de negocio — global)
CREATE TABLE usos_actividad (
    id     TEXT PRIMARY KEY,
    codigo TEXT NOT NULL,
    label  TEXT NOT NULL,
    activo BOOLEAN NOT NULL DEFAULT true
);
CREATE UNIQUE INDEX uq_usos_actividad_codigo ON usos_actividad (trim(lower(codigo)));

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
INSERT INTO usos_actividad (id, codigo, label, activo) VALUES
    ('uso_agr', 'AGR', 'Agricultura',      true),
    ('uso_gan', 'GAN', 'Ganadería',        true),
    ('uso_dob', 'DOB', 'Doble propósito',  true);

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
