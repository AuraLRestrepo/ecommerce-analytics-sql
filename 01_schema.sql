-- ============================================================
-- 01_schema.sql
-- Esquema del proyecto "Sistema de analítica para e-commerce"
-- Motor: PostgreSQL 16
--
-- Orden de ejecución: los CREATE TYPE deben correr antes que
-- cualquier CREATE TABLE que los use (Postgres exige que el
-- tipo exista antes de referenciarlo en una columna).
-- ============================================================

-- ------------------------------------------------------------
-- Tipos ENUM
-- ------------------------------------------------------------
-- Se usa ENUM en vez de VARCHAR + CHECK porque los conjuntos de
-- valores son cerrados y estables. ENUM se almacena internamente
-- como entero (más eficiente) y documenta el dominio de valores
-- directamente en el esquema. Si el conjunto de valores cambiara
-- con frecuencia, VARCHAR + CHECK sería más flexible operacionalmente
-- (agregar un valor a un CHECK es un ALTER TABLE simple; agregar un
-- valor a un ENUM requiere ALTER TYPE ... ADD VALUE, con restricciones
-- de uso dentro de transacciones).
CREATE TYPE estado_pedido AS ENUM ('pendiente', 'pagado', 'enviado', 'entregado', 'cancelado');
CREATE TYPE estado_pago AS ENUM ('pendiente', 'exitoso', 'fallido', 'reembolsado');
CREATE TYPE metodo_pago AS ENUM ('tarjeta_credito', 'tarjeta_debito', 'pse', 'efectivo');
CREATE TYPE tipo_movimiento AS ENUM ('entrada', 'salida');

