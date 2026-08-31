-- Migración 001: normaliza tc_mensual y completa la facturación de contratistas
-- Corresponde a los commits f6c25cd (tc_mensual) y f0974d3 (4 fixes de guardado
-- en tablero_insumos_ot.html) de PuntalAgro-Tableros-3C.
--
-- Correr contra la base de producción ANTES de desplegar ese código.
-- Todo es aditivo: no borra ni pisa ninguna fila existente, salvo la columna
-- JSON tc_mensual (que en la práctica está siempre vacía — ver verificación
-- de abajo — porque el guardado nunca llegó a persistirla en ningún entorno).
--
-- Verificación previa recomendada (debería devolver 0 filas):
--   SELECT empresa_id, tc_mensual FROM config_operativa
--    WHERE tc_mensual IS NOT NULL AND tc_mensual != '{}'::jsonb;

BEGIN;

-- 1) Tipo de cambio mensual: de un JSON por empresa a una fila por mes.
CREATE TABLE IF NOT EXISTS tipo_cambio_mensual (
    empresa_id TEXT NOT NULL REFERENCES empresas(id) ON DELETE CASCADE,
    anio_mes   TEXT NOT NULL,  -- 'YYYY-MM'
    valor      NUMERIC(12,2) NOT NULL,
    PRIMARY KEY (empresa_id, anio_mes)
);
CREATE INDEX IF NOT EXISTS idx_tc_mensual_empresa ON tipo_cambio_mensual(empresa_id);

ALTER TABLE config_operativa DROP COLUMN IF EXISTS tc_mensual;

-- 2) Facturación de contratistas: columnas que faltaban en ordenes_trabajo.
ALTER TABLE ordenes_trabajo
  ADD COLUMN IF NOT EXISTS tarifa_moneda TEXT NOT NULL DEFAULT 'ARS',
  ADD COLUMN IF NOT EXISTS monto_facturado NUMERIC(12,2) NOT NULL DEFAULT 0;

COMMIT;
