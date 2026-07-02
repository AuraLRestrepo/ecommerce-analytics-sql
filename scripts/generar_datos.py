"""
Generador de datos de prueba en Python (alternativa a 02_seed_data.sql).

Reproduce el mismo dataset que la versión SQL pura (categorias,
clientes, productos, pedidos, detalle_pedidos, pagos,
inventario_movimientos, resenas), pero con nombres/emails más
realistas vía Faker, y con la aleatoriedad resuelta en Python en vez
de en el motor de la base de datos (evita por completo el problema de
InitPlan que tuvimos con SQL puro, documentado en notes.md).

Uso:
    pip install -r requirements.txt
    python generar_datos.py
"""

import os
import random
from datetime import timedelta

import psycopg2
from psycopg2.extras import execute_values
from faker import Faker

DB_CONFIG = {
    "host": os.environ.get("PGHOST", "localhost"),
    "port": os.environ.get("PGPORT", "5432"),
    "user": os.environ.get("PGUSER", "admin"),
    "password": os.environ.get("PGPASSWORD", "admin123"),
    "dbname": os.environ.get("PGDATABASE", "ecommerce_analytics"),
}

N_CLIENTES = 500
N_PRODUCTOS = 200
N_PEDIDOS = 2000

PAISES = ["Colombia", "México", "Argentina", "Chile", "Perú", "España"]
ESTADOS_PEDIDO = ["pendiente", "pagado", "enviado", "entregado", "cancelado"]
METODOS_PAGO = ["tarjeta_credito", "tarjeta_debito", "pse", "efectivo"]
COMENTARIOS_RESENA = [
    "Muy buen producto, cumplió mis expectativas",
    "Calidad regular, esperaba más",
    "Excelente relación calidad-precio",
    "Llegó rápido y en buen estado",
    "No lo recomiendo, mala experiencia",
    None,
]

fake = Faker("es_ES")


def truncar_todo(cur):
    cur.execute(
        """
        TRUNCATE TABLE resenas, inventario_movimientos, pagos,
                       detalle_pedidos, pedidos, productos, clientes,
                       categorias
        RESTART IDENTITY CASCADE;
        """
    )


def seed_categorias(cur):
    raiz = ["Electrónica", "Ropa", "Hogar", "Deportes"]
    raiz_ids = []
    for nombre in raiz:
        cur.execute(
            "INSERT INTO categorias (nombre, categoria_padre_id) VALUES (%s, NULL) RETURNING id",
            (nombre,),
        )
        raiz_ids.append(cur.fetchone()[0])

    electronica_id, ropa_id, hogar_id, deportes_id = raiz_ids

    nivel2 = [
        ("Celulares", electronica_id),
        ("Laptops", electronica_id),
        ("Audio", electronica_id),
        ("Ropa Hombre", ropa_id),
        ("Ropa Mujer", ropa_id),
        ("Muebles", hogar_id),
        ("Cocina", hogar_id),
        ("Fitness", deportes_id),
        ("Ciclismo", deportes_id),
    ]
    nivel2_ids = {}
    for nombre, padre_id in nivel2:
        cur.execute(
            "INSERT INTO categorias (nombre, categoria_padre_id) VALUES (%s, %s) RETURNING id",
            (nombre, padre_id),
        )
        nivel2_ids[nombre] = cur.fetchone()[0]

    nivel3 = [
        ("Accesorios para celulares", nivel2_ids["Celulares"]),
        ("Fundas y protectores", nivel2_ids["Celulares"]),
        ("Accesorios para laptops", nivel2_ids["Laptops"]),
    ]
    for nombre, padre_id in nivel3:
        cur.execute(
            "INSERT INTO categorias (nombre, categoria_padre_id) VALUES (%s, %s)",
            (nombre, padre_id),
        )


def seed_clientes(cur, n=N_CLIENTES):
    filas = []
    for _ in range(n):
        dias_atras = random.uniform(0, 730)
        fecha_registro = fake.date_time_between(
            start_date=f"-{int(dias_atras) + 1}d", end_date="now"
        )
        filas.append(
            (fake.unique.email(), fake.name(), random.choice(PAISES), fecha_registro)
        )
    execute_values(
        cur,
        "INSERT INTO clientes (email, nombre, pais, fecha_registro) VALUES %s",
        filas,
    )


def seed_productos(cur, categoria_ids, n=N_PRODUCTOS):
    filas = []
    for i in range(1, n + 1):
        precio = round(random.uniform(10, 500), 2)
        costo = round(precio * random.uniform(0.4, 0.7), 2)
        dias_atras = random.uniform(0, 600)
        creado = fake.date_time_between(start_date=f"-{int(dias_atras) + 1}d", end_date="now")
        filas.append(
            (
                f"SKU-{i:05d}",
                f"Producto Demo {i}",
                random.choice(categoria_ids),
                precio,
                costo,
                random.randint(0, 200),
                random.random() > 0.1,
                creado,
            )
        )
    execute_values(
        cur,
        """
        INSERT INTO productos
            (sku, nombre, categoria_id, precio, costo, stock_actual, activo, created_at)
        VALUES %s
        """,
        filas,
    )


def seed_pedidos(cur, cliente_ids, n=N_PEDIDOS):
    filas = []
    for _ in range(n):
        dias_atras = random.uniform(0, 365)
        fecha = fake.date_time_between(start_date=f"-{int(dias_atras) + 1}d", end_date="now")
        filas.append((random.choice(cliente_ids), random.choice(ESTADOS_PEDIDO), 0, fecha))
    execute_values(
        cur,
        "INSERT INTO pedidos (cliente_id, estado, total, fecha_pedido) VALUES %s",
        filas,
        template="(%s, %s::estado_pedido, %s, %s)",
    )


