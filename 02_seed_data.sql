-- ============================================================
-- 02_seed_data.sql
-- Generación de datos de prueba con SQL puro (generate_series +
-- funciones de aleatoriedad de Postgres).
--
-- IMPORTANTE: este archivo contiene la versión FINAL, corregida,
-- de cada inserción. Ver notes.md para el detalle del bug que
-- obligó a reescribir productos, pedidos y detalle_pedidos.
--
-- Resumen del bug (contexto para no repetirlo):
-- Una subquery escalar tipo (SELECT id FROM tabla ORDER BY random()
-- LIMIT 1), puesta directo en el SELECT, puede ser optimizada por
-- Postgres como InitPlan: se ejecuta una sola vez para toda la query
-- en vez de una vez por fila, dejando miles de registros con el mismo
-- valor "aleatorio". LATERAL no lo arregla si la subquery interna no
-- referencia ninguna columna de la fila externa (sigue sin haber
-- correlación real). La solución robusta: generar el índice aleatorio
-- como expresión normal en el SELECT (se evalúa por fila, garantizado)
-- y unirlo con un JOIN explícito contra la tabla objetivo numerada con
-- row_number().
--
-- Volumen: ~15-20 categorías, 200 productos, 500 clientes,
-- 2,000 pedidos, ~5,000 detalle_pedidos, ~2,000 pagos,
-- ~3,000 inventario_movimientos, ~1,500 resenas.
-- ============================================================

-- ------------------------------------------------------------
-- 1. categorias (jerarquía de 3 niveles, insertada a mano para
--    controlar la relación padre-hijo)
-- ------------------------------------------------------------
-- Nivel 1: categorías raíz
INSERT INTO categorias (nombre, categoria_padre_id) VALUES
('Electrónica', NULL),
('Ropa', NULL),
('Hogar', NULL),
('Deportes', NULL);

-- Nivel 2: subcategorías (Electrónica=1, Ropa=2, Hogar=3, Deportes=4)
INSERT INTO categorias (nombre, categoria_padre_id) VALUES
('Celulares', 1),
('Laptops', 1),
('Audio', 1),
('Ropa Hombre', 2),
('Ropa Mujer', 2),
('Muebles', 3),
('Cocina', 3),
('Fitness', 4),
('Ciclismo', 4);

-- Nivel 3: sub-subcategorías (Celulares=5, Laptops=6)
INSERT INTO categorias (nombre, categoria_padre_id) VALUES
('Accesorios para celulares', 5),
('Fundas y protectores', 5),
('Accesorios para laptops', 6);

-- Verificación: confirmar IDs reales antes de continuar si hubo
-- algún borrado o reinicio previo.
-- SELECT id, nombre, categoria_padre_id FROM categorias;

-- ------------------------------------------------------------
-- 2. clientes (500 registros)
-- ------------------------------------------------------------
-- generate_series(1,500): genera 500 filas de una vez.
-- (ARRAY[...])[floor(random()*n+1)]: elige un elemento aleatorio de
-- un array de opciones — patrón estándar para simular una columna
-- categórica aleatoria.
-- now() - (random() * interval '730 days'): distribuye las fechas de
-- registro en los últimos ~2 años, para que luego las queries de
-- "clientes por mes/año" tengan sentido.
INSERT INTO clientes (email, nombre, pais, fecha_registro)
SELECT
    'cliente' || i || '@example.com',
    'Cliente Demo ' || i,
    (ARRAY['Colombia', 'México', 'Argentina', 'Chile', 'Perú', 'España'])[floor(random() * 6 + 1)],
    now() - (random() * interval '730 days')
FROM generate_series(1, 500) AS i;

-- SELECT count(*) FROM clientes; -- debe dar 500

-- ------------------------------------------------------------
-- 3. productos (200 registros) — VERSIÓN CORREGIDA con row_number()
-- ------------------------------------------------------------
-- costo se calcula como 40%-70% del precio en la misma subquery
-- (sub), para garantizar costo < precio siempre (margen real entre
-- 30% y 60%). Si se generaran precio y costo con llamadas random()
-- independientes no habría garantía de esa relación.
-- categoria_id: se numeran las categorías con row_number() y se
-- generan índices aleatorios (cat_rn) directamente en el SELECT de
-- la subquery — evaluados fila por fila, sin ambigüedad para el
-- planner — y se casan con un JOIN normal (no LATERAL).
WITH cat_numeradas AS (
    SELECT id, row_number() OVER () AS rn
    FROM categorias
),
total_categorias AS (
    SELECT count(*) AS n FROM categorias
)
INSERT INTO productos (sku, nombre, categoria_id, precio, costo, stock_actual, activo, created_at)
SELECT
    'SKU-' || lpad(sub.i::text, 5, '0'),
    'Producto Demo ' || sub.i,
    cat.id,
    sub.precio,
    round((sub.precio * (random() * 0.3 + 0.4))::numeric, 2),
    floor(random() * 200)::int,
    (random() > 0.1),
    now() - (random() * interval '600 days')
