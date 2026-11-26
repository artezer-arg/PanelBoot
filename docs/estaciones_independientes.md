# Dos estaciones Door con la misma cola de órdenes

Ejecutá `database/door_estaciones_independientes.sql` una vez en la base de prueba `TB-L` y, tras la prueba, en la base compartida. Usá una cuenta con permisos para crear la tabla y los procedimientos. Comprobá que el usuario de Door puede ejecutar `dbo.SP_DoorSiguientePanelEstacion` y `dbo.SP_DoorFinalizarPanelEstacion`; si tiene permisos restringidos, otorgale `EXECUTE` sobre esos dos procedimientos.

El script registra `DL01-A` y `DL01-B` con el puntero que tenga DL01 durante la instalación. Si querés que alguna estación empiece en otra orden, definí su último ID procesado antes del primer uso. Volver a ejecutar el script conserva los punteros existentes.

Prepará una carpeta nueva para la versión actualizada en cada PC. Usá la misma conexión a `TB-L` en ambas y editá la sección `StationSequence` del `appsettings.json` local antes de iniciar:

| PC | Id | SourcePuesto |
| --- | --- | --- |
| A | DL01-A | DL01 |
| B | DL01-B | DL01 |

Ejecutá `start_hmi_workstation.bat` en cada PC. En el navegador, verificá que la URL de API apunte al Door de esa misma PC (`http://localhost:5121`). El identificador de estación se toma de la configuración local del backend. Los dos campos vacíos activan el comportamiento anterior.

## Prueba de aceptación

1. Abrí ambos HMI y verificá que muestren la misma orden pendiente con identificadores de estación distintos.
2. Validá la orden en A. Confirmá que A pasa a la siguiente y que B permanece en la primera.
3. Reiniciá B y comprobá que sigue en la primera. Validala con otro QR y verificá que B avance.
4. Confirmá en `dbo.Door_Estacion_Secuencia` el puntero de cada estación y en `dbo.Validacion_Ornamento` los cierres de ambas. Verificá que un QR aprobado siga rechazándose si se reutiliza.

En este modo el cierre se registra con la estación en `Validacion_Ornamento` y actualiza `Door_Estacion_Secuencia`. Los consumidores actuales de `Produccion_Secuencia` y del puntero de `Puesto` siguen viendo el flujo original. Las equivalencias, la configuración general de SQL y el control de QR duplicados siguen siendo compartidos.
