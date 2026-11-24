-- Migración 024: un usuario puede trabajar con varios clientes
--
-- Hasta ahora cada cuenta pertenecía a un solo cliente (usuarios.cliente_id) y
-- un admin_cliente administraba solo ese cliente. Desde esta migración:
--  - usuario_clientes: los clientes que administra cada persona (rol
--    admin_cliente). En cada uno tiene acceso pleno, como antes con su cliente.
--  - permisos (sin cambios en la tabla): permisos empresa por empresa, que ahora
--    pueden ser de clientes distintos y también puede tenerlos un admin_cliente
--    en empresas de clientes que no administra.
--  - usuarios.cliente_id queda como el cliente al que pertenece la cuenta (quien
--    la dio de alta). Puede ser NULL para el personal de Puntal Agro.
-- Las cuentas que trabajan con más de un cliente solo las administra el
-- admin_general (lo valida el servidor).
--
-- Para los datos existentes no cambia nada: cada admin_cliente queda
-- administrando su cliente de siempre. Se puede volver a correr.

BEGIN;

CREATE TABLE IF NOT EXISTS usuario_clientes (
    usuario_id  TEXT NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,
    cliente_id  TEXT NOT NULL REFERENCES clientes(id) ON DELETE CASCADE,
    PRIMARY KEY (usuario_id, cliente_id)
);
CREATE INDEX IF NOT EXISTS idx_usuario_clientes_cliente ON usuario_clientes (cliente_id);

INSERT INTO usuario_clientes (usuario_id, cliente_id)
SELECT id, cliente_id FROM usuarios
 WHERE rol = 'admin_cliente' AND cliente_id IS NOT NULL
ON CONFLICT DO NOTHING;

COMMIT;
