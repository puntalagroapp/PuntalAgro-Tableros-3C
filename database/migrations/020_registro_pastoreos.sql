-- Migración 020: Registro de Pastoreos (registro_pastoreos.html, BUILD 60 del cliente)
--
-- Reemplaza las claves gan_* que la herramienta guardaba en el navegador.
-- Estructura en columnas; JSONB solo en pastoreo_config (bolsa de parámetros
-- que se guarda entera) y pastoreo_pendientes (entregas históricas transitorias).
--
-- Sin claves foráneas a lotes, tipos de actividad ni insumos: "Cargar datos"
-- borra y vuelve a crear los lotes/actividades (Plan de Uso) y los insumos
-- (Registro de Labores) de la empresa, y una FK haría fallar esa carga o
-- borraría los pastoreos. Mismo criterio que los lotes de las OT.

BEGIN;

-- ── Herramienta ──────────────────────────────────────────────────────────────
INSERT INTO herramientas (id, nombre, descripcion, tipo, url, dominio, asignable) VALUES
    ('registro_pastoreos', 'Registro de Pastoreos',
     'Pastoreos por potrero: entradas y salidas de hacienda, suplementación, existencias por rodeo y categoría, y materia seca cosechada por recurso forrajero.',
     'propia', 'registro_pastoreos.html', 'Ganadería', true)
ON CONFLICT (id) DO NOTHING;

-- ── Recursos forrajeros nuevos (uso ganadero) ────────────────────────────────
INSERT INTO cultivos_default (id, sigla, nombre, es_cultivo, actividad, especie_id, graminea, default2da, activo) VALUES
    ('cd_rmz', 'RMz', 'Rastrojo de maíz',               true, 'GAN', null, true, false, true),
    ('cd_rv',  'RV',  'Rastrojos varios',               true, 'GAN', null, null, false, true),
    ('cd_csp', 'CSP', 'Cultivo de servicio pastoreado', true, 'GAN', null, null, false, true)
ON CONFLICT (id) DO NOTHING;

-- y en cada empresa existente (mismo formato que copia el alta de empresa)
INSERT INTO tipos_actividad (id, empresa_id, datos)
SELECT 'ta_' || e.id || '_' || c.id, e.id,
       jsonb_build_object('id', 'ta_' || e.id || '_' || c.id, 'empresaId', e.id, 'nombre', c.nombre, 'sigla', c.sigla,
                          'esCultivo', c.es_cultivo, 'actividad', c.actividad, 'especieId', c.especie_id,
                          'graminea', c.graminea, 'default2da', c.default2da, 'activo', true)
  FROM empresas e CROSS JOIN cultivos_default c
 WHERE c.id IN ('cd_rmz', 'cd_rv', 'cd_csp')
   AND NOT EXISTS (SELECT 1 FROM tipos_actividad t
                    WHERE t.empresa_id = e.id AND trim(lower(t.datos->>'nombre')) = trim(lower(c.nombre)))
ON CONFLICT (id, empresa_id) DO NOTHING;

-- ── % de materia seca del insumo (lo carga Registro de Pastoreos) ────────────
ALTER TABLE insumos ADD COLUMN IF NOT EXISTS pct_ms NUMERIC(6,2)
    CHECK (pct_ms IS NULL OR (pct_ms > 0 AND pct_ms <= 100));

-- ── Categorías de hacienda: catálogo GENERAL (solo admin_general) ────────────
CREATE TABLE categorias_hacienda (
    id      TEXT PRIMARY KEY,
    nombre  TEXT NOT NULL,
    orden   INTEGER NOT NULL DEFAULT 0,
    activo  BOOLEAN NOT NULL DEFAULT true
);
CREATE UNIQUE INDEX uq_categorias_hacienda_nombre ON categorias_hacienda (trim(lower(nombre)));
INSERT INTO categorias_hacienda (id, nombre, orden) VALUES
    ('cat_0', 'Orejano', 1), ('cat_1', 'Ternera', 2), ('cat_2', 'Vaq. 1-2', 3), ('cat_3', 'Vaq. 2-3', 4),
    ('cat_4', 'Ternero', 5), ('cat_5', 'Novillo 1-2', 6), ('cat_6', 'Novillo 2-3', 7), ('cat_7', 'Torito 1-2', 8),
    ('cat_8', 'Toro 2-3', 9), ('cat_9', 'Vaca cría', 10), ('cat_10', 'Toro padre', 11), ('cat_11', 'Vaca invernada', 12);