FROM (
    SELECT
        i,
        round((random() * 490 + 10)::numeric, 2) AS precio,
        floor(random() * (SELECT n FROM total_categorias) + 1)::int AS cat_rn
    FROM generate_series(1, 200) AS i
) sub
JOIN cat_numeradas cat ON cat.rn = sub.cat_rn;

-- Verificación: distribución de productos entre categorías (no debe
-- haber una sola categoría con los 200 productos).
-- SELECT categoria_id, count(*) FROM productos GROUP BY categoria_id ORDER BY count(*) DESC;

-- ------------------------------------------------------------
-- 4. pedidos (2,000 registros) — VERSIÓN CORREGIDA con row_number()
-- ------------------------------------------------------------
-- total se deja en 0 a propósito: se recalcula más abajo a partir
-- del detalle real de cada pedido (nunca se "inventa" un total).
WITH cli_numerados AS (
    SELECT id, row_number() OVER () AS rn
    FROM clientes
),
total_clientes AS (
    SELECT count(*) AS n FROM clientes
)
INSERT INTO pedidos (cliente_id, estado, total, fecha_pedido)
SELECT
    cli.id,
    (ARRAY['pendiente','pagado','enviado','entregado','cancelado'])[floor(random()*5+1)]::estado_pedido,
    0,
    now() - (random() * interval '365 days')
FROM (
    SELECT
        i,
        floor(random() * (SELECT n FROM total_clientes) + 1)::int AS cli_rn
    FROM generate_series(1, 2000) AS i
) sub
JOIN cli_numerados cli ON cli.rn = sub.cli_rn;

-- Verificación: debe haber varios cientos de clientes distintos, no
-- uno solo dominando todos los pedidos.
-- SELECT count(DISTINCT cliente_id) FROM pedidos;
-- SELECT cliente_id, count(*) FROM pedidos GROUP BY cliente_id ORDER BY count(*) DESC LIMIT 10;

-- ------------------------------------------------------------
-- 5. detalle_pedidos — VERSIÓN CORREGIDA con row_number()
-- ------------------------------------------------------------
-- lineas_por_pedido: aquí generate_series(1, floor(random()*5+1))
-- sí funciona bien dentro de un CTE normal (sin LATERAL) porque
-- random() está en la misma proyección que genera las filas de
-- pedidos (una fila de pedidos entra, un número aleatorio de líneas
-- sale) — no depende de una subquery aparte evaluada una sola vez.
-- El producto de cada línea sí necesitaba el patrón row_number()+JOIN
-- porque ahí sí había una subquery de selección aleatoria separada.
WITH prod_numerados AS (
    SELECT id, precio, row_number() OVER () AS rn
    FROM productos
),
total_productos AS (
    SELECT count(*) AS n FROM productos
),
lineas_por_pedido AS (
    SELECT
        p.id AS pedido_id,
        generate_series(1, floor(random() * 5 + 1)::int) AS linea
    FROM pedidos p
)
INSERT INTO detalle_pedidos (pedido_id, producto_id, cantidad, precio_unitario)
SELECT
    lp.pedido_id,
    prod.id,
    floor(random() * 4 + 1)::int,       -- cantidad entre 1 y 4
    prod.precio                          -- precio vigente al momento de "la venta"
FROM (
    SELECT
        pedido_id,
        linea,
        floor(random() * (SELECT n FROM total_productos) + 1)::int AS prod_rn
    FROM lineas_por_pedido
) lp
JOIN prod_numerados prod ON prod.rn = lp.prod_rn;

-- Verificación: conteo por producto debe estar repartido, no
-- concentrado en uno solo.
-- SELECT count(*) FROM detalle_pedidos;
-- SELECT producto_id, count(*) FROM detalle_pedidos GROUP BY producto_id ORDER BY count(*) DESC LIMIT 10;

-- ------------------------------------------------------------
-- 6. Recalcular total en pedidos a partir del detalle real
-- ------------------------------------------------------------
-- Patrón UPDATE ... FROM (subquery agregada): forma estándar en
-- Postgres de actualizar una tabla en base a datos agregados de otra.
UPDATE pedidos SET total = 0;

UPDATE pedidos p
SET total = sub.total_calculado
FROM (
    SELECT pedido_id, sum(cantidad * precio_unitario) AS total_calculado
    FROM detalle_pedidos
    GROUP BY pedido_id
) sub
WHERE p.id = sub.pedido_id;

