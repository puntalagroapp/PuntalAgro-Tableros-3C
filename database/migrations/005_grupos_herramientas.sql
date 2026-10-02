-- Migración 005: agrupamiento (un solo nivel) de herramientas en "carpetas".
--
-- Por ahora solo se usa para Herramientas Puntal (tipo='interna'), pero el
-- nombre es genérico a propósito: el cliente podría pedir lo mismo para
-- herramientas externas más adelante, y esta misma tabla ya le serviría sin
-- otra migración. Todo aditivo: las herramientas existentes quedan sin grupo
-- (grupo_id NULL), visibles igual que hoy, sin romper nada.

BEGIN;

CREATE TABLE IF NOT EXISTS grupos_herramientas (
    id     TEXT PRIMARY KEY,
    nombre TEXT NOT NULL,
    orden  INTEGER NOT NULL DEFAULT 0,
    activo BOOLEAN NOT NULL DEFAULT true
);

ALTER TABLE herramientas
  ADD COLUMN IF NOT EXISTS grupo_id TEXT REFERENCES grupos_herramientas(id) ON DELETE SET NULL;

COMMIT;
