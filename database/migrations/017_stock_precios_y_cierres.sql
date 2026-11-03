-- Migración 017: Stock del cliente (client-src/2026-10-30).
-- Precio y moneda por línea de movimiento (compras y stock inicial alimentan el
-- promedio ponderado móvil) y cierres de stock a una fecha.
ALTER TABLE movimientos ADD COLUMN IF NOT EXISTS precio NUMERIC(16,4);
ALTER TABLE movimientos ADD COLUMN IF NOT EXISTS moneda TEXT;

CREATE TABLE IF NOT EXISTS cierres_stock (
    id          TEXT NOT NULL,
    empresa_id  TEXT NOT NULL REFERENCES empresas(id) ON DELETE CASCADE,
    fecha       DATE NOT NULL,
    precios     JSONB NOT NULL DEFAULT '{}',
    comp_ids    TEXT[] NOT NULL DEFAULT '{}',
    creado_el   DATE,
    creado_por  TEXT,
    PRIMARY KEY (id, empresa_id)
);
CREATE INDEX IF NOT EXISTS idx_cierres_stock_empresa ON cierres_stock(empresa_id, fecha);