def seed_detalle_pedidos(cur, pedido_ids, productos):
    """productos: lista de tuplas (id, precio)."""
    filas = []
    for pedido_id in pedido_ids:
        n_lineas = random.randint(1, 5)
        for _ in range(n_lineas):
            producto_id, precio = random.choice(productos)
            cantidad = random.randint(1, 4)
            filas.append((pedido_id, producto_id, cantidad, precio))
    execute_values(
        cur,
        "INSERT INTO detalle_pedidos (pedido_id, producto_id, cantidad, precio_unitario) VALUES %s",
        filas,
    )


def recalcular_totales(cur):
    cur.execute("UPDATE pedidos SET total = 0")
    cur.execute(
        """
        UPDATE pedidos p
        SET total = sub.total_calculado
        FROM (
            SELECT pedido_id, sum(cantidad * precio_unitario) AS total_calculado
            FROM detalle_pedidos
            GROUP BY pedido_id
        ) sub
        WHERE p.id = sub.pedido_id
        """
    )


def seed_pagos(cur):
    cur.execute("SELECT id, estado, total, fecha_pedido FROM pedidos WHERE total > 0")
    pedidos = cur.fetchall()

    filas = []
    for pedido_id, estado, total, fecha_pedido in pedidos:
        if estado in ("pagado", "enviado", "entregado"):
            estado_pago = "exitoso"
        elif estado == "cancelado":
            estado_pago = random.choice(["fallido", "reembolsado"])
        else:
            estado_pago = "pendiente"

        fecha_pago = fecha_pedido + timedelta(days=random.uniform(0, 2))
        filas.append((pedido_id, total, random.choice(METODOS_PAGO), estado_pago, fecha_pago))

    execute_values(
        cur,
        "INSERT INTO pagos (pedido_id, monto, metodo, estado, fecha_pago) VALUES %s",
        filas,
        template="(%s, %s, %s::metodo_pago, %s::estado_pago, %s)",
    )


def seed_inventario_movimientos(cur, producto_ids):
    cur.execute(
        "SELECT producto_id, cantidad, pedido_id, fecha_pedido "
        "FROM detalle_pedidos d JOIN pedidos p ON p.id = d.pedido_id"
    )
    ventas = cur.fetchall()

    filas = [
        (producto_id, "salida", cantidad, f"Venta - Pedido #{pedido_id}", pedido_id, fecha)
        for producto_id, cantidad, pedido_id, fecha in ventas
    ]

    for producto_id in producto_ids:
        for _ in range(3):
            filas.append(
                (
                    producto_id,
                    "entrada",
                    random.randint(20, 120),
                    "Reabastecimiento de proveedor",
                    None,
                    fake.date_time_between(start_date="-400d", end_date="now"),
                )
            )

    execute_values(
        cur,
        """
        INSERT INTO inventario_movimientos
            (producto_id, tipo, cantidad, motivo, referencia_pedido_id, fecha)
        VALUES %s
        """,
        filas,
        template="(%s, %s::tipo_movimiento, %s, %s, %s, %s)",
    )


def seed_resenas(cur):
    cur.execute(
        "SELECT d.producto_id, p.cliente_id, p.fecha_pedido "
        "FROM detalle_pedidos d JOIN pedidos p ON p.id = d.pedido_id"
    )
    compras = cur.fetchall()

    vistos = set()
    filas = []
    for producto_id, cliente_id, fecha_pedido in compras:
        clave = (producto_id, cliente_id)
        if clave in vistos:
            continue
        if random.random() >= 0.35:
            continue
        vistos.add(clave)
        fecha = fecha_pedido + timedelta(days=random.uniform(0, 20))
        filas.append(
            (
                producto_id,
                cliente_id,
                random.randint(1, 5),
                random.choice(COMENTARIOS_RESENA),
                fecha,
            )
        )

    execute_values(
        cur,
        "INSERT INTO resenas (producto_id, cliente_id, calificacion, comentario, fecha) VALUES %s",
        filas,
    )


def main():
    conn = psycopg2.connect(**DB_CONFIG)
    conn.autocommit = False
    try:
        with conn.cursor() as cur:
            print("Truncando tablas...")
            truncar_todo(cur)

            print("Insertando categorias...")
            seed_categorias(cur)

            print(f"Insertando {N_CLIENTES} clientes...")
            seed_clientes(cur)

            cur.execute("SELECT id FROM categorias")
            categoria_ids = [row[0] for row in cur.fetchall()]

            print(f"Insertando {N_PRODUCTOS} productos...")
            seed_productos(cur, categoria_ids)

            cur.execute("SELECT id FROM clientes")
            cliente_ids = [row[0] for row in cur.fetchall()]

            print(f"Insertando {N_PEDIDOS} pedidos...")
            seed_pedidos(cur, cliente_ids)

            cur.execute("SELECT id, precio FROM productos")
            productos = cur.fetchall()
            cur.execute("SELECT id FROM pedidos")
            pedido_ids = [row[0] for row in cur.fetchall()]

            print("Insertando detalle_pedidos...")
            seed_detalle_pedidos(cur, pedido_ids, productos)

            print("Recalculando totales de pedidos...")
            recalcular_totales(cur)

            print("Insertando pagos...")
            seed_pagos(cur)

            producto_ids = [p[0] for p in productos]
            print("Insertando inventario_movimientos...")
            seed_inventario_movimientos(cur, producto_ids)

            print("Insertando resenas...")
            seed_resenas(cur)

        conn.commit()
        print("Listo. Datos generados y confirmados.")
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


if __name__ == "__main__":
    main()
