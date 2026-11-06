-- shop schema. audit_log has no primary key on purpose: many old databases have tables like it, and
-- logical replication treats them differently.
create table customers (
  id serial primary key,
  email text not null unique,
  name text not null,
  created_at timestamptz not null default now()
);

create table products (
  id serial primary key,
  sku text not null unique,
  name text not null,
  price_cents integer not null check (price_cents >= 0),
  initial_stock integer not null,
  stock integer not null check (stock >= 0)
);

create table orders (
  id bigserial primary key,
  customer_id integer not null references customers (id),
  total_cents bigint not null,
  status text not null default 'placed',
  created_at timestamptz not null default now()
);
create index orders_customer on orders (customer_id);

create table order_items (
  id bigserial primary key,
  order_id bigint not null references orders (id),
  product_id integer not null references products (id),
  qty integer not null check (qty > 0),
  price_cents integer not null
);
create index order_items_order on order_items (order_id);

create table uploads (
  id uuid primary key,
  name text not null,
  size integer not null,
  sha256 text not null,
  created_at timestamptz not null default now()
);

create table audit_log (
  at timestamptz not null default now(),
  action text not null,
  detail jsonb
);

-- Generated data: 200 customers, 50 products, 5000 past orders.
insert into customers (email, name)
select 'c' || g || '@example.com', 'Customer ' || g from generate_series(1, 200) g;

insert into products (sku, name, price_cents, initial_stock, stock)
select 'SKU-' || g, 'Product ' || g, 100 + g * 37, 1000000, 1000000 from generate_series(1, 50) g;

with made as (
  insert into orders (customer_id, total_cents, created_at)
  select 1 + g % 200, 0, now() - (g || ' minutes')::interval from generate_series(1, 5000) g
  returning id
), lines as (
  insert into order_items (order_id, product_id, qty, price_cents)
  select m.id, 1 + (m.id * 7 + n) % 50, 1 + n, 100 + (1 + (m.id * 7 + n) % 50) * 37
  from made m cross join generate_series(0, 1) n
  returning product_id, qty
)
update products p set stock = p.stock - s.sold
from (select product_id, sum(qty) as sold from lines group by product_id) s
where p.id = s.product_id;

-- A separate statement: one statement cannot update rows it inserted.
update orders o set total_cents = t.total
from (select order_id, sum(qty * price_cents) as total from order_items group by order_id) t
where o.id = t.order_id;

insert into audit_log (action, detail) select 'seed', jsonb_build_object('n', g) from generate_series(1, 2000) g;
