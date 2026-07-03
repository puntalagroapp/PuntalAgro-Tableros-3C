-- =============================================================================
-- Migración 001: Agregar claves foráneas faltantes
-- Aplicar sobre bases existentes que fueron creadas con el init.sql original.
-- Ejecutar: docker exec -i pa_postgres_db psql -U postgres -d puntalagro_tableros_3C
--           < database/migrations/001_add_missing_fks.sql
-- =============================================================================

-- 1. sesiones.empresa_id_activa → empresas(id)
ALTER TABLE sesiones
    ADD CONSTRAINT fk_sesiones_empresa_activa
    FOREIGN KEY (empresa_id_activa) REFERENCES empresas(id) ON DELETE SET NULL;

-- 2. choferes(tercero_id, empresa_id) → terceros(id, empresa_id)
ALTER TABLE choferes
    ADD CONSTRAINT fk_choferes_tercero
    FOREIGN KEY (tercero_id, empresa_id) REFERENCES terceros(id, empresa_id) ON DELETE CASCADE;

-- 3. actividades(tipo_actividad_id, empresa_id) → tipos_actividad(id, empresa_id)
--    tipo_actividad_id es nullable: si es NULL, la FK no se evalúa (MATCH SIMPLE).
ALTER TABLE actividades
    ADD CONSTRAINT fk_actividades_tipo_actividad
    FOREIGN KEY (tipo_actividad_id, empresa_id) REFERENCES tipos_actividad(id, empresa_id) ON DELETE RESTRICT;

-- 4. ordenes_trabajo(tercero_id, empresa_id) → terceros(id, empresa_id)
--    tercero_id es nullable: si es NULL, la FK no se evalúa.
ALTER TABLE ordenes_trabajo
    ADD CONSTRAINT fk_ots_tercero
    FOREIGN KEY (tercero_id, empresa_id) REFERENCES terceros(id, empresa_id) ON DELETE RESTRICT;

-- 5. movimientos(insumo_id, empresa_id) → insumos(id, empresa_id)
ALTER TABLE movimientos
    ADD CONSTRAINT fk_movimientos_insumo
    FOREIGN KEY (insumo_id, empresa_id) REFERENCES insumos(id, empresa_id) ON DELETE RESTRICT;

-- 6. movimientos(origen_deposito_id, empresa_id) → depositos(id, empresa_id)
ALTER TABLE movimientos
    ADD CONSTRAINT fk_movimientos_origen_deposito
    FOREIGN KEY (origen_deposito_id, empresa_id) REFERENCES depositos(id, empresa_id) ON DELETE RESTRICT;

-- 7. movimientos(destino_deposito_id, empresa_id) → depositos(id, empresa_id)
ALTER TABLE movimientos
    ADD CONSTRAINT fk_movimientos_destino_deposito
    FOREIGN KEY (destino_deposito_id, empresa_id) REFERENCES depositos(id, empresa_id) ON DELETE RESTRICT;

-- 8. movimientos(ot_id, empresa_id) → ordenes_trabajo(id, empresa_id)
ALTER TABLE movimientos
    ADD CONSTRAINT fk_movimientos_ot
    FOREIGN KEY (ot_id, empresa_id) REFERENCES ordenes_trabajo(id, empresa_id) ON DELETE RESTRICT;
