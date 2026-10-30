-- Migración 010: "Maestros / Padrones" pasa a ser una herramienta asignable
-- más, igual que Plan de Uso del Suelo, para poder habilitarla/deshabilitarla
-- por usuario en Usuarios y permisos (antes la veía cualquiera con acceso a
-- la empresa, sin importar sus permisos de herramientas).
INSERT INTO herramientas (id, nombre, descripcion, tipo, url, dominio, asignable)
VALUES (
    'maestros',
    'Maestros / Padrones',
    'Catálogos base que consumen los demás módulos: proveedores y clientes, choferes, depósitos y acopios, labores, cultivos, especies y unidades.',
    'propia',
    'maestros.html',
    'Configuración',
    true
)
ON CONFLICT (id) DO NOTHING;