-- Verificación: no debe haber pedidos cuyo total no cuadre con la
-- suma real del detalle (excepto pedidos sin líneas, que quedan en 0
-- correctamente).
-- SELECT p.id, p.total, sum(d.cantidad * d.precio_unitario) AS total_real
-- FROM pedidos p
-- JOIN detalle_pedidos d ON d.pedido_id = p.id
-- GROUP BY p.id, p.total
-- HAVING p.total != sum(d.cantidad * d.precio_unitario)
-- LIMIT 5;

-- ------------------------------------------------------------
-- 7. pagos
-- ------------------------------------------------------------
-- Coherencia lógica con el estado del pedido (no solo integridad
-- referencial): pagado/enviado/entregado -> pago exitoso;
-- cancelado -> fallido o reembolsado; el resto -> pendiente.
-- fecha_pago siempre después de fecha_pedido (coherencia temporal).
-- No se genera pago para pedidos sin líneas de detalle (total = 0).
INSERT INTO pagos (pedido_id, monto, metodo, estado, fecha_pago)
SELECT
    p.id,
    p.total,
    (ARRAY['tarjeta_credito','tarjeta_debito','pse','efectivo'])[floor(random()*4+1)]::metodo_pago,
    CASE
        WHEN p.estado IN ('pagado','enviado','entregado') THEN 'exitoso'
        WHEN p.estado = 'cancelado' THEN (ARRAY['fallido','reembolsado'])[floor(random()*2+1)]
        ELSE 'pendiente'
    END::estado_pago,
    p.fecha_pedido + (random() * interval '2 days')
FROM pedidos p
WHERE p.total > 0;

-- Verificación: pagado/enviado/entregado siempre debe caer con
-- estado de pago "exitoso", nunca con "fallido".
-- SELECT count(*) FROM pagos;
-- SELECT p.estado AS estado_pedido, pg.estado AS estado_pago, count(*)
-- FROM pedidos p JOIN pagos pg ON pg.pedido_id = p.id
-- GROUP BY p.estado, pg.estado
-- ORDER BY 1, 2;

-- ------------------------------------------------------------
-- 8. inventario_movimientos
-- ------------------------------------------------------------
-- Salidas: una por cada línea de detalle_pedidos vendida.
INSERT INTO inventario_movimientos (producto_id, tipo, cantidad, motivo, referencia_pedido_id, fecha)
SELECT
    d.producto_id,
    'salida',
    d.cantidad,
    'Venta - Pedido #' || d.pedido_id,
    d.pedido_id,
    p.fecha_pedido
FROM detalle_pedidos d
JOIN pedidos p ON p.id = d.pedido_id;

-- Entradas: reabastecimientos aleatorios, sin pedido asociado
-- (~3 reabastecimientos por producto en promedio).
INSERT INTO inventario_movimientos (producto_id, tipo, cantidad, motivo, referencia_pedido_id, fecha)
SELECT
    prod.id,
    'entrada',
    floor(random() * 100 + 20)::int,
    'Reabastecimiento de proveedor',
    NULL,
    now() - (random() * interval '400 days')
FROM productos prod
CROSS JOIN generate_series(1, 3);

-- SELECT count(*) FROM inventario_movimientos;
-- SELECT tipo, count(*) FROM inventario_movimientos GROUP BY tipo;

-- ------------------------------------------------------------
-- 9. resenas
-- ------------------------------------------------------------
-- Solo clientes que realmente compraron un producto pueden
-- reseñarlo (regla de coherencia de negocio, no solo FK).
-- DISTINCT ON (producto_id, cliente_id): un cliente puede haber
-- comprado el mismo producto en pedidos distintos, generando
-- duplicados; DISTINCT ON se queda con una sola fila por combinación
-- (la primera según ORDER BY), evitando violar el UNIQUE del esquema.
-- WHERE random() < 0.35: solo el 35% de las compras generan reseña.
INSERT INTO resenas (producto_id, cliente_id, calificacion, comentario, fecha)
SELECT DISTINCT ON (d.producto_id, p.cliente_id)
    d.producto_id,
    p.cliente_id,
    floor(random() * 5 + 1)::int,
    (ARRAY[
        'Muy buen producto, cumplió mis expectativas',
        'Calidad regular, esperaba más',
        'Excelente relación calidad-precio',
        'Llegó rápido y en buen estado',
        'No lo recomiendo, mala experiencia',
        NULL
    ])[floor(random()*6+1)],
    p.fecha_pedido + (random() * interval '20 days')
FROM detalle_pedidos d
JOIN pedidos p ON p.id = d.pedido_id
WHERE random() < 0.35
ORDER BY d.producto_id, p.cliente_id, random();

-- SELECT count(*) FROM resenas;
-- SELECT round(avg(calificacion), 2) FROM resenas;
