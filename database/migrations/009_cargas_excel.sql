-- Migración 009: auditoría de la "Carga de datos desde Excel" (cargar_datos.html).
-- Es una operación destructiva e irreversible (reemplaza lo que la empresa
-- tenga cargado en las partes importadas), así que cada ejecución queda
-- registrada: quién, cuándo, para qué empresa, qué partes y el resumen que
-- vio el usuario en el paso de Revisión antes de confirmar.
CREATE TABLE cargas_excel (
    id          TEXT PRIMARY KEY,
    empresa_id  TEXT NOT NULL REFERENCES empresas(id) ON DELETE CASCADE,
    usuario_id  TEXT NOT NULL REFERENCES usuarios(id),
    fecha       TIMESTAMPTZ NOT NULL DEFAULT now(),
    partes      JSONB NOT NULL DEFAULT '{}',   -- {plan:true/false, reg:true/false}
    resumen     JSONB NOT NULL DEFAULT '[]',   -- informe.resumen tal como lo vio el usuario
    avisos      JSONB NOT NULL DEFAULT '[]'    -- informe.avisos tal como lo vio el usuario
);
CREATE INDEX idx_cargas_excel_empresa ON cargas_excel(empresa_id, fecha DESC);
