# Recetas de cámara por PLC Siemens S7-1500

La integración arranca deshabilitada. Desde el panel de administración, abrí la sección **PLC Siemens S7-1500**, configurá los parámetros y las reglas y guardá los cambios. Door guarda la configuración en `plc-recipe.json` junto a `backend.exe`, por separado en cada PC. Esta actualización no requiere una migración SQL adicional.

Configuración predeterminada del PLC: S7 nativo mediante S7netplus, IP `192.168.10.1`, puerto `102`, rack `0`, slot `1`, intervalo `100 ms`, tiempo máximo por operación `2000 ms`. Configurá en TIA Portal el permiso PUT/GET para la CPU y el DB48 con acceso no optimizado. Verificá que el proyecto del PLC use estos tipos y offsets:

| Dirección | Dato | Sentido |
| --- | --- | --- |
| DB48.DBW2 | Receta, INT con signo | Door → PLC |
| DB48.DBX4.0 | Confirmación opcional, BOOL | Door → PLC |
| DB48.DBW6 | Estado, INT: REQ 20, ACK 10, IDLE 24 | PLC → Door |
| DB48.DBW0 | Modelo de referencia, INT | PLC → Door |

Probá el extractor con `20-14-12`, una regla exacta `D3L FR RH` en posición 2 y una regla exacta `D1 FR RH` en posición 3. El probador de QR no contacta al PLC. La prueba TCP verifica conectividad, y la lectura de estado verifica el acceso al DB vía S7. Los botones de envío directo y handshake escriben en el PLC con la configuración guardada. Usalos primero en banco. Si dos PCs tienen habilitada esta función, cada una debe apuntar al PLC o bloque de datos asignado a su estación para evitar que compartan el mismo registro de receta.

## Flujo de operación

1. Para un panel con ornamento, Door valida su QR y, si está aprobado, imprime el Kanban. Para un panel sin ornamento, la opción **Imprimir automáticamente el Kanban cuando el panel no lleva ornamento** determina si imprime de inmediato o espera el botón **Imprimir Kanban** en Operativo.
2. Después de imprimir, Door pide el QR de la cuna. Busca la regla para el SD o modelo de la orden. En **Valor asignado**, la regla indica el QR de cuna exacto y el número que debe enviarse para ese modelo. En **Posición del QR**, la regla elige uno de los números incluidos en el QR.
3. En modo directo escribe y exige que la lectura coincida. En modo handshake espera REQ, deja el entero escrito y espera ACK. Una regla con segundo valor repite el ciclo si el segundo handshake está habilitado. El valor leído que se muestra corresponde a la última escritura.
4. Con la confirmación booleana activada, Door escribe y verifica únicamente el bit elegido. Después cierra la orden y avanza el puntero de la estación.

Ante un error, la orden queda pendiente. Escaneá de nuevo el QR de la cuna o usá **Reintentar cuna**. Al volver a Operativo, Door recupera la espera de cuna si el Kanban figura impreso. Con el PLC deshabilitado, las órdenes nuevas siguen el cierre habitual. Para una etiqueta que quedó impresa con el PLC habilitado, podés reintentar el avance después de deshabilitarlo.
