-- Migración 015: marca de OT registrada con "OT rápida" (labor ya realizada).
-- Se fija al crearla y no cambia; se muestra como etiqueta en el listado y en el Excel.
ALTER TABLE ordenes_trabajo ADD COLUMN rapida BOOLEAN NOT NULL DEFAULT false;
