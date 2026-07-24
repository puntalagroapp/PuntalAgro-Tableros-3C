-- Migración 005: columnas de fuente/vigencia/orden para herramientas externas
-- (calculadoras, informes en PDF, sitios externos mostrados en el inicio bajo
-- "Externos"). Permite que admin_general edite/reemplace el link o el PDF, y
-- fije un rango de fechas de validez para la visualización.
BEGIN;

ALTER TABLE herramientas
  ADD COLUMN IF NOT EXISTS fuente         TEXT,
  ADD COLUMN IF NOT EXISTS vigencia_desde DATE,
  ADD COLUMN IF NOT EXISTS vigencia_hasta DATE,
  ADD COLUMN IF NOT EXISTS orden          INTEGER NOT NULL DEFAULT 0;

-- Semilla de las 6 herramientas externas que hoy están hardcodeadas en
-- frontend/index.html — no se pisan si ya existen (ON CONFLICT DO NOTHING),
-- por si esta migración corre sobre una base que ya las tiene con otro id.
INSERT INTO herramientas (id, nombre, descripcion, tipo, url, fuente, orden, asignable) VALUES
    ('ext_calc_alquileres',  'Calculadora de Alquileres',
     'Calculadora de arrendamientos agrícolas para estimar el valor del alquiler de campo en distintos esquemas.',
     'externa', 'https://simpleza.com.ar/herramientas/calculadora-alquileres/', 'Simpleza', 1, false),
    ('ext_agri_finanzas',    'Agricultura & Finanzas',
     'Simulador financiero agrícola: rentabilidad por cultivo, impacto de shocks de precios y rindes, y escenarios de financiamiento con o sin socio a riesgo.',
     'externa', 'https://simpleza.com.ar/herramientas/agriculturafinanciera/', 'Simpleza', 2, false),
    ('ext_reporte_actualidad','Reporte de Actualidad Agro',
     'Reporte de actualidad del sector agropecuario con análisis de coyuntura y datos de referencia.',
     'externa', 'https://drive.google.com/file/d/1xfwCMCIAalW0YV47MCtThDFhc60dBNIJ/view', 'CREA', 3, false),
    ('ext_rif_urea_india',   'RIF Especial · Licitación Urea India',
     'Informe especial sobre la licitación oficial de compra de urea de India (NFL) de mayo 2026: volúmenes, fechas, restricciones geopolíticas e impacto esperado en precios internacionales.',
     'externa', 'rif_especial_urea_india.pdf.pdf', 'Ingeniería en Fertilizantes', 4, false),
    ('ext_apuntes_zym',      'Apuntes para Empresas · Mayo 2026',
     'Análisis de contexto para empresas agropecuarias: macro en la micro, baja de retenciones, negocio agrícola, ganadero y lechero. Método del 1% y el Furgón de Cola.',
     'externa', 'apuntes_zorraquin_meneses_mayo2026.pdf', 'Zorraquín + Meneses', 5, false),
    ('ext_rif_semanal_fert', 'RIF Semanal · Mercado de Fertilizantes',
     'Reporte semanal del mercado de fertilizantes (29 mayo 2026): nitrogenados, fosfatados, precios locales e internacionales, y relación insumo-producto para trigo y maíz.',
     'externa', 'rif_semanal_2026_22.pdf', 'Ingeniería en Fertilizantes', 6, false)
ON CONFLICT (id) DO NOTHING;

COMMIT;
