-- =============================================================================
-- Migración 003: normalizar OTs/movimientos para tablero_insumos_ot.
--
-- Retoma la migración cancelada el 2026-07-03 (ver decision_tablas_independientes
-- _por_tablero en la memoria del proyecto): el diseño anterior guardaba todo el
-- estado operativo de TODAS las empresas en un único blob JSONB compartido
-- (tabla `tableros`, clave fija 'puntalagro_insumos_v4'), sin aislamiento por
-- fila. Esta migración conecta `ordenes_trabajo`/`movimientos` (ya existían,
-- nunca se usaron) a un modelo real, agrega `comprobantes` (cabecera separada
-- de las líneas de movimiento) y saca del blob lo último que quedaba (config
-- de tipo de cambio) a `config_operativa`.
--
-- No hay datos reales cargados en producción para este tablero todavía (el
-- blob nunca se conectó a ningún endpoint) — no hace falta migrar datos.
--
-- Ejecutar: docker exec -i pa_postgres_db psql -U postgres -d puntalagro_tableros_3C
--           < database/migrations/003_ordenes_trabajo_normalizadas.sql
-- =============================================================================

BEGIN;

-- ── Comprobantes (cabecera de movimiento, compartida por N líneas) ──────────
CREATE TABLE IF NOT EXISTS comprobantes (
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
CREATE INDEX IF NOT EXISTS idx_comprobantes_empresa ON comprobantes(empresa_id, campania_id);

-- ── Movimientos: sacar columnas denormalizadas, agregar comprobante_id ──────
ALTER TABLE movimientos DROP CONSTRAINT IF EXISTS movimientos_ot_id_empresa_id_fkey;
ALTER TABLE movimientos
    DROP COLUMN IF EXISTS fecha,
    DROP COLUMN IF EXISTS tipo,
    DROP COLUMN IF EXISTS comprobante_tipo,
    DROP COLUMN IF EXISTS comprobante_nro,
    DROP COLUMN IF EXISTS obs,
    DROP COLUMN IF EXISTS ot_id;
ALTER TABLE movimientos
    ADD COLUMN IF NOT EXISTS comprobante_id TEXT,
    ADD COLUMN IF NOT EXISTS ref_destino_id TEXT;
-- NOT NULL se agrega en un paso aparte porque la tabla puede tener filas viejas
-- de pruebas sin comprobante_id; si la tabla está vacía esto es inmediato.
DO $$
DECLARE n int;
BEGIN
  SELECT COUNT(*) INTO n FROM movimientos WHERE comprobante_id IS NULL;
  IF n > 0 THEN
    RAISE EXCEPTION 'Hay % fila(s) en movimientos sin comprobante_id (datos de prueba viejos). Backup/limpiá esa tabla antes de continuar: SELECT * FROM movimientos WHERE comprobante_id IS NULL;', n;
  END IF;
END $$;
ALTER TABLE movimientos ALTER COLUMN comprobante_id SET NOT NULL;
ALTER TABLE movimientos DROP CONSTRAINT IF EXISTS movimientos_comprobante_id_empresa_id_fkey;
ALTER TABLE movimientos
    ADD CONSTRAINT movimientos_comprobante_id_empresa_id_fkey
    FOREIGN KEY (comprobante_id, empresa_id) REFERENCES comprobantes(id, empresa_id) ON DELETE CASCADE;
CREATE INDEX IF NOT EXISTS idx_movimientos_comprobante ON movimientos(comprobante_id, empresa_id);

-- ── Ordenes de trabajo: labor_tipo (cabecera) + único num por empresa ───────
ALTER TABLE ordenes_trabajo ADD COLUMN IF NOT EXISTS labor_tipo TEXT CHECK (labor_tipo IN ('LP','LC'));
DO $$
DECLARE n int;
BEGIN
  SELECT COUNT(*) INTO n FROM (SELECT empresa_id, num FROM ordenes_trabajo GROUP BY 1,2 HAVING COUNT(*)>1) x;
  IF n > 0 THEN RAISE EXCEPTION 'Hay % num(s) de OT duplicados por empresa. Resolvé antes de continuar.', n; END IF;
END $$;
CREATE UNIQUE INDEX IF NOT EXISTS uq_ordenes_trabajo_num_empresa ON ordenes_trabajo(empresa_id, num);

-- ── Contador atómico de num de OT (evita la carrera de state.nextOt++) ──────
CREATE TABLE IF NOT EXISTS contadores_ot (
    empresa_id TEXT PRIMARY KEY REFERENCES empresas(id) ON DELETE CASCADE,
    siguiente  INTEGER NOT NULL DEFAULT 1
);

-- ── Config operativa por empresa (tipo de cambio) — último resto del blob ───
CREATE TABLE IF NOT EXISTS config_operativa (
    empresa_id  TEXT PRIMARY KEY REFERENCES empresas(id) ON DELETE CASCADE,
    tc_usd      NUMERIC(12,2) DEFAULT 1000,
    tc_mensual  JSONB NOT NULL DEFAULT '{}',
    tc_apertura NUMERIC(12,2) DEFAULT 0,
    tc_cierre   NUMERIC(12,2) DEFAULT 0
);

COMMIT;
