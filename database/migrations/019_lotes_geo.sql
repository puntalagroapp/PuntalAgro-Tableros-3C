-- Migración 019: mapa de los lotes (polígonos del KML/KMZ que se carga en el
-- Plan de Uso del Suelo; también los usa Registro de Labores e Insumos para los
-- mapas de las OT). geo = [{id, nombre, ha, ring:[[lat,lng],…]}]; NULL = sin mapa.
ALTER TABLE lotes ADD COLUMN IF NOT EXISTS geo JSONB;
