-- ============================================================
-- 03_queries_analiticas.sql
-- Paso 4 del proyecto: CTE recursivo, window functions y
-- comparación contra promedio de grupo.
-- Todas las queries de este archivo fueron probadas y confirmadas
-- funcionando contra el dataset de 02_seed_data.sql.
-- ============================================================

-- ------------------------------------------------------------
-- 1. CTE recursivo — recorrer toda la jerarquía de categorías
-- ------------------------------------------------------------
-- Caso base: categorías raíz (categoria_padre_id IS NULL).
-- Caso recursivo: JOIN de categorias contra el resultado que la
-- propia CTE va acumulando — Postgres itera: en la iteración 1
-- encuentra los hijos directos de las raíces, en la 2 los hijos de
-- esos hijos, y así hasta que una iteración no produce filas nuevas
-- (ahí para automáticamente).
-- nivel incrementa en cada iteración (profundidad); ruta concatena
-- el camino completo (útil para breadcrumbs en un frontend real).
-- Nota: si la jerarquía tuviera referencias circulares esto podría
-- generar un loop infinito; Postgres 14+ ofrece la cláusula CYCLE
-- para protegerse de ese caso (no usada aquí, pero vale mencionarla).
WITH RECURSIVE arbol_categorias AS (
    SELECT
        id,
        nombre,
        categoria_padre_id,
        1 AS nivel,
        nombre::text AS ruta
    FROM categorias
    WHERE categoria_padre_id IS NULL

    UNION ALL

    SELECT
        c.id,
        c.nombre,
        c.categoria_padre_id,
        ac.nivel + 1,
        ac.ruta || ' > ' || c.nombre
    FROM categorias c
    JOIN arbol_categorias ac ON c.categoria_padre_id = ac.id
)
SELECT * FROM arbol_categorias
ORDER BY ruta;

-- ------------------------------------------------------------
-- 2. Window function — ranking de productos por ventas dentro de
--    su categoría
-- ------------------------------------------------------------
-- PARTITION BY c.id: el RANK() se reinicia por cada categoría en vez
-- de rankear todos los productos globalmente.
-- RANK() (no ROW_NUMBER() ni DENSE_RANK()): si dos productos empatan
-- en ingresos, ambos deben verse como "#1" y el siguiente producto es
-- honestamente "#3" (RANK salta números en empates; DENSE_RANK no
-- salta; ROW_NUMBER no reconoce empates, siempre da un número único).
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
GROUP BY c.id, c.nombre, p.id, p.nombre
ORDER BY c.nombre, ranking_en_categoria;

-- ------------------------------------------------------------
-- 3. Window function — running total e ingresos mes a mes
-- ------------------------------------------------------------
-- sum(...) OVER (ORDER BY mes), sin PARTITION BY: running total
-- (acumulado) — cada fila suma su valor más todos los anteriores
-- según el orden.
-- LAG(): valor de la fila anterior en el orden especificado, para
-- comparar "este mes vs. el anterior" sin self-join.
-- NULLIF(x, 0): evita división por cero (si el mes anterior tuvo 0
-- ingresos, la división da NULL en vez de error).
WITH ventas_mensuales AS (
    SELECT
        date_trunc('month', p.fecha_pedido) AS mes,
        sum(d.cantidad * d.precio_unitario) AS ingresos_mes
    FROM pedidos p
    JOIN detalle_pedidos d ON d.pedido_id = p.id
    WHERE p.estado != 'cancelado'
    GROUP BY date_trunc('month', p.fecha_pedido)
)
SELECT
    mes,
    ingresos_mes,
    sum(ingresos_mes) OVER (ORDER BY mes) AS ingresos_acumulados,
    round(
        (ingresos_mes - lag(ingresos_mes) OVER (ORDER BY mes))
        / NULLIF(lag(ingresos_mes) OVER (ORDER BY mes), 0) * 100, 2
    ) AS variacion_pct_mes_anterior
FROM ventas_mensuales
ORDER BY mes;

-- ------------------------------------------------------------
-- 4. Clientes con gasto por encima del promedio de su país
-- ------------------------------------------------------------
-- Versión final funcionando, con window function AVG() OVER
-- (PARTITION BY pais). Es preferible a una subquery correlacionada
-- porque calcula el promedio por país en una sola pasada, sin
-- re-ejecutar una subquery por cada cliente, y separa claramente
-- tres pasos: "gasto por cliente" -> "promedio de referencia" ->
-- "filtrar".
--
-- (La primera versión con subquery correlacionada de 3 niveles de
-- anidamiento no devolvía resultados correctos y quedó descartada
-- en favor de esta reescritura; ver notes.md.)
WITH gasto_por_cliente AS (
    SELECT
        cl.id,
        cl.nombre,
        cl.pais,
        sum(p.total) AS gasto_total
    FROM clientes cl
    JOIN pedidos p ON p.cliente_id = cl.id
    GROUP BY cl.id, cl.nombre, cl.pais
),
con_promedio AS (
    SELECT
        *,
        avg(gasto_total) OVER (PARTITION BY pais) AS promedio_pais
    FROM gasto_por_cliente
)
SELECT nombre, pais, gasto_total, round(promedio_pais, 2) AS promedio_pais
FROM con_promedio
WHERE gasto_total > promedio_pais
ORDER BY pais, gasto_total DESC;
