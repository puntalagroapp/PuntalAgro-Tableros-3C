-- =============================================================================
-- Migración 002: nueva herramienta "Existencia y Producción Ganadera".
-- El cliente agregó el link en su index.html standalone; el tablero en sí
-- (exist_prod_ganadera.html) todavía no está migrado — esta migración solo
-- habilita el registro en el catálogo de herramientas para que se pueda
-- asignar por permiso, igual que las demás.
-- Ejecutar: docker exec -i pa_postgres_db psql -U postgres -d puntalagro_tableros_3C
--           < database/migrations/002_add_herramienta_exist_prod_ganadera.sql
-- =============================================================================

INSERT INTO herramientas (id, nombre, descripcion, tipo, url, dominio, asignable)
VALUES (
  'exist_prod_ganadera',
  'Existencia y Producción Ganadera',
  'Existencias de hacienda por negocio, rodeo y categoría. Movimientos, conciliación de stock y seguimiento de cabezas y kilos.',
  'propia',
  'exist_prod_ganadera.html',
  'Ganadería',
  true
)
ON CONFLICT (id) DO NOTHING;
