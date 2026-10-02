-- Migración 006: descripción para los grupos (carpetas) de herramientas.
--
-- Para que la tarjeta de un grupo tenga el mismo bloque "+ Detalle" que el
-- resto de las tarjetas. Aditivo: nullable, los grupos existentes quedan sin
-- descripción (se ve un detalle vacío hasta que se cargue una).

BEGIN;

ALTER TABLE grupos_herramientas ADD COLUMN IF NOT EXISTS descripcion TEXT;

COMMIT;
