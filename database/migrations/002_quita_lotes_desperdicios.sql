-- Migración 002: la estructura/desperdicios deja de ser un lote y pasa a
-- calcularse (total del campo − Σ lotes). Ver tablero_uso_suelo.html, entrega del
-- cliente 2026-09-24 (estructuraDeCampo).
--
-- Corresponde a la rama feature/migracion-tablero-uso-suelo-2026-09-25.
-- Correr contra la base de producción ANTES de desplegar ese código: si los lotes
-- "Desperdicios" siguieran cargados, su superficie contaría dos veces (dentro de
-- "Total lotes" y de nuevo en la estructura calculada por resta).
--
-- Solo borra lotes con ambiente DESP y SIN actividades asociadas, y el ambiente
-- DESP del catálogo si ya no lo usa ningún lote. Si el paso 0 devuelve filas,
-- NO correr el resto: revisar a mano qué se cargó ahí.
--
-- Paso 0 (verificación previa, ver qué se va a tocar):
--   SELECT l.id, l.empresa_id, l.nombre, l.ha,
--          (SELECT count(*) FROM actividades a WHERE a.lote_id = l.id) AS actividades
--     FROM lotes l WHERE upper(trim(l.ambiente)) = 'DESP';
--   -- todas las filas deberían tener actividades = 0

BEGIN;

DELETE FROM lotes l
 WHERE upper(trim(l.ambiente)) = 'DESP'
   AND NOT EXISTS (SELECT 1 FROM actividades a WHERE a.lote_id = l.id);

DELETE FROM ambientes a
 WHERE upper(trim(a.datos->>'codigo')) = 'DESP'
   AND NOT EXISTS (SELECT 1 FROM lotes l
                    WHERE l.empresa_id = a.empresa_id
                      AND upper(trim(l.ambiente)) = 'DESP');

COMMIT;
