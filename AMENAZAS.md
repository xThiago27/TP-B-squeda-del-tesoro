# Análisis de amenazas

| Ataque | ¿Era posible? | Qué se hizo |
|---|---|---|
| **Compartir una pista o la URL con otro equipo** | Parcialmente. La pista es texto y la URL es pública. | Compartirlas no libera nada: cada equipo tiene un token (UUID) y el servidor solo libera la pregunta si **ese** equipo valida su llegada al punto con GPS. Riesgo residual: compartir el código de recuperación permitiría usar la sesión de otro equipo. |
| **Adivinar tokens o saltear el orden de los puntos** | No. | No hay QR: el mecanismo es la brújula. El orden lo lleva el servidor (`punto_actual`); el cliente nunca elige el punto. Los tokens son UUID aleatorios. Las respuestas y códigos de respaldo no viajan al navegador (tabla `puntos` bloqueada por RLS) y solo se entregan las coordenadas del punto actual. Los códigos de respaldo se limitan a 5 intentos fallidos cada 5 minutos. |
| **Suplantar la ubicación con GPS falso** | Sí. Ningún servidor puede comprobar la posición real del celular. | Riesgo aceptado y mitigado con auditoría: cada intento queda en `registros_llegada` con coordenadas, precisión y distancia, visible en el panel; se penaliza el código de respaldo y los organizadores supervisan en la plaza. El modo ensayo solo se activa con `?ensayo=1`. Mejora futura: detectar saltos de posición imposibles. |
| **Validaciones repetidas o simultáneas** | No. | Cada operación bloquea la fila del equipo (`FOR UPDATE`) y es atómica. Una llegada ya validada no se duplica, y `responder` solo avanza una vez porque después de acertar la llegada vuelve a quedar sin validar. Puntaje, bonus y tiempo se calculan con la hora del servidor. |
| **Acceder al panel del organizador sin credenciales** | No. | `admin.html` requiere login de Supabase Auth; los registros públicos están desactivados; las tablas con datos personales solo se leen con usuario autenticado (RLS) y `reiniciar_partida` está revocada para usuarios anónimos. |

**Evidencia a adjuntar (completar tras probar):** captura de un intento sin login al panel (debe fallar), captura del panel con intentos registrados y captura de `reiniciar_partida` rechazada sin sesión.
