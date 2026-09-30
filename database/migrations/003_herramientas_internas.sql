-- Migración 003: acceso a "Herramientas Puntal" (biblioteca interna del equipo
-- Puntal) por usuario, y nuevo tipo 'interna' en la tabla herramientas.
--
-- Corresponde a la rama que agrega la sección "Herramientas Puntal" al inicio
-- con permiso propio (usuarios.herramientas_internas), separado del resto de los
-- permisos porque no depende de empresa.
--
-- Todo es aditivo: no borra ni pisa ninguna fila existente.

BEGIN;

ALTER TABLE usuarios
  ADD COLUMN IF NOT EXISTS herramientas_internas BOOLEAN NOT NULL DEFAULT false;

ALTER TABLE herramientas DROP CONSTRAINT IF EXISTS herramientas_tipo_check;
ALTER TABLE herramientas
  ADD CONSTRAINT herramientas_tipo_check CHECK (tipo IN ('propia','externa','interna'));

ALTER TABLE herramientas ADD COLUMN IF NOT EXISTS archivo_nombre TEXT;

COMMIT;
