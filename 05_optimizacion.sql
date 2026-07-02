-- ============================================================
-- 05_optimizacion.sql
-- Paso 6: índices y EXPLAIN ANALYZE antes/después.
--
-- Punto clave para entrevista: a diferencia de las PRIMARY KEY y los
-- constraints UNIQUE, Postgres NO crea automáticamente un índice
-- sobre las columnas de FOREIGN KEY. Antes de este script, \di solo
-- mostraba índices de PK/UNIQUE — cualquier filtro o JOIN por una FK
-- (cliente_id, producto_id, pedido_id, categoria_id...) forzaba un
-- Seq Scan completo de la tabla.
--
-- Todas las mediciones de este archivo se corrieron contra los datos
-- reales del proyecto (2,000 pedidos, 5,957 detalle_pedidos, 200
-- productos, 600 inventario_movimientos), no son estimaciones.
-- ============================================================

-- ------------------------------------------------------------
-- Índices creados (uno por cada FK sin índice + un caso de columna
-- muy consultada por igualdad)
-- ------------------------------------------------------------
CREATE INDEX idx_productos_categoria_id ON productos(categoria_id);
CREATE INDEX idx_pedidos_cliente_id ON pedidos(cliente_id);
CREATE INDEX idx_detalle_pedidos_pedido_id ON detalle_pedidos(pedido_id);
CREATE INDEX idx_detalle_pedidos_producto_id ON detalle_pedidos(producto_id);
CREATE INDEX idx_pagos_pedido_id ON pagos(pedido_id);
CREATE INDEX idx_inventario_movimientos_producto_id ON inventario_movimientos(producto_id);
CREATE INDEX idx_resenas_cliente_id ON resenas(cliente_id);
CREATE INDEX idx_categorias_categoria_padre_id ON categorias(categoria_padre_id);
CREATE INDEX idx_pedidos_estado ON pedidos(estado);

-- Después de crear índices nuevos, siempre correr ANALYZE: actualiza
-- las estadísticas que usa el planner (cardinalidad, distribución de
-- valores) para decidir si le conviene usar el índice o no. Sin esto,
-- el planner puede seguir usando estadísticas viejas.
ANALYZE;

-- ============================================================
-- CASO 1 — filtro por FK selectivo: SÍ mejora, y el planner lo adopta
-- ============================================================

-- Antes (sin índice en cliente_id):
--   Seq Scan on pedidos  (cost=0.00..53.00 rows=3 width=26)
--                        (actual time=0.182..0.366 rows=4 loops=1)
--     Filter: (cliente_id = 123)
--     Rows Removed by Filter: 1996
--   Execution Time: 0.457 ms

-- Después (con idx_pedidos_cliente_id):
--   Bitmap Heap Scan on pedidos  (cost=4.30..13.39 rows=3 width=26)
--                                (actual time=0.110..0.116 rows=4 loops=1)
--     Recheck Cond: (cliente_id = 123)
--     Heap Blocks: exact=4
--     ->  Bitmap Index Scan on idx_pedidos_cliente_id
--           Index Cond: (cliente_id = 123)
--   Execution Time: 0.227 ms   -- ~2x más rápido, y cambia de plan solo

EXPLAIN ANALYZE SELECT * FROM pedidos WHERE cliente_id = 123;

-- Mismo patrón, resultado más marcado en la tabla más grande
-- (detalle_pedidos, ~6,000 filas):
--
-- Antes:  Seq Scan, Execution Time: 0.567 ms (recorre 5,957 filas)
-- Después: Bitmap Heap Scan + Bitmap Index Scan, Execution Time: 0.142 ms
--          -> ~4x más rápido
EXPLAIN ANALYZE SELECT * FROM detalle_pedidos WHERE producto_id = 55;

-- ============================================================
-- CASO 2 — tabla muy pequeña: el índice existe pero el planner elige
-- IGNORARLO, y esa es la decisión correcta
-- ============================================================

-- productos tiene 200 filas en solo 3 páginas de disco. Leer las 3
-- páginas completas (Seq Scan) es más barato que hacer un Bitmap
-- Index Scan (que implica leer el índice + volver a la tabla). El
-- planner de Postgres es cost-based, no "usa índice si existe" —
-- decide según costo estimado real.
--
-- Con el índice creado, esta query sigue eligiendo Seq Scan:
--   Seq Scan on productos  (cost=0.00..5.50 rows=36 width=61)
--     Execution Time: 0.054 ms
EXPLAIN ANALYZE SELECT * FROM productos WHERE categoria_id = 7;