-- ── Unidades de negocio y rodeos (por empresa) ───────────────────────────────
CREATE TABLE negocios_ganaderos (
    id          TEXT NOT NULL,
    empresa_id  TEXT NOT NULL REFERENCES empresas(id) ON DELETE CASCADE,
    nombre      TEXT NOT NULL,
    activo      BOOLEAN NOT NULL DEFAULT true,
    PRIMARY KEY (id, empresa_id)
);
CREATE UNIQUE INDEX uq_negocios_ganaderos_nombre ON negocios_ganaderos (empresa_id, trim(lower(nombre)));

CREATE TABLE rodeos (
    id          TEXT NOT NULL,
    empresa_id  TEXT NOT NULL REFERENCES empresas(id) ON DELETE CASCADE,
    negocio_id  TEXT NOT NULL,
    nombre      TEXT NOT NULL,
    activo      BOOLEAN NOT NULL DEFAULT true,
    obs         TEXT NOT NULL DEFAULT '',
    creado      TIMESTAMPTZ,
    actualizado TIMESTAMPTZ,
    PRIMARY KEY (id, empresa_id),
    FOREIGN KEY (negocio_id, empresa_id) REFERENCES negocios_ganaderos(id, empresa_id) ON DELETE RESTRICT
);
CREATE UNIQUE INDEX uq_rodeos_nombre ON rodeos (empresa_id, trim(lower(nombre)));

-- ── Raciones (por empresa) ───────────────────────────────────────────────────
CREATE TABLE raciones (
    id          TEXT NOT NULL,
    empresa_id  TEXT NOT NULL REFERENCES empresas(id) ON DELETE CASCADE,
    nombre      TEXT NOT NULL,
    activa      BOOLEAN NOT NULL DEFAULT true,
    obs         TEXT NOT NULL DEFAULT '',
    creado      TIMESTAMPTZ,
    actualizado TIMESTAMPTZ,
    PRIMARY KEY (id, empresa_id)
);
CREATE UNIQUE INDEX uq_raciones_nombre ON raciones (empresa_id, trim(lower(nombre)));

CREATE TABLE racion_componentes (
    racion_id   TEXT NOT NULL,
    empresa_id  TEXT NOT NULL,
    orden       INTEGER NOT NULL,
    insumo_id   TEXT NOT NULL,
    pct_incl    NUMERIC(7,3) NOT NULL,
    PRIMARY KEY (racion_id, empresa_id, orden),
    FOREIGN KEY (racion_id, empresa_id) REFERENCES raciones(id, empresa_id) ON DELETE CASCADE
);

-- ── Pastoreos ────────────────────────────────────────────────────────────────
CREATE TABLE pastoreos (
    id                 TEXT NOT NULL,
    empresa_id         TEXT NOT NULL REFERENCES empresas(id) ON DELETE CASCADE,
    campania_id        TEXT REFERENCES campanias(id) ON DELETE RESTRICT,
    campo_id           TEXT,                 -- campo del lote principal (filtro de permisos)
    lote_id            TEXT NOT NULL,        -- lote principal
    lote_ids           TEXT[],               -- todos los lotes, si el pastoreo abarca varios
    num                INTEGER,              -- número del pastoreo dentro del lote principal
    tipo_actividad_id  TEXT,                 -- recurso forrajero
    origen             TEXT NOT NULL DEFAULT '',
    importado          BOOLEAN NOT NULL DEFAULT false,  -- vino del histórico (carga única)
    creado             TIMESTAMPTZ,
    actualizado        TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (id, empresa_id)
);
CREATE INDEX idx_pastoreos_empresa_campania ON pastoreos (empresa_id, campania_id);
CREATE INDEX idx_pastoreos_empresa_lote ON pastoreos (empresa_id, lote_id);

CREATE TABLE pastoreo_movimientos (
    pastoreo_id   TEXT NOT NULL,
    empresa_id    TEXT NOT NULL,
    id            TEXT NOT NULL,
    orden         INTEGER NOT NULL,
    fecha         DATE,
    fecha_txt     TEXT,                      -- solo si la fecha cargada no es válida (se muestra como error)
    tipo          TEXT NOT NULL,             -- inicio, fin, pase_e, pase_s, tras_e, tras_s, compra, venta, nac, mort, cesion, cat_s, cat_e
    categoria_id  TEXT REFERENCES categorias_hacienda(id) ON DELETE RESTRICT,
    rodeo_id      TEXT,
    cab           NUMERIC(12,2),
    kg            NUMERIC(12,3),             -- kg por cabeza
    obs           TEXT NOT NULL DEFAULT '',
    cambio_id     TEXT,                      -- liga el par de un cambio de categoría
    cierra        BOOLEAN NOT NULL DEFAULT false,
    PRIMARY KEY (pastoreo_id, empresa_id, id),
    FOREIGN KEY (pastoreo_id, empresa_id) REFERENCES pastoreos(id, empresa_id) ON DELETE CASCADE,
    FOREIGN KEY (rodeo_id, empresa_id) REFERENCES rodeos(id, empresa_id) ON DELETE RESTRICT
);
CREATE INDEX idx_pastoreo_movimientos_fecha ON pastoreo_movimientos (empresa_id, fecha);

