-- =============================================================================
-- Migración 004: catálogos globales de insumos (categorías, usos, formulaciones,
-- principios activos) + entidad "socios" por empresa.
--
-- Contexto: actualización de maestros.html (2026-07-17/2026-07-21). El cliente
-- confirmó explícitamente (2026-07-21) que estos 4 catálogos son GLOBALES
-- (store único, visibles en todas las empresas, los edita el administrador de
-- la app) — no por empresa. Ver decisión en memoria del proyecto
-- (decision_catalogos_insumos_por_empresa). "Socios" es nueva, por empresa,
-- mismo patrón que terceros/choferes/depositos.
--
-- Ejecutar: docker exec -i pa_postgres_db psql -U postgres -d puntalagro_tableros_3C
--           < database/migrations/004_catalogos_insumos_y_socios.sql
-- =============================================================================

BEGIN;

-- ── Categorías de insumo (global) ────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS categorias_insumo (
    id     TEXT PRIMARY KEY,
    codigo TEXT NOT NULL,
    label  TEXT NOT NULL,
    base   BOOLEAN NOT NULL DEFAULT false,
    fito   BOOLEAN NOT NULL DEFAULT false,
    subcat BOOLEAN NOT NULL DEFAULT false,
    activo BOOLEAN NOT NULL DEFAULT true
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_categorias_insumo_codigo ON categorias_insumo (trim(lower(codigo)));

INSERT INTO categorias_insumo (id, codigo, label, base, fito, subcat, activo) VALUES
('cat_sem',  'SEM',  'Semillas',                   true, false, false, true),
('cat_cura', 'CURA', 'Curasemillas e Inoculantes', true, false, false, true),
('cat_herb', 'HERB', 'Herbicidas',                 true, true,  false, true),
('cat_inse', 'INSE', 'Insecticidas',                true, true,  false, true),
('cat_fung', 'FUNG', 'Fungicidas',                  true, true,  false, true),
('cat_coad', 'COAD', 'Coadyuvantes y Correctores',  true, false, true,  true),
('cat_fert', 'FERT', 'Fertilizantes',               true, false, false, true),
('cat_otro', 'OTRO', 'Otros Insumos',               true, false, false, true)
ON CONFLICT (id) DO NOTHING;

-- ── Usos (cultivo / unidad de negocio — global) ──────────────────────────────
CREATE TABLE IF NOT EXISTS usos_actividad (
    id     TEXT PRIMARY KEY,
    codigo TEXT NOT NULL,
    label  TEXT NOT NULL,
    activo BOOLEAN NOT NULL DEFAULT true
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_usos_actividad_codigo ON usos_actividad (trim(lower(codigo)));

INSERT INTO usos_actividad (id, codigo, label, activo) VALUES
('uso_agr', 'AGR', 'Agricultura',      true),
('uso_gan', 'GAN', 'Ganadería',        true),
('uso_dob', 'DOB', 'Doble propósito',  true)
ON CONFLICT (id) DO NOTHING;

-- ── Formulaciones (orden de mezclado en tanque — global) ─────────────────────
CREATE TABLE IF NOT EXISTS formulaciones (
    id          TEXT PRIMARY KEY,
    codigo      TEXT,
    descripcion TEXT NOT NULL,
    orden       INTEGER NOT NULL DEFAULT 0,
    activo      BOOLEAN NOT NULL DEFAULT true
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_formulaciones_descripcion ON formulaciones (trim(lower(descripcion)));

INSERT INTO formulaciones (id, codigo, descripcion, orden, activo) VALUES
('f_agua', '',   'Agua (media carga, corrección dureza/pH)',           1,  true),
('f_coad', '',   'Coadyuvantes / correctores / secuestrantes',          2,  true),
('f_anti', '',   'Antiespumante',                                      3,  true),
('f_wp',   'WP', 'Polvos mojables',                                    4,  true),
('f_wg',   'WG', 'Gránulos dispersables',                              5,  true),
('f_sg',   'SG', 'Gránulos solubles',                                  6,  true),
('f_od',   'OD', 'Dispersiones oleosas',                               7,  true),
('f_sc',   'SC', 'Suspensiones concentradas',                          8,  true),
('f_cs',   'CS', 'Suspensiones de encapsulados (microcápsulas)',       9,  true),
('f_se',   'SE', 'Suspo-emulsiones',                                   10, true),
('f_ew',   'EW', 'Emulsiones de aceite en agua',                       11, true),
('f_ec',   'EC', 'Concentrados emulsionables',                         12, true),
('f_sl',   'SL', 'Concentrados / líquidos solubles',                   13, true),
('f_acei', '',   'Aceites / surfactantes / adyuvantes finales',        14, true),
('f_foli', '',   'Micronutrientes / fertilizantes foliares',           15, true)
ON CONFLICT (id) DO NOTHING;

-- ── Principios activos (global). Seed: 152 filas base EIQ Referencia
--    (CropLife/SENASA + EIQ Cornell). eiq NULL = N/D (feromonas, biológicos,
--    coadyuvantes: suman 0 al EIQ total). ────────────────────────────────────
CREATE TABLE IF NOT EXISTS principios_activos (
    id     TEXT PRIMARY KEY,
    nombre TEXT NOT NULL,
    eiq    NUMERIC(6,2),
    uso    TEXT,
    activo BOOLEAN NOT NULL DEFAULT true
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_principios_activos_nombre ON principios_activos (trim(lower(nombre)));

INSERT INTO principios_activos (id, nombre, eiq, uso, activo) VALUES
('pa_0', '(E,E)8,10-DODECADIENOL', NULL, 'Feromona (control de plagas)', true),
('pa_1', '(E,Z)7,9-DODECADIENIL ACETATO', NULL, 'Feromona (control de plagas)', true),
('pa_2', '(Z)/(E)-8-DODECENIL ACETATO', NULL, 'Feromona (control de plagas)', true),
('pa_3', '2,4 D', 19.27, 'Herbicida', true),
('pa_4', '2,4-DB', 19.27, 'Herbicida', true),
('pa_5', 'ABAMECTINA', 35.65, 'Insecticida/Acaricida', true),
('pa_6', 'ACEFATO', 18.45, 'Insecticida', true),
('pa_7', 'ACEITE DE SOJA', 5.0, 'Coadyuvante', true),
('pa_8', 'ACEITE MINERAL', 5.0, 'Coadyuvante', true),
('pa_9', 'ACETAMIPRID', 24.83, 'Insecticida', true),
('pa_10', 'ACETOCLOR', 22.0, 'Herbicida', true),
('pa_11', 'ACIDO FOSFORICO', NULL, 'Coadyuvante', true),
('pa_12', 'ACIDO GIBERELICO', 5.0, 'Regulador de crecimiento', true),
('pa_13', 'AFIDOPYROPEN', 18.0, 'Insecticida', true),
('pa_14', 'ALCOHOL GRASO ETOXILADO', NULL, 'Coadyuvante', true),
('pa_15', 'ALCOHOL LAURICO ETOXILADO', NULL, 'Coadyuvante', true),
('pa_16', 'ALCOHOL LINEAL ETOXILADO', NULL, 'Coadyuvante', true),
('pa_17', 'ALCOHOLES GRASOS', NULL, 'Coadyuvante', true),
('pa_18', 'ALFACIPERMETRINA/ALFAMETRINA', 36.71, 'Insecticida', true),
('pa_19', 'ALQUIL ARIL POLIGLICOL ETER', NULL, 'Coadyuvante', true),
('pa_20', 'AMETRINA', 22.0, 'Herbicida', true),
('pa_21', 'ATRAZINA', 22.71, 'Herbicida', true),
('pa_22', 'AZOXISTROBINA', 27.33, 'Fungicida', true),
('pa_23', 'AZUFRE', 33.0, 'Fungicida/Acaricida', true),
('pa_24', 'BACILLUS AMYLOLIQUEFACIENS', NULL, 'Fungicida biológico', true),
('pa_25', 'BACILLUS THURINGIENSIS', NULL, 'Insecticida biológico', true),
('pa_26', 'BACILLUS THURINGIENSIS var AIZAWAI', NULL, 'Insecticida biológico', true),
('pa_27', 'BENAZOLIN ETIL', 20.0, 'Herbicida', true),
('pa_28', 'BENZOATO DE EMAMECTINA', 30.5, 'Insecticida', true),
('pa_29', 'BENZOVINDIFLUPIR', 22.0, 'Fungicida', true),
('pa_30', 'BICICLOPIRONA', 20.0, 'Herbicida', true),
('pa_31', 'BIFENTRIN', 44.43, 'Insecticida', true),
('pa_32', 'BOSCALID', 19.43, 'Fungicida', true),
('pa_33', 'BROMOXINIL', 21.93, 'Herbicida', true),
('pa_34', 'Bacillus Velezensis', NULL, 'Fungicida biológico', true),
('pa_35', 'CAPTAN', 33.0, 'Fungicida', true),
('pa_36', 'CARBARIL', 22.83, 'Insecticida', true),
('pa_37', 'CARBENDAZIM', 33.0, 'Fungicida', true),
('pa_38', 'CARBONATO BASICO DE COBRE', 33.67, 'Fungicida', true),
('pa_39', 'CARFENTRAZONE ETIL', 19.83, 'Herbicida', true),
('pa_40', 'CIPERMETRINA', 36.71, 'Insecticida', true),
('pa_41', 'CIPROCONAZOLE', 21.67, 'Fungicida', true),
('pa_42', 'CLETODIM', 18.93, 'Herbicida', true),
('pa_43', 'CLOMAZONE', 23.13, 'Herbicida', true),
('pa_44', 'CLOPYRALID', 19.5, 'Herbicida', true),
('pa_45', 'CLOQUINTOCET MEXIL', 15.0, 'Protector (safener)', true),
('pa_46', 'CLORANTRANILIPROLE', 27.5, 'Insecticida', true),
('pa_47', 'CLORFENAPIR', 36.27, 'Insecticida/Acaricida', true),
('pa_48', 'CLORIMURON ETIL', 24.0, 'Herbicida', true),
('pa_49', 'CLOROTALONIL', 33.0, 'Fungicida', true),
('pa_50', 'DELTAMETRINA', 27.13, 'Insecticida', true),
('pa_51', 'DICAMBA', 25.43, 'Herbicida', true),
('pa_52', 'DICLOSULAM', 17.83, 'Herbicida', true),
('pa_53', 'DIFENOCONAZOLE', 22.83, 'Fungicida', true),
('pa_54', 'DIFLUFENICAN', 19.83, 'Herbicida', true),
('pa_55', 'DIMETOATO', 32.71, 'Insecticida', true),
('pa_56', 'DIMETOMORF', 21.83, 'Fungicida', true),
('pa_57', 'DINOTEFURAN', 26.5, 'Insecticida', true),
('pa_58', 'DIQUAT', 33.93, 'Herbicida', true),
('pa_59', 'DIQUAT DIBROMURO', 33.93, 'Herbicida', true),
('pa_60', 'DIURON', 24.66, 'Herbicida', true),
('pa_61', 'DODECIL BENCEN SULFONICO', NULL, 'Coadyuvante', true),
('pa_62', 'EPOXICONAZOLE', 35.45, 'Fungicida', true),
('pa_63', 'ESTERES METILICOS DE ACIDOS GRASOS DE ACEITE DE SOJA', NULL, 'Coadyuvante', true),
('pa_64', 'ESTERES METILICOS DE ACIDOS GRASOS DE ACEITE VEGETAL', NULL, 'Coadyuvante', true),
('pa_65', 'ETEFON', 26.13, 'Regulador de crecimiento', true),
('pa_66', 'FENOXAPROP-P ETIL', 19.83, 'Herbicida', true),
('pa_67', 'FIPRONIL', 35.83, 'Insecticida', true),
('pa_68', 'FLUAZINAM', 21.13, 'Fungicida', true),
('pa_69', 'FLUDIOXONIL', 20.13, 'Fungicida', true),
('pa_70', 'FLUMETSULAM', 19.0, 'Herbicida', true),
('pa_71', 'FLUMIOXAZIN', 17.66, 'Herbicida', true),
('pa_72', 'FLUROCLORIDONA', 22.0, 'Herbicida', true),
('pa_73', 'FLUROXIPIR MEPTIL', 21.0, 'Herbicida', true),
('pa_74', 'FLUTRIAFOL', 22.0, 'Fungicida', true),
('pa_75', 'FLUXAPIROXAD', 28.0, 'Fungicida', true),
('pa_76', 'FOMESAFEN', 19.0, 'Herbicida', true),
('pa_77', 'FOSFURO DE ALUMINIO', 30.0, 'Fumigante/Insecticida', true),
('pa_78', 'GLIFOSATO', 15.33, 'Herbicida', true),
('pa_79', 'GLUFOSINATO DE AMONIO', 19.92, 'Herbicida', true),
('pa_80', 'HALAUXIFEN METIL', 19.0, 'Herbicida', true),
('pa_81', 'HALOXIFOP-P METIL', 19.5, 'Herbicida', true),
('pa_82', 'HEPTAMETILTRISILOXANO', NULL, 'Coadyuvante', true),
('pa_83', 'HIDROXIDO DE COBRE', 33.67, 'Fungicida', true),
('pa_84', 'IMAZALIL', 24.0, 'Fungicida', true),
('pa_85', 'IMAZAPIC', 19.83, 'Herbicida', true),
('pa_86', 'IMAZAPIR', 19.87, 'Herbicida', true),
('pa_87', 'IMAZETAPIR', 19.0, 'Herbicida', true),
('pa_88', 'IMIDACLOPRID', 36.71, 'Insecticida', true),
('pa_89', 'IPRODIONE', 30.5, 'Fungicida', true),
('pa_90', 'ISOXABEN', 21.0, 'Herbicida', true),
('pa_91', 'ISOXAFLUTOLE', 22.5, 'Herbicida', true),
('pa_92', 'LAMBDA-CIALOTRINA', 44.45, 'Insecticida', true),
('pa_93', 'LECITINA DE SOJA', 10.0, 'Coadyuvante', true),
('pa_94', 'LUFENURON', 22.93, 'Insecticida', true),
('pa_95', 'M.C.P.A.', 19.5, 'Herbicida', true),
('pa_96', 'M.S.M.A.', 23.0, 'Herbicida', true),
('pa_97', 'MANCOZEB', 32.87, 'Fungicida', true),
('pa_98', 'MESOTRIONE', 19.5, 'Herbicida', true),
('pa_99', 'METALAXIL', 22.13, 'Fungicida', true),
('pa_100', 'METALAXIL -M', 22.13, 'Fungicida', true),
('pa_101', 'METALDEHIDO', 22.0, 'Molusquicida', true),
('pa_102', 'METIL CICLOPROPENO', 10.0, 'Regulador de crecimiento', true),
('pa_103', 'METIL TIOFANATO', 35.0, 'Fungicida', true),
('pa_104', 'METOLACLORO', 21.61, 'Herbicida', true),
('pa_105', 'METOMIL', 36.5, 'Insecticida', true),
('pa_106', 'METOXIFENOCIDE', 22.93, 'Insecticida', true),
('pa_107', 'METRIBUZIN', 28.0, 'Herbicida', true),
('pa_108', 'METSULFURON METIL', 21.0, 'Herbicida', true),
('pa_109', 'MICLOBUTANIL', 22.0, 'Fungicida', true),
('pa_110', 'NICOSULFURON', 19.83, 'Herbicida', true),
('pa_111', 'NONIL FENOL ETOXILADO', NULL, 'Coadyuvante', true),
('pa_112', 'NOVALURON', 22.0, 'Insecticida', true),
('pa_113', 'OXICLORURO DE COBRE', 33.67, 'Fungicida', true),
('pa_114', 'OXIDO CUPROSO', 33.67, 'Fungicida', true),
('pa_115', 'OXIFLUORFEN', 27.43, 'Herbicida', true),
('pa_116', 'PARAQUAT DICLORURO', 38.07, 'Herbicida', true),
('pa_117', 'PENDIMETALIN', 23.0, 'Herbicida', true),
('pa_118', 'PICLORAM', 19.83, 'Herbicida', true),
('pa_119', 'PICOXISTROBIN', 27.0, 'Fungicida', true),
('pa_120', 'PIDIFLUMETOFEN', 22.0, 'Fungicida', true),
('pa_121', 'PINOXADEN', 19.83, 'Herbicida', true),
('pa_122', 'PIRACLOSTROBIN', 31.5, 'Fungicida', true),
('pa_123', 'PIRIMETANIL', 19.43, 'Fungicida', true),
('pa_124', 'PIRIMIFOS METIL', 33.83, 'Insecticida', true),
('pa_125', 'PIRIPROXIFEN', 26.93, 'Insecticida (regulador)', true),
('pa_126', 'PIROXASULFONE', 18.5, 'Herbicida', true),
('pa_127', 'PROFENOFOS', 41.5, 'Insecticida', true),
('pa_128', 'PROHEXADIONE DE CALCIO', 15.0, 'Regulador de crecimiento', true),
('pa_129', 'PROMETRINA', 22.0, 'Herbicida', true),
('pa_130', 'PROPICONAZOLE', 21.93, 'Fungicida', true),
('pa_131', 'PROTIOCONAZOLE', 22.0, 'Fungicida', true),
('pa_132', 'QUIZALOFOP-P ETIL', 20.83, 'Herbicida', true),
('pa_133', 'S-METOLACLORO', 21.61, 'Herbicida', true),
('pa_134', 'SAFLUFENACIL', 19.83, 'Herbicida', true),
('pa_135', 'SEDAXANE', 19.0, 'Fungicida', true),
('pa_136', 'SPINOSAD', 26.0, 'Insecticida', true),
('pa_137', 'SULFATO DE AMONIO', 10.0, 'Coadyuvante', true),
('pa_138', 'SULFATO DE COBRE PENTAHIDRATADO', 33.67, 'Fungicida', true),
('pa_139', 'SULFENTRAZONE', 23.5, 'Herbicida', true),
('pa_140', 'T.C.M.T.B.', 30.0, 'Fungicida', true),
('pa_141', 'TEBUCONAZOLE', 25.33, 'Fungicida', true),
('pa_142', 'TERBUTILAZINA', 23.0, 'Herbicida', true),
('pa_143', 'TIABENDAZOL', 23.5, 'Fungicida', true),
('pa_144', 'TIAMETOXAM', 33.7, 'Insecticida', true),
('pa_145', 'TIENCARBAZONE METIL', 18.0, 'Herbicida', true),
('pa_146', 'TIODICARB', 33.93, 'Insecticida', true),
('pa_147', 'TIRAM', 35.93, 'Fungicida', true),
('pa_148', 'TOPRAMEZONE', 19.0, 'Herbicida', true),
('pa_149', 'TRICHODERMA AFROHARZIANUM cepa Th2R199', NULL, 'Fungicida biológico', true),
('pa_150', 'TRICHODERMA HARZIANUM', NULL, 'Fungicida biológico', true),
('pa_151', 'TRIFLOXISTROBIN', 27.0, 'Fungicida', true)
ON CONFLICT (id) DO NOTHING;

-- ── Socios (por empresa) — nueva entidad simple, mismo patrón que terceros/
--    choferes/depositos: JSONB datos, sin columnas propias. ──────────────────
CREATE TABLE IF NOT EXISTS socios (
    id         TEXT NOT NULL,
    empresa_id TEXT NOT NULL REFERENCES empresas(id) ON DELETE CASCADE,
    datos      JSONB NOT NULL DEFAULT '{}',
    PRIMARY KEY (id, empresa_id)
);
CREATE INDEX IF NOT EXISTS idx_socios_empresa ON socios(empresa_id);
CREATE UNIQUE INDEX IF NOT EXISTS uq_socios_nombre_empresa ON socios (empresa_id, trim(lower(datos->>'nombre')));

COMMIT;
