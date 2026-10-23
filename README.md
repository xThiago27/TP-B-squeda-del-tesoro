# El código perdido de la Plaza del Congreso

Búsqueda del tesoro geolocalizada, jugable desde el navegador del celular (Android/Chrome e iOS/Safari), sin instalación.

## Integrantes
- Enzo Fuentes
- Juan Ignacio Urondo Romero
- Thiago Ruiz Diaz

**Facultad:** Ingeniería en Informática (Sede Centro) · **Materia:** Paradigma de la programación

## El juego
Cada equipo (3 a 5 personas) es un grupo de *debuggers* que recorre 12 puntos de la Plaza del Congreso. Una flecha guía hacia el próximo punto, pero es **tramposa**: cambia de color y los jugadores deben descubrir la regla. Al llegar (a menos de 15 m, verificado en el servidor) se desbloquea una pregunta sobre paradigmas de programación. Al reunir los 12 fragmentos el sistema "compila".
Mecánicas: narrativa, desafíos por punto y puntaje con bonus por velocidad (penalización por usar el código de respaldo).

## Arquitectura
- **Cliente:** HTML/JS estático en Vercel (carpeta `web/`). Usa `navigator.geolocation` y la brújula del celular.
- **Servidor:** Supabase (PostgreSQL). La validación de llegada (haversine), las respuestas, el puntaje, el cronómetro y el ranking se calculan en **funciones SQL** (`supabase.sql`) invocadas por `rpc`. Se eligieron en lugar de Edge Functions porque no requieren instalar nada y cada operación es una transacción atómica.
- **Seguridad:** las respuestas y los códigos de respaldo están en la tabla `puntos`, sin acceso público (RLS). Los datos personales (`participantes`) solo los lee el organizador autenticado.
- **Ley 25.326:** el formulario informa el uso de los datos y pide consentimiento; menores requieren autorización de tutor; no se muestran en el ranking; `reiniciar_partida` los borra.

## Archivos
| Archivo | Función |
|---|---|
| `config.json` | **Todo lo que depende de la plaza**: puntos, radios, pistas, preguntas, códigos de respaldo, regla de la brújula, puntaje |
| `generar_seed.py` | Convierte `config.json` en `seed.sql` y `web/config.publico.json` |
| `supabase.sql` | Tablas, seguridad y funciones del servidor |
| `seed.sql` | Datos de los puntos (generado) |
| `web/index.html` | Juego para los jugadores |
| `web/admin.html` | Panel del organizador |

## Cómo poner el juego en marcha
1. Crear un proyecto en Supabase y ejecutar `supabase.sql` y luego `seed.sql` en el SQL Editor.
2. Crear el usuario organizador en Authentication y desactivar los registros públicos.
3. Poner la URL del proyecto y la clave *anon* en `web/index.html` y `web/admin.html`.
4. Publicar el repo en Vercel con Output Directory = `web`.
5. Jugar en `https://<tu-url>/`. Para probar desde casa: `https://<tu-url>/?ensayo=1`. Panel: `/admin.html`.

## Cambiar de plaza (solo editando el JSON)
1. Marcar los puntos en Google My Maps y copiar las coordenadas a `config.json`.
2. Ajustar pistas, preguntas, radios y códigos de respaldo.
3. Ejecutar `python3 generar_seed.py`.
4. Pegar el nuevo `seed.sql` en el SQL Editor de Supabase y subir el nuevo `web/config.publico.json`.
No se modifica código. El mecanismo es la brújula tramposa, por lo que no se generan QR.

## Uso de IA
Ver `USO_DE_IA.md`. Análisis de amenazas: `AMENAZAS.md`.

## Estructura de `config.json` (relato y desafíos)
Cada punto tiene `relato` (fragmento de la historia que se revela al acertar), `desafios` (lista de desafíos del punto; si se cargan varios, a cada equipo le toca uno según su token, lo que permite rejugar la misma plaza) y opcionalmente `pista_extra` (si falta, se calcula sola desde las coordenadas). Tipos de desafío: `opcion_multiple`, `verdadero_falso` y `texto_libre` (la respuesta admite alternativas separadas por `|`). El texto de cierre está en `final`.
