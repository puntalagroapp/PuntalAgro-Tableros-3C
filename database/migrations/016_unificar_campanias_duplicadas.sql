-- Migración 016: une campañas duplicadas por nombre equivalente.
-- La carga desde Excel del Plan de uso creaba '25-26' aunque ya existiera
-- '25/26' (camp_2526). Se agrupan por nombre normalizado ('25-26' = '25/26' =
-- '2025/2026'); en cada grupo queda la de menor orden (la original), se le
-- pasan todas las referencias y se borran las demás. Si no hay duplicados no
-- hace nada, así que se puede correr más de una vez.
BEGIN;

CREATE TEMP TABLE _camp_norm ON COMMIT DROP AS
SELECT id, orden, activa,
       CASE WHEN m IS NOT NULL THEN right(m[1], 2) || '/' || right(m[2], 2)
            ELSE lower(trim(nombre)) END AS clave
  FROM (SELECT id, nombre, orden, activa,
               regexp_match(lower(trim(nombre)), '^(\d{2}|\d{4})\s*[-/_ ]?\s*(\d{2}|\d{4})$') AS m
          FROM campanias) x;

CREATE TEMP TABLE _camp_map ON COMMIT DROP AS
SELECT d.id AS dup_id, k.id AS keep_id, d.activa AS dup_activa
  FROM _camp_norm d
  JOIN LATERAL (SELECT id FROM _camp_norm k
                 WHERE k.clave = d.clave ORDER BY k.orden, k.id LIMIT 1) k ON true
 WHERE k.id <> d.id;

UPDATE actividades     t SET campania_id = m.keep_id FROM _camp_map m WHERE t.campania_id = m.dup_id;
UPDATE comprobantes    t SET campania_id = m.keep_id FROM _camp_map m WHERE t.campania_id = m.dup_id;
UPDATE ordenes_trabajo t SET campania_id = m.keep_id FROM _camp_map m WHERE t.campania_id = m.dup_id;

-- Tarifas de referencia: si la original ya tiene tarifa para esa labor, gana la original.
DELETE FROM tarifas_referencia_labor t USING _camp_map m
 WHERE t.campania_id = m.dup_id
   AND EXISTS (SELECT 1 FROM tarifas_referencia_labor o
                WHERE o.empresa_id = t.empresa_id AND o.labor_id = t.labor_id AND o.campania_id = m.keep_id);
UPDATE tarifas_referencia_labor t SET campania_id = m.keep_id FROM _camp_map m WHERE t.campania_id = m.dup_id;

-- Si la activa era una duplicada, la activa pasa a ser la original.
UPDATE campanias c SET activa = true FROM _camp_map m WHERE c.id = m.keep_id AND m.dup_activa;

DELETE FROM campanias c USING _camp_map m WHERE c.id = m.dup_id;

COMMIT;
