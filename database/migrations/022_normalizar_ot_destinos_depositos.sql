-- Migración 022: saca el JSONB de las OT y de los depósitos.
--
-- 1) ot_trabajos.destinos (lotes de cada labor, con sus líneas de insumo y sus
--    cambios de cultivo) y ot_trabajos.plantilla (insumos sugeridos de la labor)
--    pasan a filas: ot_destinos, ot_destino_lineas, ot_destino_cambios_cultivo y
--    ot_plantilla. El servidor sigue armando el mismo documento para el tablero.
-- 2) depositos.datos pasa a columnas (nombre, clase, campo_id, especie_id, activo).
--
-- Antes de cambiar nada se verifica que los datos se puedan convertir sin perder
-- nada (referencias existentes, números y fechas válidos). Si algo no cierra, la
-- migración aborta entera y lista qué falló: no queda nada a medio hacer.
--
-- Se mantienen en JSONB, a propósito:
--   - ot_destinos.geo_ot: el polígono dibujado para la OT, mismo formato que lotes.geo.
--   - ordenes_trabajo.ultimo_registro: borrador de "Volver a pendiente", se lee y
--     se guarda entero.

BEGIN;

-- ── Helpers temporales (se borran solos al cerrar la sesión) ──────────────────
-- Número desde JSON: número, texto numérico o vacío. Otra cosa → 'NaN' (se reporta).
CREATE FUNCTION pg_temp.num(v jsonb) RETURNS numeric LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN v IS NULL OR jsonb_typeof(v) = 'null' THEN NULL
    WHEN jsonb_typeof(v) = 'number' THEN (v #>> '{}')::numeric
    WHEN jsonb_typeof(v) = 'string' AND btrim(v #>> '{}') = '' THEN NULL
    WHEN jsonb_typeof(v) = 'string' AND btrim(v #>> '{}') ~ '^-?[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?$'
      THEN btrim(v #>> '{}')::numeric
    ELSE 'NaN'::numeric
  END $$;
-- Fecha 'YYYY-MM-DD' (o vacía). Otra cosa → NULL (el chequeo previo la reporta).
CREATE FUNCTION pg_temp.fecha(t text) RETURNS date LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN t ~ '^\d{4}-\d{2}-\d{2}$' THEN t::date ELSE NULL END $$;

CREATE TEMP TABLE _dest ON COMMIT DROP AS
  SELECT t.id AS trabajo_id, t.empresa_id, o.n AS orden, o.d
    FROM ot_trabajos t, jsonb_array_elements(t.destinos) WITH ORDINALITY o(d, n)
   WHERE jsonb_typeof(t.destinos) = 'array' AND jsonb_typeof(o.d) = 'object';
CREATE TEMP TABLE _lin ON COMMIT DROP AS
  SELECT x.trabajo_id, x.empresa_id, x.d->>'id' AS destino_id, o.n AS orden, o.l
    FROM _dest x, jsonb_array_elements(x.d->'lineas') WITH ORDINALITY o(l, n)
   WHERE jsonb_typeof(x.d->'lineas') = 'array' AND jsonb_typeof(o.l) = 'object';
CREATE TEMP TABLE _cc ON COMMIT DROP AS
  SELECT x.trabajo_id, x.empresa_id, x.d->>'id' AS destino_id, o.n AS orden, o.c
    FROM _dest x, jsonb_array_elements(x.d->'cambiosCultivo') WITH ORDINALITY o(c, n)
   WHERE jsonb_typeof(x.d->'cambiosCultivo') = 'array' AND jsonb_typeof(o.c) = 'object';
CREATE TEMP TABLE _pla ON COMMIT DROP AS
  SELECT t.id AS trabajo_id, t.empresa_id, o.n AS orden, o.p
    FROM ot_trabajos t, jsonb_array_elements(t.plantilla) WITH ORDINALITY o(p, n)
   WHERE jsonb_typeof(t.plantilla) = 'array' AND jsonb_typeof(o.p) = 'object';

-- ── Chequeo previo ────────────────────────────────────────────────────────────
DO $$
DECLARE
  problemas text[] := '{}';
  r record;
BEGIN
  FOR r IN
    SELECT 'destino sin id en trabajo ' || trabajo_id AS p FROM _dest WHERE COALESCE(d->>'id', '') = ''
    UNION ALL
    SELECT 'destino ' || (d->>'id') || ' repetido en trabajo ' || trabajo_id FROM _dest
     GROUP BY trabajo_id, d->>'id' HAVING count(*) > 1
    UNION ALL
    SELECT 'destino ' || (d->>'id') || ': estadoLote "' || (d->>'estadoLote') || '"' FROM _dest
     WHERE COALESCE(d->>'estadoLote', '') NOT IN ('', 'Pendiente', 'Aplicado')
    UNION ALL
    SELECT 'destino ' || (d->>'id') || ': ha/haReal no numérico' FROM _dest
     WHERE pg_temp.num(d->'ha') = 'NaN' OR pg_temp.num(d->'haReal') = 'NaN'
    UNION ALL
    SELECT 'destino ' || (d->>'id') || ': fecha inválida "' || COALESCE(d->>'fechaAplicReal', '') || '" / "' || COALESCE(d->>'cultivoMantenidoFecha', '') || '"' FROM _dest
     WHERE (COALESCE(d->>'fechaAplicReal', '') <> '' AND pg_temp.fecha(d->>'fechaAplicReal') IS NULL)
        OR (COALESCE(d->>'cultivoMantenidoFecha', '') <> '' AND pg_temp.fecha(d->>'cultivoMantenidoFecha') IS NULL)
    UNION ALL
    SELECT 'destino ' || (d->>'id') || ': campo inexistente ' || (d->>'campoId') FROM _dest
     WHERE COALESCE(d->>'campoId', '') <> '' AND NOT EXISTS (SELECT 1 FROM campos c WHERE c.id = d->>'campoId')
    UNION ALL
    SELECT 'destino ' || destino_id || ': cambio de cultivo con fecha inválida "' || (c->>'fecha') || '"' FROM _cc
     WHERE COALESCE(c->>'fecha', '') <> '' AND pg_temp.fecha(c->>'fecha') IS NULL
    UNION ALL
    SELECT 'destino ' || destino_id || ': línea ' || orden || ' con número inválido' FROM _lin
     WHERE 'NaN' IN (pg_temp.num(l->'dosis'), pg_temp.num(l->'dosisReal'), pg_temp.num(l->'entregada'),
                     pg_temp.num(l->'usado'), pg_temp.num(l->'devStock'), pg_temp.num(l->'devBaja'))
    UNION ALL
    SELECT 'destino ' || destino_id || ': insumo inexistente ' || (l->>'insumoId') FROM _lin x
     WHERE COALESCE(l->>'insumoId', '') <> ''
       AND NOT EXISTS (SELECT 1 FROM insumos i WHERE i.id = x.l->>'insumoId' AND i.empresa_id = x.empresa_id)
    UNION ALL
    SELECT 'destino ' || destino_id || ': depósito inexistente ' || (l->>'depositoId') FROM _lin x
     WHERE COALESCE(l->>'depositoId', '') <> ''
       AND NOT EXISTS (SELECT 1 FROM depositos i WHERE i.id = x.l->>'depositoId' AND i.empresa_id = x.empresa_id)
    UNION ALL
    SELECT 'plantilla de trabajo ' || trabajo_id || ': dosis inválida' FROM _pla WHERE pg_temp.num(p->'dosis') = 'NaN'
    UNION ALL
    SELECT 'plantilla de trabajo ' || trabajo_id || ': insumo inexistente ' || (p->>'insumoId') FROM _pla x
     WHERE COALESCE(p->>'insumoId', '') <> ''
       AND NOT EXISTS (SELECT 1 FROM insumos i WHERE i.id = x.p->>'insumoId' AND i.empresa_id = x.empresa_id)
    UNION ALL
    SELECT 'plantilla de trabajo ' || trabajo_id || ': depósito inexistente ' || (p->>'depositoId') FROM _pla x
     WHERE COALESCE(p->>'depositoId', '') <> ''
       AND NOT EXISTS (SELECT 1 FROM depositos i WHERE i.id = x.p->>'depositoId' AND i.empresa_id = x.empresa_id)
    UNION ALL
    SELECT 'depósito ' || id || ': sin nombre' FROM depositos WHERE COALESCE(btrim(datos->>'nombre'), '') = ''
    UNION ALL
    SELECT 'depósito ' || id || ': clase "' || (datos->>'clase') || '"' FROM depositos
     WHERE COALESCE(datos->>'clase', '') NOT IN ('', 'insumos', 'granos')
    UNION ALL
    SELECT 'depósito ' || id || ': campo inexistente ' || (datos->>'campoId') FROM depositos x
     WHERE COALESCE(datos->>'campoId', '') <> '' AND NOT EXISTS (SELECT 1 FROM campos c WHERE c.id = x.datos->>'campoId')
    UNION ALL
    SELECT 'depósito ' || id || ': especie inexistente ' || (datos->>'especieId') FROM depositos x
     WHERE COALESCE(datos->>'especieId', '') <> '' AND NOT EXISTS (SELECT 1 FROM especies e WHERE e.id = x.datos->>'especieId')
    UNION ALL
    SELECT 'depósito ' || id || ': activo "' || (datos->>'activo') || '"' FROM depositos
     WHERE jsonb_typeof(datos->'activo') NOT IN ('boolean', 'null')
  LOOP
    problemas := problemas || r.p;
  END LOOP;
  IF array_length(problemas, 1) > 0 THEN
    RAISE EXCEPTION E'Migración 022 cancelada, no se cambió nada. Datos a revisar:\n%', array_to_string(problemas[1:50], E'\n');
  END IF;
END $$;

-- ── 1. OT: destinos, líneas, cambios de cultivo y plantilla ──────────────────

-- Un lote (o unidad de negocio) dentro de una labor de la OT.
-- lote_id sin FK: es un lote de pa-core o 'UN:<campoId>' (unidad de negocio), y
-- "Cargar datos" del Plan de Uso borra y recrea los lotes de la empresa.
CREATE TABLE ot_destinos (
    id                       TEXT NOT NULL,
    empresa_id               TEXT NOT NULL REFERENCES empresas(id) ON DELETE CASCADE,
    trabajo_id               TEXT NOT NULL,
    orden                    INT  NOT NULL,
    lote_id                  TEXT,
    campo_id                 TEXT,
    cultivo                  TEXT,
    ha                       NUMERIC,
    ha_real                  NUMERIC,
    obs                      TEXT,
    estado_lote              TEXT NOT NULL DEFAULT 'Pendiente' CHECK (estado_lote IN ('Pendiente','Aplicado')),
    fecha_aplic_real         DATE,
    tanda_id                 TEXT,
    cultivo_mantenido        TEXT,
    cultivo_mantenido_fecha  DATE,
    cultivo_mantenido_ahora  TEXT,
    geo_ot                   JSONB,  -- polígono propio de la OT {ring:[[lng,lat],...]}, como lotes.geo
    PRIMARY KEY (trabajo_id, empresa_id, id),
    CONSTRAINT ot_destinos_trabajo_fk FOREIGN KEY (trabajo_id, empresa_id)
        REFERENCES ot_trabajos(id, empresa_id) ON DELETE CASCADE,
    CONSTRAINT ot_destinos_campo_fk FOREIGN KEY (campo_id) REFERENCES campos(id) ON DELETE RESTRICT
);
CREATE INDEX idx_ot_destinos_empresa ON ot_destinos(empresa_id, campo_id);
CREATE INDEX idx_ot_destinos_lote    ON ot_destinos(empresa_id, lote_id);

-- Línea de insumo de un destino: lo planificado (dosis) y lo registrado al aplicar.
CREATE TABLE ot_destino_lineas (
    empresa_id   TEXT NOT NULL REFERENCES empresas(id) ON DELETE CASCADE,
    trabajo_id   TEXT NOT NULL,
    destino_id   TEXT NOT NULL,
    orden        INT  NOT NULL,
    insumo_id    TEXT,
    deposito_id  TEXT,
    dosis        NUMERIC,
    dosis_real   NUMERIC,
    entregada    NUMERIC,
    usado        NUMERIC,
    dev_stock    NUMERIC,
    dev_baja     NUMERIC,
    PRIMARY KEY (trabajo_id, empresa_id, destino_id, orden),
    CONSTRAINT ot_destino_lineas_destino_fk FOREIGN KEY (trabajo_id, empresa_id, destino_id)
        REFERENCES ot_destinos(trabajo_id, empresa_id, id) ON DELETE CASCADE,
    CONSTRAINT ot_destino_lineas_insumo_fk FOREIGN KEY (insumo_id, empresa_id)
        REFERENCES insumos(id, empresa_id) ON DELETE RESTRICT,
    CONSTRAINT ot_destino_lineas_deposito_fk FOREIGN KEY (deposito_id, empresa_id)
        REFERENCES depositos(id, empresa_id) ON DELETE RESTRICT
);
CREATE INDEX idx_ot_destino_lineas_insumo   ON ot_destino_lineas(empresa_id, insumo_id);
CREATE INDEX idx_ot_destino_lineas_deposito ON ot_destino_lineas(empresa_id, deposito_id);

-- Historial de cambios de cultivo de un destino ("pasó de Girasol a Maíz").
CREATE TABLE ot_destino_cambios_cultivo (
    empresa_id    TEXT NOT NULL REFERENCES empresas(id) ON DELETE CASCADE,
    trabajo_id    TEXT NOT NULL,
    destino_id    TEXT NOT NULL,
    orden         INT  NOT NULL,
    cultivo_de    TEXT,
    cultivo_a     TEXT,
    fecha         DATE,
    PRIMARY KEY (trabajo_id, empresa_id, destino_id, orden),
    CONSTRAINT ot_destino_cambios_destino_fk FOREIGN KEY (trabajo_id, empresa_id, destino_id)
        REFERENCES ot_destinos(trabajo_id, empresa_id, id) ON DELETE CASCADE
);

-- Insumos sugeridos de la labor (dosis por ha), que se copian a cada lote.
CREATE TABLE ot_plantilla (
    empresa_id   TEXT NOT NULL REFERENCES empresas(id) ON DELETE CASCADE,
    trabajo_id   TEXT NOT NULL,
    orden        INT  NOT NULL,
    insumo_id    TEXT,
    dosis        NUMERIC,
    deposito_id  TEXT,
    PRIMARY KEY (trabajo_id, empresa_id, orden),
    CONSTRAINT ot_plantilla_trabajo_fk FOREIGN KEY (trabajo_id, empresa_id)
        REFERENCES ot_trabajos(id, empresa_id) ON DELETE CASCADE,
    CONSTRAINT ot_plantilla_insumo_fk FOREIGN KEY (insumo_id, empresa_id)
        REFERENCES insumos(id, empresa_id) ON DELETE RESTRICT,
    CONSTRAINT ot_plantilla_deposito_fk FOREIGN KEY (deposito_id, empresa_id)
        REFERENCES depositos(id, empresa_id) ON DELETE RESTRICT
);

INSERT INTO ot_destinos (id, empresa_id, trabajo_id, orden, lote_id, campo_id, cultivo, ha, ha_real, obs,
                         estado_lote, fecha_aplic_real, tanda_id, cultivo_mantenido, cultivo_mantenido_fecha,
                         cultivo_mantenido_ahora, geo_ot)
SELECT d->>'id', empresa_id, trabajo_id, orden, d->>'loteId', NULLIF(d->>'campoId', ''), d->>'cultivo',
       pg_temp.num(d->'ha'), pg_temp.num(d->'haReal'), d->>'obs',
       CASE WHEN d->>'estadoLote' = 'Aplicado' THEN 'Aplicado' ELSE 'Pendiente' END,
       pg_temp.fecha(d->>'fechaAplicReal'), d->>'tandaId', d->>'cultivoMantenido',
       pg_temp.fecha(d->>'cultivoMantenidoFecha'), d->>'cultivoMantenidoAhora',
       CASE WHEN jsonb_typeof(d->'geoOt') = 'object' THEN d->'geoOt' END
  FROM _dest;

INSERT INTO ot_destino_lineas (empresa_id, trabajo_id, destino_id, orden, insumo_id, deposito_id,
                               dosis, dosis_real, entregada, usado, dev_stock, dev_baja)
SELECT empresa_id, trabajo_id, destino_id, orden, NULLIF(l->>'insumoId', ''), NULLIF(l->>'depositoId', ''),
       pg_temp.num(l->'dosis'), pg_temp.num(l->'dosisReal'), pg_temp.num(l->'entregada'),
       pg_temp.num(l->'usado'), pg_temp.num(l->'devStock'), pg_temp.num(l->'devBaja')
  FROM _lin;

INSERT INTO ot_destino_cambios_cultivo (empresa_id, trabajo_id, destino_id, orden, cultivo_de, cultivo_a, fecha)
SELECT empresa_id, trabajo_id, destino_id, orden, c->>'de', c->>'a', pg_temp.fecha(c->>'fecha')
  FROM _cc;

INSERT INTO ot_plantilla (empresa_id, trabajo_id, orden, insumo_id, dosis, deposito_id)
SELECT empresa_id, trabajo_id, orden, NULLIF(p->>'insumoId', ''), pg_temp.num(p->'dosis'), NULLIF(p->>'depositoId', '')
  FROM _pla;

ALTER TABLE ot_trabajos DROP COLUMN destinos, DROP COLUMN plantilla;

-- ── 2. Depósitos: datos → columnas ───────────────────────────────────────────
ALTER TABLE depositos
    ADD COLUMN nombre     TEXT,
    ADD COLUMN clase      TEXT,
    ADD COLUMN campo_id   TEXT,
    ADD COLUMN especie_id TEXT,
    ADD COLUMN activo     BOOLEAN;

UPDATE depositos SET
    nombre     = btrim(datos->>'nombre'),
    clase      = COALESCE(NULLIF(datos->>'clase', ''), 'insumos'),
    campo_id   = NULLIF(datos->>'campoId', ''),
    especie_id = NULLIF(datos->>'especieId', ''),
    activo     = COALESCE((datos->>'activo')::boolean, true);

DROP INDEX uq_depositos_nombre_empresa;
ALTER TABLE depositos
    ALTER COLUMN nombre SET NOT NULL,
    ALTER COLUMN clase  SET NOT NULL,
    ALTER COLUMN clase  SET DEFAULT 'insumos',
    ALTER COLUMN activo SET NOT NULL,
    ALTER COLUMN activo SET DEFAULT true,
    ADD CONSTRAINT depositos_clase_check CHECK (clase IN ('insumos','granos')),
    ADD CONSTRAINT depositos_campo_fk   FOREIGN KEY (campo_id)   REFERENCES campos(id)   ON DELETE RESTRICT,
    ADD CONSTRAINT depositos_especie_fk FOREIGN KEY (especie_id) REFERENCES especies(id) ON DELETE RESTRICT,
    DROP COLUMN datos;
CREATE UNIQUE INDEX uq_depositos_nombre_empresa ON depositos (empresa_id, trim(lower(nombre)));
CREATE INDEX idx_depositos_campo ON depositos(campo_id);

COMMIT;