CREATE TABLE pastoreo_suplementos (
    pastoreo_id    TEXT NOT NULL,
    empresa_id     TEXT NOT NULL,
    id             TEXT NOT NULL,
    orden          INTEGER NOT NULL,
    fecha          DATE,
    fecha_txt      TEXT,
    insumo_id      TEXT,                     -- entrega de un ingrediente…
    racion_id      TEXT,                     -- …o de una ración
    racion_nombre  TEXT,                     -- nombre de la ración al momento de la entrega
    kg_tc          NUMERIC(14,3),            -- kg tal cual
    pct_ms         NUMERIC(6,2),             -- % materia seca al momento de la entrega
    humedad        NUMERIC(8,5),             -- registros viejos (antes de pctMS)
    remito         TEXT,
    obs            TEXT NOT NULL DEFAULT '',
    PRIMARY KEY (pastoreo_id, empresa_id, id),
    FOREIGN KEY (pastoreo_id, empresa_id) REFERENCES pastoreos(id, empresa_id) ON DELETE CASCADE
);
CREATE INDEX idx_pastoreo_suplementos_fecha ON pastoreo_suplementos (empresa_id, fecha);

-- composición de la ración guardada en cada entrega (foto al momento de entregar)
CREATE TABLE pastoreo_suplemento_componentes (
    pastoreo_id   TEXT NOT NULL,
    empresa_id    TEXT NOT NULL,
    suplemento_id TEXT NOT NULL,
    orden         INTEGER NOT NULL,
    insumo_id     TEXT NOT NULL,
    pct_incl      NUMERIC(7,3),
    pct_ms        NUMERIC(6,2),
    PRIMARY KEY (pastoreo_id, empresa_id, suplemento_id, orden),
    FOREIGN KEY (pastoreo_id, empresa_id, suplemento_id)
        REFERENCES pastoreo_suplementos(pastoreo_id, empresa_id, id) ON DELETE CASCADE
);

-- ── Correcciones manuales por lote y campaña (el Plan de Uso no cambia) ──────
CREATE TABLE pastoreo_superficie (
    empresa_id   TEXT NOT NULL REFERENCES empresas(id) ON DELETE CASCADE,
    campania_id  TEXT NOT NULL REFERENCES campanias(id) ON DELETE RESTRICT,
    lote_id      TEXT NOT NULL,
    ganadera     BOOLEAN NOT NULL,
    PRIMARY KEY (empresa_id, campania_id, lote_id)
);

CREATE TABLE pastoreo_recurso (
    empresa_id         TEXT NOT NULL REFERENCES empresas(id) ON DELETE CASCADE,
    campania_id        TEXT NOT NULL REFERENCES campanias(id) ON DELETE RESTRICT,
    lote_id            TEXT NOT NULL,
    tipo_actividad_id  TEXT NOT NULL,
    PRIMARY KEY (empresa_id, campania_id, lote_id)
);

-- tasa de crecimiento bruta actual estimada por recurso (kg MS/ha/día)
CREATE TABLE pastoreo_tasas (
    empresa_id         TEXT NOT NULL REFERENCES empresas(id) ON DELETE CASCADE,
    tipo_actividad_id  TEXT NOT NULL,
    tcb                NUMERIC(8,2) NOT NULL,
    fecha              DATE,
    PRIMARY KEY (empresa_id, tipo_actividad_id)
);

-- coeficientes y parámetros del cálculo (se leen y guardan enteros)
CREATE TABLE pastoreo_config (
    empresa_id  TEXT PRIMARY KEY REFERENCES empresas(id) ON DELETE CASCADE,
    datos       JSONB NOT NULL DEFAULT '{}'
);

-- entregas históricas sin pastoreo asignado (se asignan a mano y desaparecen)
CREATE TABLE pastoreo_pendientes (
    empresa_id  TEXT PRIMARY KEY REFERENCES empresas(id) ON DELETE CASCADE,
    items       JSONB NOT NULL DEFAULT '[]'
);

COMMIT;
