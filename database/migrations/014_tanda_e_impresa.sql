-- Migración 014: tanda de aplicación en el comprobante y marca de OT impresa.
-- ref_tanda: agrupa los comprobantes que generó un mismo registro de lo realizado
-- (para corregir o restaurar esa tanda). impresa: la OT ya se imprimió; al
-- editarla se avisa que puede estar en el campo.
ALTER TABLE comprobantes ADD COLUMN ref_tanda TEXT;
ALTER TABLE ordenes_trabajo ADD COLUMN impresa BOOLEAN NOT NULL DEFAULT false;