-- Prueba de que el índice SÍ funciona si se fuerza su uso (solo para
-- demostrarlo, nunca se hace esto en producción):
--   SET enable_seqscan = off;
--   -> Bitmap Heap Scan usando idx_productos_categoria_id
--   -> Execution Time: 0.150 ms  (MÁS LENTO que el Seq Scan de arriba)
-- Esto confirma que el planner tomó la decisión correcta: en una
-- tabla de 3 páginas, el índice añade overhead en vez de ahorrarlo.
-- Con más volumen (miles/millones de filas) el resultado se invierte
-- y el planner empieza a preferir el índice automáticamente.
SET enable_seqscan = off;
EXPLAIN ANALYZE SELECT * FROM productos WHERE categoria_id = 7;
SET enable_seqscan = on;

-- ============================================================
-- CASO 3 — agregación sobre toda la tabla: un índice de igualdad no
-- ayuda, y el plan con Hash Join + Seq Scan ya es el óptimo
-- ============================================================

-- El query de ranking de productos por categoría (03_queries_analiticas.sql,
-- query 2) necesita leer prácticamente todo detalle_pedidos para
-- agregar por producto/categoría — no hay un WHERE selectivo que un
-- índice pueda aprovechar. El plan real:
--   Hash Join (detalle_pedidos x productos x categorias)
--   -> HashAggregate -> Sort -> WindowAgg
--   Execution Time: 4.504 ms
-- Un índice en categoria_id o producto_id no cambiaría esto: cuando
-- una query necesita "casi todas las filas", Seq Scan + Hash Join es
-- más eficiente que miles de búsquedas individuales por índice.
EXPLAIN ANALYZE
SELECT
    c.nombre AS categoria,
    p.nombre AS producto,
    sum(d.cantidad) AS unidades_vendidas,
    sum(d.cantidad * d.precio_unitario) AS ingresos,
    RANK() OVER (
        PARTITION BY c.id
        ORDER BY sum(d.cantidad * d.precio_unitario) DESC
    ) AS ranking_en_categoria
FROM productos p
JOIN categorias c ON c.id = p.categoria_id
JOIN detalle_pedidos d ON d.producto_id = p.id
GROUP BY c.id, c.nombre, p.id, p.nombre;

-- ============================================================
-- CASO 4 — índice de baja selectividad: idx_pedidos_estado se creó
-- pero no ayuda a un filtro "distinto de" que matchea la mayoría de
-- las filas
-- ============================================================

-- La query de ventas mensuales filtra WHERE estado != 'cancelado'.
-- De 2,000 pedidos, ~1,578 (79%) cumplen esa condición — no es un
-- filtro selectivo, así que el planner sigue eligiendo Seq Scan sobre
-- pedidos en vez de usar idx_pedidos_estado:
--   Seq Scan on pedidos  Filter: (estado <> 'cancelado')
--   Rows Removed by Filter: 422   -- de 2000, remueve solo 422 (=cancelados)
-- Lección para entrevista: un índice en una columna de pocos valores
-- distintos (ENUM de 5 estados) solo ayuda cuando el valor buscado es
-- una porción pequeña del total. Filtrar por "!= algo poco común" no
-- es selectivo, aunque el "algo poco común" en sí sí lo sería
-- (WHERE estado = 'cancelado' probablemente SÍ usaría el índice).
EXPLAIN ANALYZE
WITH ventas_mensuales AS (
    SELECT date_trunc('month', p.fecha_pedido) AS mes,
           sum(d.cantidad * d.precio_unitario) AS ingresos_mes
    FROM pedidos p
    JOIN detalle_pedidos d ON d.pedido_id = p.id
    WHERE p.estado != 'cancelado'
    GROUP BY date_trunc('month', p.fecha_pedido)
)
SELECT mes, ingresos_mes, sum(ingresos_mes) OVER (ORDER BY mes)
FROM ventas_mensuales
ORDER BY mes;

-- ============================================================
-- Conclusión (para el README / la entrevista)
-- ============================================================
-- 1. Postgres no indexa FKs automáticamente — hay que crearlos a mano.
-- 2. El planner es cost-based: un índice que existe no significa que
--    se use. En tablas pequeñas, Seq Scan gana casi siempre.
-- 3. Los índices ayudan a filtros selectivos (pocas filas de muchas),
--    no a queries que ya necesitan leer la mayoría de la tabla.
-- 4. Siempre correr ANALYZE después de crear índices o cargar datos
--    en volumen, para que el planner tenga estadísticas actualizadas.
-- 5. Con el volumen actual (miles de filas) las ganancias son de
--    fracciones de milisegundo; el valor real de estos índices se
--    nota con volumen de producción (millones de filas), donde un
--    Seq Scan sin índice en una FK se vuelve inaceptablemente lento.
