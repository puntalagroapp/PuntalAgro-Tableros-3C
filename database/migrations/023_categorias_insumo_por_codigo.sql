-- Migración 023: la categoría de cada insumo (insumos.datos->>'tipo') pasa a ser
-- el CÓDIGO del catálogo categorias_insumo (HERB, SEM, ...), que es lo que usa
-- Maestros. "Cargar datos" (Excel de Labores e Insumos) guardaba nombres sueltos
-- ("Herbicida", "Semilla", "Combustible"...) y por eso Maestros no mostraba esos
-- insumos. Se agrega la categoría "Combustibles y lubricantes" (COMB).
--
-- Acepta el nombre en singular, en plural o el nombre completo de la categoría,
-- sin importar mayúsculas. Si queda algún insumo con una categoría que no se
-- reconoce, la migración aborta sin cambiar nada y la lista.

BEGIN;

INSERT INTO categorias_insumo (id, codigo, label, base, fito, subcat, activo)
VALUES ('cat_comb', 'COMB', 'Combustibles y lubricantes', true, false, false, true)
ON CONFLICT (id) DO NOTHING;

CREATE TEMP TABLE _equiv (nombre TEXT PRIMARY KEY, codigo TEXT NOT NULL) ON COMMIT DROP;
INSERT INTO _equiv (nombre, codigo) VALUES
    ('semilla', 'SEM'), ('semillas', 'SEM'),
    ('curasemilla', 'CURA'), ('curasemillas', 'CURA'), ('inoculante', 'CURA'), ('inoculantes', 'CURA'),
    ('curasemillas/inoculantes', 'CURA'),
    ('herbicida', 'HERB'), ('herbicidas', 'HERB'),
    ('insecticida', 'INSE'), ('insecticidas', 'INSE'),
    ('fungicida', 'FUNG'), ('fungicidas', 'FUNG'),
    ('coadyuvante', 'COAD'), ('coadyuvantes', 'COAD'), ('coadyuvantes/correctores', 'COAD'),
    ('fertilizante', 'FERT'), ('fertilizantes', 'FERT'),
    ('combustible', 'COMB'), ('combustibles', 'COMB'),
    ('otro', 'OTRO'), ('otros', 'OTRO'), ('varios', 'OTRO');
-- Nombres completos y códigos del catálogo (incluye categorías agregadas a mano).
INSERT INTO _equiv (nombre, codigo)
SELECT lower(btrim(label)), codigo FROM categorias_insumo ON CONFLICT (nombre) DO NOTHING;
INSERT INTO _equiv (nombre, codigo)
SELECT lower(btrim(codigo)), codigo FROM categorias_insumo ON CONFLICT (nombre) DO NOTHING;

DO $$
DECLARE sin_equiv text;
BEGIN
  SELECT string_agg(DISTINCT COALESCE(i.datos->>'tipo', '(vacía)'), ', ') INTO sin_equiv
    FROM insumos i
   WHERE NOT EXISTS (SELECT 1 FROM _equiv e WHERE e.nombre = lower(btrim(COALESCE(i.datos->>'tipo', ''))));
  IF sin_equiv IS NOT NULL THEN
    RAISE EXCEPTION 'Migración 023 cancelada, no se cambió nada. Categorías de insumo sin equivalencia: %', sin_equiv;
  END IF;
END $$;

UPDATE insumos i
   SET datos = jsonb_set(i.datos, '{tipo}', to_jsonb(e.codigo))
  FROM _equiv e
 WHERE e.nombre = lower(btrim(i.datos->>'tipo'))
   AND i.datos->>'tipo' IS DISTINCT FROM e.codigo;

COMMIT;
