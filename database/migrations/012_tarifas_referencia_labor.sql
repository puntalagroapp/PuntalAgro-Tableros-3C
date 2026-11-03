-- Migración 012: tarifa de referencia de cada labor propia, por campaña.
-- Es solo una SUGERENCIA para autocompletar al emitir una OT — el valor
-- real queda guardado en ot_trabajos.tarifa/tarifa_moneda de cada OT ya
-- emitida (editable ahí). No incluye campo: una OT puede tener destinos
-- en varios campos, la tarifa es una por OT.
CREATE TABLE tarifas_referencia_labor (
    empresa_id   TEXT NOT NULL REFERENCES empresas(id) ON DELETE CASCADE,
    labor_id     TEXT NOT NULL REFERENCES labores(id),
    campania_id  TEXT NOT NULL REFERENCES campanias(id),
    valor        NUMERIC(12,2) NOT NULL DEFAULT 0,
    moneda       TEXT NOT NULL DEFAULT 'ARS',
    PRIMARY KEY (empresa_id, labor_id, campania_id)
);

-- Estado de pago al contratista: faltaba en ot_trabajos (se agregó
-- estado_fact/monto_facturado en la migración 011, pero no esto). Lo
-- necesita el reporte de labores/contratistas (facturado/pagado/adeudado).
ALTER TABLE ot_trabajos ADD COLUMN estado_pago TEXT NOT NULL DEFAULT 'No';
ALTER TABLE ot_trabajos ADD COLUMN monto_pagado NUMERIC(12,2) NOT NULL DEFAULT 0;
