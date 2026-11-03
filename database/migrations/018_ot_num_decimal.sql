-- Migración 018: el número de OT puede tener decimales (sub-OT del Excel del
-- cliente, p. ej. 38.1). La numeración nueva sigue siendo entera (contadores_ot).
ALTER TABLE ordenes_trabajo ALTER COLUMN num TYPE NUMERIC;
ALTER TABLE comprobantes ALTER COLUMN ref_ot_num TYPE NUMERIC;
