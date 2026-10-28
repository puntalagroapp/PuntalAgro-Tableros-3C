-- Migración 008: persiste en la base los datos reales de
-- calendario_actividades.html (hoy viven solo en localStorage del navegador:
-- se pierden al limpiar el sitio y no se comparten entre usuarios de la
-- misma empresa ni entre dispositivos).

-- Config por empresa: roles elegidos y actividades elegidas (listas variables,
-- de ahí JSONB) para armar el calendario de esa empresa.
CREATE TABLE calendario_actividades_config (
    empresa_id           TEXT PRIMARY KEY REFERENCES empresas(id) ON DELETE CASCADE,
    roles_elegidos        JSONB NOT NULL DEFAULT '[]',
    actividades_elegidas  JSONB NOT NULL DEFAULT '[]'
);

-- Tareas marcadas como "hecha" por empresa y mes: una fila = una marca.
CREATE TABLE calendario_actividades_hechas (
    empresa_id   TEXT NOT NULL REFERENCES empresas(id) ON DELETE CASCADE,
    anio_mes     TEXT NOT NULL,   -- 'YYYY-MM'
    tarea_id     TEXT NOT NULL,
    PRIMARY KEY (empresa_id, anio_mes, tarea_id)
);
CREATE INDEX idx_calendario_hechas_empresa_mes ON calendario_actividades_hechas(empresa_id, anio_mes);