-- ------------------------------------------------------------
-- 1. categorias
-- ------------------------------------------------------------
-- FK recursiva (self-reference) para modelar una jerarquía de
-- profundidad variable (Electrónica > Celulares > Accesorios...).
-- ON DELETE SET NULL: borrar una categoría padre no borra en cascada
-- a sus hijas, solo las deja huérfanas (decisión de negocio: prefiero
-- categorías sin padre a perder datos por accidente).
-- TIMESTAMPTZ (no TIMESTAMP): Postgres guarda internamente en UTC y
-- convierte a la zona horaria de la sesión al mostrar. Usar TIMESTAMP
-- sin zona horaria es un problema en cuanto la app tenga usuarios en
-- husos horarios distintos.
CREATE TABLE categorias (
    id                  SERIAL PRIMARY KEY,
    nombre              VARCHAR(100) NOT NULL,
    categoria_padre_id  INT REFERENCES categorias(id) ON DELETE SET NULL,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ------------------------------------------------------------
-- 2. productos
-- ------------------------------------------------------------
-- NUMERIC(10,2) y nunca FLOAT/REAL para dinero: FLOAT es punto
-- flotante binario y no representa exactamente ciertos decimales
-- (errores de centavos que se acumulan). NUMERIC es precisión exacta.
-- CHECK a nivel de BD: última línea de defensa de integridad, no
-- depender solo de validación en la capa de aplicación.
-- ON DELETE RESTRICT en categoria_id: un producto siempre debe tener
-- categoría, no puede quedar huérfano.
CREATE TABLE productos (
    id              SERIAL PRIMARY KEY,
    sku             VARCHAR(50) NOT NULL UNIQUE,
    nombre          VARCHAR(200) NOT NULL,
    categoria_id    INT NOT NULL REFERENCES categorias(id) ON DELETE RESTRICT,
    precio          NUMERIC(10,2) NOT NULL CHECK (precio >= 0),
    costo           NUMERIC(10,2) NOT NULL CHECK (costo >= 0),
    stock_actual    INT NOT NULL DEFAULT 0 CHECK (stock_actual >= 0),
    activo          BOOLEAN NOT NULL DEFAULT true,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ------------------------------------------------------------
-- 3. clientes
-- ------------------------------------------------------------
-- email UNIQUE a nivel de BD: la integridad de datos no debe
-- depender solo del código de aplicación.
CREATE TABLE clientes (
    id              SERIAL PRIMARY KEY,
    email           VARCHAR(150) NOT NULL UNIQUE,
    nombre          VARCHAR(150) NOT NULL,
    pais            VARCHAR(60),
    fecha_registro  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ------------------------------------------------------------
-- 4. pedidos
-- ------------------------------------------------------------
-- total tiene DEFAULT 0: se recalcula siempre a partir del detalle
-- real (detalle_pedidos), nunca se inserta "inventado" — el total
-- es una consecuencia de los datos, no una fuente de verdad aparte.
CREATE TABLE pedidos (
    id             SERIAL PRIMARY KEY,
    cliente_id     INT NOT NULL REFERENCES clientes(id) ON DELETE RESTRICT,
    estado         estado_pedido NOT NULL DEFAULT 'pendiente',
    total          NUMERIC(10,2) NOT NULL DEFAULT 0 CHECK (total >= 0),
    fecha_pedido   TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ------------------------------------------------------------
-- 5. detalle_pedidos (tabla puente N:M entre pedidos y productos)
-- ------------------------------------------------------------
-- Usa un id SERIAL propio (surrogate key) en vez de PRIMARY KEY
-- compuesta (pedido_id, producto_id), porque:
--   1. Un pedido puede repetir el mismo producto en líneas distintas
--      (ej. misma prenda en tallas distintas, tratadas como líneas
--      separadas) — una PK compuesta lo bloquearía.
--   2. Facilita relaciones hacia tablas hijas que necesiten apuntar
--      a una línea específica del pedido (ej. devoluciones).
--   3. Un id entero simple es más liviano de indexar que una PK
--      compuesta, sobre todo cuando se usa como FK en otras tablas.
-- Regla general: clave compuesta cuando la combinación de FKs ES la
-- entidad completa y no se referencia individualmente; id surrogate
-- cuando pueden existir varias filas válidas con la misma combinación
-- de FKs o se anticipa que otras tablas apuntarán a esa fila.
--
-- precio_unitario se guarda en el detalle (no se referencia
-- productos.precio) porque el precio pudo cambiar después de la
-- venta y se necesita el histórico exacto de lo cobrado.
--
-- ON DELETE CASCADE en pedido_id: si se borra el pedido, sus líneas
-- no tienen sentido sin él.
-- ON DELETE RESTRICT en producto_id: no se puede borrar un producto
-- que ya fue vendido (protege el histórico); en la práctica se usa
-- soft delete (productos.activo = false) en vez de DELETE real.
CREATE TABLE detalle_pedidos (
    id               SERIAL PRIMARY KEY,
    pedido_id        INT NOT NULL REFERENCES pedidos(id) ON DELETE CASCADE,
    producto_id      INT NOT NULL REFERENCES productos(id) ON DELETE RESTRICT,
    cantidad         INT NOT NULL CHECK (cantidad > 0),
    precio_unitario  NUMERIC(10,2) NOT NULL CHECK (precio_unitario >= 0)
);

-- ------------------------------------------------------------
-- 6. pagos
-- ------------------------------------------------------------
-- Tabla separada de pedidos porque un pedido puede tener, en teoría,
-- varios intentos de pago (uno fallido, uno exitoso). Dos ENUMs
-- distintos (metodo vs estado) porque son conceptos independientes;
-- mezclarlos obligaría a valores tipo "tarjeta_credito_fallido".
CREATE TABLE pagos (
    id          SERIAL PRIMARY KEY,
    pedido_id   INT NOT NULL REFERENCES pedidos(id) ON DELETE CASCADE,
    monto       NUMERIC(10,2) NOT NULL CHECK (monto >= 0),
    metodo      metodo_pago NOT NULL,
    estado      estado_pago NOT NULL DEFAULT 'pendiente',
    fecha_pago  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ------------------------------------------------------------
-- 7. inventario_movimientos
-- ------------------------------------------------------------
-- Log de auditoría de stock: productos.stock_actual nunca se
-- actualiza a mano, siempre a través de este historial de
-- entradas/salidas (fuente de verdad + trazabilidad).
-- referencia_pedido_id es nullable: una salida por venta sí tiene
-- pedido asociado, pero una entrada por reabastecimiento no.
CREATE TABLE inventario_movimientos (
    id                    SERIAL PRIMARY KEY,
    producto_id           INT NOT NULL REFERENCES productos(id) ON DELETE RESTRICT,
    tipo                  tipo_movimiento NOT NULL,
    cantidad              INT NOT NULL CHECK (cantidad > 0),
    motivo                VARCHAR(200),
    referencia_pedido_id  INT REFERENCES pedidos(id) ON DELETE SET NULL,
    fecha                 TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ------------------------------------------------------------
-- 8. resenas (tabla puente N:M entre productos y clientes)
-- ------------------------------------------------------------
-- SMALLINT para calificacion: no se necesita un INT de 4 bytes para
-- un valor 1-5. TEXT (no VARCHAR) para comentario: no hay un límite
-- de negocio razonable para el texto libre.
-- UNIQUE (producto_id, cliente_id): un cliente solo puede reseñar un
-- producto una vez — aquí sí es correcto como constraint porque es
-- una regla de negocio real, no una limitación técnica de modelado.
CREATE TABLE resenas (
    id            SERIAL PRIMARY KEY,
    producto_id   INT NOT NULL REFERENCES productos(id) ON DELETE CASCADE,
    cliente_id    INT NOT NULL REFERENCES clientes(id) ON DELETE CASCADE,
    calificacion  SMALLINT NOT NULL CHECK (calificacion BETWEEN 1 AND 5),
    comentario    TEXT,
    fecha         TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (producto_id, cliente_id)
);

-- ------------------------------------------------------------
-- Modelo de relaciones (resumen)
-- ------------------------------------------------------------
-- categorias (1) ──< (N) categorias            [self-reference, 1:N]
-- categorias (1) ──< (N) productos              [1:N]
-- clientes   (1) ──< (N) pedidos                [1:N]
-- pedidos    (1) ──< (N) detalle_pedidos >── (N) productos   [N:M via tabla puente]
-- pedidos    (1) ──< (N) pagos                  [1:N]
-- productos  (1) ──< (N) inventario_movimientos [1:N]
-- productos  (1) ──< (N) resenas >── (N) clientes            [N:M via tabla puente]
