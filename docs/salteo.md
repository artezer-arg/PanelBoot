# Salteo por puesto

La pantalla está en **Operativo → menú Supervisor → Salteo de secuencias y paneles**. Elegí un puesto independiente, por ejemplo DL01-A. Door muestra la última secuencia validada y los paneles posteriores al puntero, con fecha, SD, referencia, posición y mano.

- **Panel** saltea la orden de producción de esa fila.
- **Secuencia** saltea los paneles pendientes de esa secuencia y esa fecha en el puesto seleccionado. La fecha evita afectar otra jornada con el mismo número.
- **Invertir secuencia** intercambia los estados pendiente y salteado dentro de la secuencia elegida. **Restaurar** devuelve a la cola un panel salteado que todavía esté por delante del puntero. También se pueden saltear o restaurar varios paneles marcados juntos.
- Si la selección incluye un panel con impresión en curso o Kanban ya impreso, la operación se rechaza y conserva toda la selección.

Un salteo actualiza `Orden_Produccion.Estado` a `1`, aun si se realiza en un solo puesto. Si se restaura el último salteo de una orden, su estado vuelve a `0`. El valor `0` también es el valor por defecto para órdenes nuevas. La cola usa el registro de `Door_Salteo_Puesto` para que un salteo en DL01-A no quite la orden de DL01-B.

## Instalar

1. Probá primero en una copia de TB-L. La base debe tener aplicada la migración de estaciones independientes. Ejecutá `door_salteo.sql` para actualizar los procedimientos y el valor por defecto.
2. Si la cuenta de Door tiene permisos limitados, habilitá la ejecución de `SP_DoorPuestosSalteo`, `SP_DoorPendientesSalteo`, `SP_DoorRegistrarSalteo` y `SP_DoorBloquearOrdenActual`. Se mantienen los permisos ya configurados para los procedimientos de secuencia.
3. Actualizá los ejecutables de ambas estaciones y conservá `connection.json`, `plc-recipe.json` y los valores locales de `StationSequence`. Verificá `Estado = 1` y la presencia de la orden en B tras saltearla en A.

La migración conserva los valores históricos de `Estado`. Revisá las filas con valor `1` sin registro en `Door_Salteo_Puesto` antes de normalizarlas a `0`. El script anterior de Door usaba `1` como valor por defecto; también puede haber otros sistemas que asignen la columna explícitamente.

## Asignar tipos de panel a cada puesto

Después de la migración de Salteo, ejecutá `door_asignacion_paneles.sql`. Si la cuenta de Door tiene permisos limitados, habilitá la ejecución de `SP_DoorPanelesPuesto`. En **Salteo → Paneles del puesto**, activá **Limitar a los tipos marcados** y guardá la selección para cada estación:

| Puesto | Tipos de panel |
| --- | --- |
| DL01-A | FR LH y RR RH |
| DL01-B | FR RH y RR LH |

Si la restricción queda apagada, el puesto recibe todos los tipos de panel de su origen. La asignación se guarda en TB-L y se aplica tanto en Operativo como en Salteo. Al configurar un puesto que ya está en uso, el puntero actual se conserva. El sistema rechaza una configuración que deje fuera un panel de ese puesto con impresión en curso o Kanban ya impreso y cierre pendiente.

## Selección múltiple, filtro por SD e impresión alternativa

Aplicá `door_salteo_multiple_impresion.sql` **después** de las migraciones anteriores de Salteo y de asignación de paneles. Esta versión incluye la propagación de `Estado` a DL01, DL02, DL03 y DL04. Si la cuenta de Door usa permisos específicos, otorgale `EXECUTE` sobre `dbo.SP_DoorImpresionSalteo`.

En Salteo podés filtrar por SD aunque las órdenes correspondientes todavía no estén en la primera página. Marcá la casilla de cada secuencia completa y confirmá desde la barra inferior. La selección de una secuencia completa incluye sus paneles asignados a ese puesto aunque el filtro de la pantalla no los muestre.

En cada PC, seleccioná su propio puesto y abrí **Impresión de Salteo**. Elegí una cola de Windows que corresponda a una impresora física distinta de la normal. Cuando se confirma el salteo, la orden deja de pedirse en ese puesto y se encola un Kanban por panel recién salteado. Door envía la etiqueta automáticamente desde la PC que ejecuta ese puesto independiente. Con la impresora sin configurar o sin una cola válida, los trabajos permanecen pendientes. La cola normal nunca se usa de respaldo.

El estado **Enviada** significa que Windows aceptó el trabajo. Si falla el envío, podés usar **Reintentar fallidas**. Si Door se interrumpió durante un envío, verificá la cola de Windows antes de intervenir un trabajo que siga mostrando **En envío**. Door no lo reenvía automáticamente para evitar duplicados. Restaurar cancela las impresiones de esa orden que sigan pendientes o con error. La migración no imprime salteos históricos.

## Registro de cierre de producción

En una base actualizada, `SP_DoorFinalizarPanelEstacion` registra el cierre en `Produccion_Secuencia` usando el puesto de origen que existe en `dbo.Puesto` (por ejemplo, DL01). El identificador independiente se conserva en `Validacion_Ornamento` y en el puntero propio. Si falla el registro de producción, se revierte el avance en la misma transacción.

Si la base ya tenía aplicada una versión anterior de la asignación de paneles, usá `door_corregir_fk_secuencia_puesto.sql` para actualizar el cierre. Al aplicarlo, verificá que diga `CORRECCION INSTALADA` y que `PuestoParaProduccion` coincida con el origen de cada estación. El script actualiza el procedimiento y deja intacto el historial.
