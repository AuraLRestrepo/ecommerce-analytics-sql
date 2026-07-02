# Notas técnicas del proyecto

## Estado actual

- Esquema completo (8 tablas + 4 ENUMs): `01_schema.sql`
- Datos de prueba generados y corregidos: `02_seed_data.sql`
- Queries analíticas (CTE recursivo, window functions): `03_queries_analiticas.sql`
- Triggers y reconciliación de stock: `04_triggers_procedures.sql`
- Índices y `EXPLAIN ANALYZE` antes/después: `05_optimizacion.sql`
- Diagrama ER: sección "Diagrama ER" del README + `schema.dbml`

## Resuelto

- La inconsistencia de `categorias` (7 filas, jerarquía rota) se
  corrigió al correr `scripts/generar_datos.py`, que trunca y
  reinserta todo el dataset desde cero con la jerarquía correcta
  (16 categorías, 4 raíz). Confirmado con `tests/test_seed_data.py`.
- Se aplicaron los triggers de `04_triggers_procedures.sql` a la base
  real (antes solo existían como archivo, nunca se habían ejecutado):
  verificado manualmente que `trg_actualizar_stock` y
  `trg_auditar_cambio_estado_pedido` funcionan correctamente.
- Se agregó `scripts/generar_datos.py` (generador de datos en Python
  con Faker + psycopg2, alternativa a `02_seed_data.sql`) y
  `tests/test_seed_data.py` (10 tests de integridad, todos pasando).

## Bug resuelto: aleatoriedad no correlacionada tratada como constante (InitPlan)

Al generar datos de prueba con subqueries escalares tipo:
`(SELECT id FROM tabla ORDER BY random() LIMIT 1)`

Postgres puede optimizar la subquery como InitPlan si no detecta
correlación real con la fila externa, evaluándola una sola vez
para toda la query en lugar de una vez por fila. Esto causó que
miles de registros quedaran asignados a un único id aleatorio.

`LATERAL` no resuelve esto por sí solo si la subquery interna
no referencia columnas de la tabla externa.

Solución: generar el índice aleatorio como expresión en el SELECT
(se evalúa por fila garantizado) y unirlo vía JOIN explícito contra
la tabla objetivo numerada con row_number().

## Bug resuelto: subquery correlacionada de 3 niveles sin resultados

La query de "clientes con gasto por encima del promedio de su país"
escrita como subquery correlacionada anidada a tres niveles
(HAVING -> subquery avg -> subquery gasto_pais) no devolvía filas,
aun con datos base correctos. Se descartó la depuración profunda del
anidamiento y se reescribió con CTEs + window function
(`AVG(...) OVER (PARTITION BY pais)`), que además es más legible y
evita re-ejecutar una subquery por cada cliente. Ver la versión final
en `03_queries_analiticas.sql`.