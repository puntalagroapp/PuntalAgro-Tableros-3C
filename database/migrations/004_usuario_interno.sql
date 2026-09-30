-- Migración 004: marca qué usuarios son empleados de Puntal Agro.
--
-- Dato informativo/de clasificación, independiente del rol y de
-- herramientas_internas (ver comentario en init.sql). Aditivo: no borra ni
-- pisa ninguna fila existente; todos los usuarios actuales quedan en false.

BEGIN;

ALTER TABLE usuarios
  ADD COLUMN IF NOT EXISTS usuario_interno BOOLEAN NOT NULL DEFAULT false;

COMMIT;
