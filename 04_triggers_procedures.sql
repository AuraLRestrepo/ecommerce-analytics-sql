-- ============================================================
-- 04_triggers_procedures.sql
-- Paso 5: lógica de negocio en la base de datos.
--
-- Dos triggers:
--   1. Actualiza productos.stock_actual automáticamente cuando se
--      inserta un movimiento en inventario_movimientos.
--   2. Registra en una tabla de auditoría cada cambio de estado en
--      pedidos.
--
-- Requiere haber corrido 01_schema.sql y 02_seed_data.sql antes.
-- ============================================================

-- ------------------------------------------------------------
-- 0. Reconciliación inicial de stock
-- ------------------------------------------------------------
-- productos.stock_actual se generó en 02_seed_data.sql con un valor
-- aleatorio independiente de inventario_movimientos. Antes de activar
-- el trigger (que de aquí en adelante SÍ mantiene stock_actual
-- sincronizado con los movimientos), se recalcula una sola vez el
-- stock real como el neto de entradas menos salidas, para que ambas
-- fuentes queden consistentes desde el arranque.
UPDATE productos p
SET stock_actual = sub.neto
FROM (
    SELECT
        producto_id,
        sum(CASE WHEN tipo = 'entrada' THEN cantidad ELSE -cantidad END) AS neto
    FROM inventario_movimientos
    GROUP BY producto_id
) sub
WHERE p.id = sub.producto_id;

-- Verificación: no debe haber stock negativo tras la reconciliación.
-- SELECT count(*) FROM productos WHERE stock_actual < 0;

-- ------------------------------------------------------------
-- 1. Trigger: actualizar stock_actual desde inventario_movimientos
-- ------------------------------------------------------------
-- La función del trigger es, en esencia, un stored procedure escrito
-- en PL/pgSQL. Se dispara AFTER INSERT porque solo queremos ajustar
-- el stock una vez que el movimiento ya quedó registrado (si el
-- INSERT del movimiento falla, no queremos tocar el stock).
-- FOR EACH ROW: se ejecuta una vez por cada fila insertada (necesario
-- aquí porque cada movimiento afecta a un producto distinto; con
-- FOR EACH STATEMENT solo se dispararía una vez por sentencia INSERT,
-- sin acceso a NEW por fila).
-- Nunca se actualiza stock_actual manualmente desde fuera de este
-- trigger: inventario_movimientos es la única fuente de verdad, y el
-- CHECK (stock_actual >= 0) del esquema actúa como última línea de
-- defensa si una salida deja el stock en negativo.
CREATE OR REPLACE FUNCTION fn_actualizar_stock()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.tipo = 'entrada' THEN
        UPDATE productos
        SET stock_actual = stock_actual + NEW.cantidad
        WHERE id = NEW.producto_id;
    ELSE -- 'salida'
        UPDATE productos
        SET stock_actual = stock_actual - NEW.cantidad
        WHERE id = NEW.producto_id;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_actualizar_stock
AFTER INSERT ON inventario_movimientos
FOR EACH ROW
EXECUTE FUNCTION fn_actualizar_stock();

-- Prueba manual:
-- SELECT stock_actual FROM productos WHERE id = 1;
-- INSERT INTO inventario_movimientos (producto_id, tipo, cantidad, motivo)
-- VALUES (1, 'entrada', 10, 'Prueba de trigger');
-- SELECT stock_actual FROM productos WHERE id = 1; -- debe haber subido en 10

-- ------------------------------------------------------------
-- 2. Trigger de auditoría: cambios de estado en pedidos
-- ------------------------------------------------------------
-- Tabla de auditoría: guarda cada transición de estado, no solo el
-- estado final. estado_anterior es NULL-able porque, en teoría, no
-- todo cambio auditado tiene que venir de un estado previo definido
-- (defensivo; en la práctica siempre lo tendrá, ya que solo se
-- audita en UPDATE, nunca en INSERT).
CREATE TABLE auditoria_pedidos (
    id                SERIAL PRIMARY KEY,
    pedido_id         INT NOT NULL REFERENCES pedidos(id) ON DELETE CASCADE,
    estado_anterior   estado_pedido,
    estado_nuevo      estado_pedido NOT NULL,
    modificado_en     TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Se dispara AFTER UPDATE porque necesitamos comparar OLD (fila antes
-- del cambio) contra NEW (fila después) — ambas solo están disponibles
-- en triggers de UPDATE. El IF evita registrar auditoría cuando el
-- UPDATE tocó otras columnas de pedidos (ej. total) sin cambiar
-- estado — así la tabla de auditoría solo contiene transiciones
-- reales, no ruido.
-- IS DISTINCT FROM (en vez de !=): se comporta bien si algún estado
-- llegara a ser NULL, donde != daría NULL (ni true ni false) y el
-- IF nunca se cumpliría.
CREATE OR REPLACE FUNCTION fn_auditar_cambio_estado_pedido()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.estado IS DISTINCT FROM OLD.estado THEN
        INSERT INTO auditoria_pedidos (pedido_id, estado_anterior, estado_nuevo)
        VALUES (OLD.id, OLD.estado, NEW.estado);
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_auditar_cambio_estado_pedido
AFTER UPDATE ON pedidos
FOR EACH ROW
EXECUTE FUNCTION fn_auditar_cambio_estado_pedido();

-- Prueba manual:
-- UPDATE pedidos SET estado = 'enviado' WHERE id = 1;
-- SELECT * FROM auditoria_pedidos WHERE pedido_id = 1 ORDER BY modificado_en DESC;
-- UPDATE pedidos SET total = total FROM ...; -- (cambiar otra columna sin tocar estado)
-- no debería generar fila nueva en auditoria_pedidos
