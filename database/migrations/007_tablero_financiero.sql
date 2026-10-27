-- Migración 007: alta de la herramienta "Plan y Seguimiento Financiero"
-- (tablero_financiero.html) en el catálogo de herramientas propias, para
-- que se pueda habilitar por permiso igual que el resto de Gestión.
INSERT INTO herramientas (id, nombre, descripcion, tipo, url, dominio, asignable)
VALUES (
    'tablero_financiero',
    'Plan y Seguimiento Financiero',
    'Presupuesto financiero de la empresa y seguimiento de lo real contra lo planificado: ingresos, egresos y saldos por período.',
    'propia',
    'tablero_financiero.html',
    'Finanzas',
    true
)
ON CONFLICT (id) DO NOTHING;
