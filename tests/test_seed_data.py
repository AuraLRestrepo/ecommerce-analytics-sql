"""
Tests de integridad para los datos generados por
scripts/generar_datos.py.

No prueban la lógica de negocio en abstracto: consultan la base de
datos real y verifican que los datos cargados cumplan las reglas de
coherencia que se diseñaron a lo largo del proyecto (costo < precio,
totales que cuadran con el detalle, distribución sin el bug de
InitPlan, coherencia pago/estado, etc.).

Uso:
    pip install -r requirements.txt
    pytest -v
"""

import os

import psycopg2
import pytest

DB_CONFIG = {
    "host": os.environ.get("PGHOST", "localhost"),
    "port": os.environ.get("PGPORT", "5432"),
    "user": os.environ.get("PGUSER", "admin"),
    "password": os.environ.get("PGPASSWORD", "admin123"),
    "dbname": os.environ.get("PGDATABASE", "ecommerce_analytics"),
}


@pytest.fixture(scope="module")
def conn():
    connection = psycopg2.connect(**DB_CONFIG)
    yield connection
    connection.close()


@pytest.fixture()
def cur(conn):
    with conn.cursor() as cursor:
        yield cursor


def test_row_counts(cur):
    cur.execute("SELECT count(*) FROM clientes")
    assert cur.fetchone()[0] == 500

    cur.execute("SELECT count(*) FROM productos")
    assert cur.fetchone()[0] == 200

    cur.execute("SELECT count(*) FROM pedidos")
    assert cur.fetchone()[0] == 2000

    cur.execute("SELECT count(*) FROM categorias")
    assert cur.fetchone()[0] == 16


def test_categorias_jerarquia(cur):
    cur.execute("SELECT count(*) FROM categorias WHERE categoria_padre_id IS NULL")
    assert cur.fetchone()[0] == 4, "deben existir exactamente 4 categorías raíz"

    # Sin ciclos: toda categoria_padre_id debe apuntar a un id que exista
    cur.execute(
        """
        SELECT count(*) FROM categorias c
        WHERE c.categoria_padre_id IS NOT NULL
        AND NOT EXISTS (SELECT 1 FROM categorias p WHERE p.id = c.categoria_padre_id)
        """
    )
    assert cur.fetchone()[0] == 0


def test_productos_costo_menor_que_precio(cur):
    cur.execute("SELECT count(*) FROM productos WHERE costo >= precio")
    assert cur.fetchone()[0] == 0, "el costo nunca debe ser mayor o igual al precio"


def test_productos_distribuidos_entre_categorias(cur):
    """Guarda contra el bug de InitPlan: todos los productos concentrados
    en una sola categoría."""
    cur.execute(
        "SELECT count(*) FROM (SELECT categoria_id FROM productos GROUP BY categoria_id) sub"
    )
    categorias_usadas = cur.fetchone()[0]
    assert categorias_usadas > 5, (
        f"solo {categorias_usadas} categorías tienen productos; "
        "esperaba distribución entre varias"
    )

    cur.execute(
        """
        SELECT max(n) FROM (
            SELECT categoria_id, count(*) AS n FROM productos GROUP BY categoria_id
        ) sub
        """
    )
    max_por_categoria = cur.fetchone()[0]
    assert max_por_categoria < 200, "ninguna categoría debe concentrar todos los productos"


def test_pedidos_distribuidos_entre_clientes(cur):
    """Misma protección que el test anterior, para pedidos.cliente_id."""
    cur.execute("SELECT count(DISTINCT cliente_id) FROM pedidos")
    clientes_con_pedido = cur.fetchone()[0]
    assert clientes_con_pedido > 100, (
        f"solo {clientes_con_pedido} clientes distintos tienen pedidos"
    )


def test_totales_de_pedido_coinciden_con_el_detalle(cur):
    cur.execute(
        """
        SELECT count(*) FROM (
            SELECT p.id
            FROM pedidos p
            JOIN detalle_pedidos d ON d.pedido_id = p.id
            GROUP BY p.id, p.total
            HAVING p.total != sum(d.cantidad * d.precio_unitario)
        ) sub
        """
    )
    assert cur.fetchone()[0] == 0, "hay pedidos cuyo total no cuadra con su detalle"


def test_pagos_coherentes_con_estado_pedido(cur):
    cur.execute(
        """
        SELECT count(*)
        FROM pedidos p
        JOIN pagos pg ON pg.pedido_id = p.id
        WHERE p.estado IN ('pagado', 'enviado', 'entregado')
        AND pg.estado != 'exitoso'
        """
    )
    assert cur.fetchone()[0] == 0, "todo pedido pagado/enviado/entregado debe tener pago exitoso"


def test_resenas_unicas_por_producto_y_cliente(cur):
    cur.execute(
        """
        SELECT count(*) FROM (
            SELECT producto_id, cliente_id, count(*) AS n
            FROM resenas
            GROUP BY producto_id, cliente_id
            HAVING count(*) > 1
        ) sub
        """
    )
    assert cur.fetchone()[0] == 0, "no debe haber más de una reseña por cliente y producto"


def test_resenas_solo_de_clientes_que_compraron(cur):
    cur.execute(
        """
        SELECT count(*) FROM resenas r
        WHERE NOT EXISTS (
            SELECT 1 FROM detalle_pedidos d
            JOIN pedidos p ON p.id = d.pedido_id
            WHERE d.producto_id = r.producto_id AND p.cliente_id = r.cliente_id
        )
        """
    )
    assert cur.fetchone()[0] == 0, "toda reseña debe corresponder a una compra real"


def test_movimientos_de_salida_igualan_lineas_de_detalle(cur):
    cur.execute("SELECT count(*) FROM detalle_pedidos")
    n_detalle = cur.fetchone()[0]

    cur.execute("SELECT count(*) FROM inventario_movimientos WHERE tipo = 'salida'")
    n_salidas = cur.fetchone()[0]

    assert n_detalle == n_salidas, "debe haber una salida de inventario por cada línea vendida"
