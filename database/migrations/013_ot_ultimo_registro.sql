-- Migración 013: borrador de lo realizado de una OT.
-- Al "Volver a pendiente" se guarda lo que se había registrado (fechas,
-- superficies reales, cantidades y movimientos) para precargarlo la próxima vez
-- y, si no se cambia nada, restaurarlo exactamente igual.
ALTER TABLE ordenes_trabajo ADD COLUMN ultimo_registro JSONB;
