-- =====================================================================
--  LIBERATE · Datos iniciales (opcional)
--  Carga el catálogo de la tienda y la videoteca del prototipo.
--  Las fotos se suben después desde La tiendita / La videoteca.
-- =====================================================================

insert into public.productos (nombre, categoria, marca, descripcion, costo, precio, promo_pct, tiene_talles, stock, stock_talles, es_servicio, orden) values
  ('Remera Liberate',            'Ropa',         'liberate',     'Algodón peinado 24/1, calce regular. El clásico para entrenar en la plaza.', 9000, 18000, 0, true, 0, '{"S":2,"M":4,"L":4,"XL":2}', false, 1),
  ('Musculosa Dale, liberate.',  'Ropa',         'liberate',     'Liviana y fresca. Para los días que el sol de la plaza pega fuerte.',          7500, 15000, 0, true, 0, '{"S":1,"M":2,"L":2,"XL":1}', false, 2),
  ('Gorra L',                    'Accesorios',   'liberate',     'Gorra de gabardina con la L bordada. Visera curva, regulable.',               6500, 14000, 0, false, 9, '{}', false, 3),
  ('Medias golondrina',          'Accesorios',   'liberate',     'Medias de caña media con golondrinas. Vienen de a par.',                      2800, 6500, 0, false, 20, '{}', false, 4),
  ('Pesa rusa 8 kg',             'Equipamiento', 'liberate',     'Pesa rusa de hierro con base plana. Ideal para swings y goblet.',            30000, 42000, 0, false, 3, '{}', false, 5),
  ('Banda elástica',             'Equipamiento', 'liberate',     'Banda de tela de resistencia media. No se enrolla ni se corta.',              4000, 9000, 15, false, 15, '{}', false, 6),
  ('Botella verde agua',         'Accesorios',   'liberate',     'Botella térmica de acero, 750 ml. Agua fría toda la clase.',                  5500, 11000, 0, false, 0, '{}', false, 7),
  ('Short Liberate',             'Ropa',         'liberate',     'Short con bolsillo para la llave y calza interna.',                           8000, 16500, 20, true, 0, '{"S":1,"M":3,"L":3,"XL":1}', false, 8),
  ('Mat de yoga',                'Momento Yogi', 'momento_yogi', 'Mat de 6 mm antideslizante de Momento Yogi.',                                 22000, 38000, 0, false, 7, '{}', false, 9),
  ('Pack 4 clases de yoga',      'Momento Yogi', 'momento_yogi', '4 clases de yoga con Pame en Power Gym. Las usás en el mes.',                9000, 28000, 0, false, 0, '{}', true, 10),
  ('Bloque de yoga',             'Momento Yogi', 'momento_yogi', 'Bloque de corcho natural, firme y liviano.',                                  5000, 9500, 0, false, 12, '{}', false, 11),
  ('Correa de yoga',             'Momento Yogi', 'momento_yogi', 'Correa de algodón con hebilla metálica, 2,5 m.',                              3500, 7000, 0, false, 2, '{}', false, 12)
on conflict do nothing;

with c as (
  insert into public.cursos (nombre, bajada, marca, precio, nivel, publicado, orden) values
    ('Liberate en casa',          'Funcional sin equipamiento',  'liberate',     12000, 'Todos los niveles', true, 1),
    ('HIIT 20 minutos',           'Rutinas cortas que queman',   'liberate',      9000, 'Intermedio',        true, 2),
    ('Kettlebell desde cero',     'Técnica, fuerza y swing',     'liberate',     15000, 'Principiante',      true, 3),
    ('Yoga para entrenar mejor',  'Movilidad para deportistas',  'momento_yogi', 11000, 'Todos los niveles', true, 4),
    ('Meditaciones con Pame',     'Respirar y bajar un cambio',  'momento_yogi',  7000, 'Para todos',        true, 5),
    ('Yoga para dormir',          'Flujos suaves de noche',      'momento_yogi',  8000, 'Suave',             true, 6)
  returning id, nombre
)
insert into public.curso_clases (curso_id, orden, titulo, minutos, gratis)
select c.id, x.orden, x.titulo, x.minutos, x.orden = 1
from c join (values
  ('Liberate en casa', 1, 'Activación y movilidad', 12), ('Liberate en casa', 2, 'Piernas y glúteos', 22),
  ('Liberate en casa', 3, 'Core y abdomen', 18), ('Liberate en casa', 4, 'Full body sin equipo', 25), ('Liberate en casa', 5, 'Estirar y soltar', 10),
  ('HIIT 20 minutos', 1, 'Tabata de bienvenida', 20), ('HIIT 20 minutos', 2, 'Escaleras de burpees', 20),
  ('HIIT 20 minutos', 3, 'EMOM piernas', 20), ('HIIT 20 minutos', 4, 'Finisher de core', 15),
  ('Kettlebell desde cero', 1, 'Agarre y postura', 10), ('Kettlebell desde cero', 2, 'El swing bien hecho', 18),
  ('Kettlebell desde cero', 3, 'Goblet squat', 15), ('Kettlebell desde cero', 4, 'Clean y press', 20),
  ('Kettlebell desde cero', 5, 'Circuito final', 25), ('Kettlebell desde cero', 6, 'Plan de 4 semanas', 8),
  ('Yoga para entrenar mejor', 1, 'Caderas libres', 20), ('Yoga para entrenar mejor', 2, 'Espalda y hombros', 18),
  ('Yoga para entrenar mejor', 3, 'Isquios y gemelos', 20), ('Yoga para entrenar mejor', 4, 'Flujo post entrenamiento', 25),
  ('Meditaciones con Pame', 1, 'Respiración 4-7-8', 8), ('Meditaciones con Pame', 2, 'Antes de entrenar', 6),
  ('Meditaciones con Pame', 3, 'Soltar el día', 12), ('Meditaciones con Pame', 4, 'Escaneo corporal', 15),
  ('Yoga para dormir', 1, 'Flujo lento', 20), ('Yoga para dormir', 2, 'Piernas arriba', 12), ('Yoga para dormir', 3, 'Yin de 15', 15)
) as x(curso, orden, titulo, minutos) on x.curso = c.nombre;
