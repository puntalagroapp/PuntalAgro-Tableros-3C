-- Migración 011: una Orden de Trabajo (un mismo número) puede agrupar varias
-- labores distintas ("sembrar y fertilizar en la misma orden"), cada una con
-- su propio contratista/tarifa/facturación y sus propios lotes. Hasta ahora
-- ordenes_trabajo modelaba 1 fila = 1 labor; pasa a ser solo la CABECERA
-- (num, fecha, campaña, estado agregado) y cada labor es una fila nueva en
-- ot_trabajos.
--
-- Migra los datos existentes sin tocar comprobantes: cada fila actual de
-- ordenes_trabajo se copia a ot_trabajos REUSANDO EL MISMO id, así que
-- comprobantes.ref_ot (que ya apunta a ese id) sigue siendo válido — solo se
-- le cambia el destino de la referencia y se renombra a ref_ot_trabajo.

CREATE TABLE ot_trabajos (
    id               TEXT NOT NULL,
    empresa_id       TEXT NOT NULL REFERENCES empresas(id) ON DELETE CASCADE,
    ot_id            TEXT NOT NULL,
    labor_tipo       TEXT CHECK (labor_tipo IN ('LP','LC')),
    labor_id         TEXT REFERENCES labores(id),
    subactividad     TEXT,
    tercero_id       TEXT,
    tarifa           NUMERIC(12,2),
    tarifa_moneda    TEXT NOT NULL DEFAULT 'ARS',
    monto_facturado  NUMERIC(12,2) NOT NULL DEFAULT 0,
    estado_fact      TEXT NOT NULL DEFAULT 'Sin facturar'
                         CHECK (estado_fact IN ('Sin facturar','Parcial','Facturado')),
    es_resiembra     BOOLEAN NOT NULL DEFAULT false,
    plantilla        JSONB NOT NULL DEFAULT '[]',
    destinos         JSONB NOT NULL DEFAULT '[]',
    orden            INT NOT NULL DEFAULT 1,
    PRIMARY KEY (id, empresa_id),
    FOREIGN KEY (ot_id, empresa_id) REFERENCES ordenes_trabajo(id, empresa_id) ON DELETE CASCADE,
    FOREIGN KEY (tercero_id, empresa_id) REFERENCES terceros(id, empresa_id) ON DELETE RESTRICT
);
CREATE INDEX idx_ot_trabajos_ot ON ot_trabajos(ot_id, empresa_id);

-- Vuelca cada OT existente a su propio (único, por ahora) trabajo.
INSERT INTO ot_trabajos (id, empresa_id, ot_id, labor_tipo, labor_id, subactividad,
                          tercero_id, tarifa, tarifa_moneda, monto_facturado,
                          estado_fact, plantilla, destinos, orden)
SELECT id, empresa_id, id, labor_tipo, labor_id, subactividad,
       tercero_id, tarifa, tarifa_moneda, monto_facturado,
       estado_fact, plantilla, destinos, 1
FROM ordenes_trabajo;

-- comprobantes.ref_ot pasa a apuntar a ot_trabajos (mismos valores, mismo id).
-- RESTRICT y no SET NULL: con una FK compuesta (ref_ot_trabajo, empresa_id),
-- Postgres pone en NULL LAS DOS columnas al hacer SET NULL — y empresa_id no
-- puede ser NULL acá (ni tendría sentido). Además es la regla correcta: una
-- vez que una labor generó consumo real (el comprobante existe), no debería
-- poder borrarse la orden que lo originó.
ALTER TABLE comprobantes DROP CONSTRAINT comprobantes_ref_ot_empresa_id_fkey;
ALTER TABLE comprobantes RENAME COLUMN ref_ot TO ref_ot_trabajo;
ALTER TABLE comprobantes
    ADD CONSTRAINT comprobantes_ref_ot_trabajo_empresa_id_fkey
    FOREIGN KEY (ref_ot_trabajo, empresa_id) REFERENCES ot_trabajos(id, empresa_id) ON DELETE RESTRICT;

-- ordenes_trabajo queda solo como cabecera.
ALTER TABLE ordenes_trabajo
    DROP COLUMN labor_tipo,
    DROP COLUMN labor_id,
    DROP COLUMN subactividad,
    DROP COLUMN tercero_id,
    DROP COLUMN tarifa,
    DROP COLUMN tarifa_moneda,
    DROP COLUMN monto_facturado,
    DROP COLUMN estado_fact,
    DROP COLUMN plantilla,
    DROP COLUMN destinos;
