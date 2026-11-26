-- Migración 025: herramientas contratadas por cliente
--
-- Puntal Agro le vende a cada cliente el acceso a determinadas herramientas
-- (tableros propios). cliente_herramientas guarda esa lista; solo la edita el
-- admin_general (Administración → cliente). Efecto:
--  - El admin_cliente (y quien tenga nivel 'administrar' en una empresa) ve en
--    las empresas de ese cliente solo las herramientas contratadas.
--  - Al asignar permisos en una empresa solo se ofrecen las herramientas
--    contratadas por su cliente; un permiso viejo que incluya una herramienta
--    que el cliente ya no tiene queda sin efecto para esa herramienta (si se
--    vuelve a contratar, el permiso vuelve a valer sin tocarlo).
--  - admin_general sigue viendo todo.
-- Las herramientas externas e internas no se contratan (siguen como hoy).
--
-- Para los datos existentes no cambia nada: cada cliente queda con TODAS las
-- herramientas propias asignables de hoy. Se puede volver a correr.

BEGIN;

CREATE TABLE IF NOT EXISTS cliente_herramientas (
    cliente_id      TEXT NOT NULL REFERENCES clientes(id) ON DELETE CASCADE,
    herramienta_id  TEXT NOT NULL REFERENCES herramientas(id) ON DELETE CASCADE,
    PRIMARY KEY (cliente_id, herramienta_id)
);

INSERT INTO cliente_herramientas (cliente_id, herramienta_id)
SELECT c.id, h.id
  FROM clientes c CROSS JOIN herramientas h
 WHERE h.tipo = 'propia' AND h.asignable = true
   AND NOT EXISTS (SELECT 1 FROM cliente_herramientas x WHERE x.cliente_id = c.id)
ON CONFLICT DO NOTHING;

COMMIT;
