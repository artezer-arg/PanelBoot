-- Aplicar en la misma instancia SQL a la que conecta Door en producción.
-- Reemplaza las dos correcciones anteriores del cierre de Produccion_Secuencia.
USE [TB-L];

IF OBJECT_ID('dbo.SP_DoorFinalizarPanelEstacion', 'P') IS NULL
    THROW 50000, 'Esta base no tiene el procedimiento de cierre de estaciones independientes.', 1;

IF OBJECT_ID('dbo.Door_Cola_Estacion', 'V') IS NULL
    THROW 50000, 'Falta la vista de cola de estaciones. Aplicar primero las migraciones de Salteo y asignacion.', 1;

EXEC sys.sp_executesql N'
ALTER PROCEDURE dbo.SP_DoorFinalizarPanelEstacion
    @Estacion VARCHAR(20),
    @PuestoOrigen VARCHAR(20),
    @ID_OrdenProduccion INT,
    @ID_Validacion INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @Puntero INT, @Siguiente INT, @FechaAvance DATETIME,
                @ID_OrdenCliente INT, @Orden INT, @PuestoProduccion VARCHAR(20);
        SELECT @Puntero = Puntero_ID_OrdenProduccion
        FROM dbo.Door_Estacion_Secuencia WITH (UPDLOCK, HOLDLOCK)
        WHERE Estacion = @Estacion AND PuestoOrigen = @PuestoOrigen;

        IF @Puntero IS NULL
            THROW 50001, ''La estacion no esta registrada para el puesto de origen.'', 1;

        SELECT @PuestoProduccion = P.Puesto
        FROM dbo.Puesto P
        WHERE P.Puesto = @PuestoOrigen;

        IF @PuestoProduccion IS NULL
            THROW 50003, ''El puesto de origen de la estacion no existe en dbo.Puesto.'', 1;

        IF NOT EXISTS (
            SELECT 1 FROM dbo.Validacion_Ornamento
            WHERE ID_Validacion = @ID_Validacion
              AND ID_OrdenProduccion = @ID_OrdenProduccion AND Puesto = @Estacion
              AND ResultadoGeneral = ''APROBADO'' AND EstadoImpresion = ''COMPLETO''
        )
            THROW 50002, ''La orden requiere una validacion impresa de esta estacion.'', 1;

        SELECT @FechaAvance = FechaAvancePuntero, @ID_OrdenCliente = ID_OrdenCliente, @Orden = Orden
        FROM dbo.Validacion_Ornamento WHERE ID_Validacion = @ID_Validacion;

        IF @FechaAvance IS NULL OR @ID_OrdenProduccion > @Puntero
        BEGIN
            SELECT TOP (1) @Siguiente = Q.ID_OrdenProduccion
            FROM dbo.Door_Cola_Estacion Q
            WHERE Q.Estacion = @Estacion AND Q.PuestoOrigen = @PuestoOrigen
              AND Q.ID_OrdenProduccion > @Puntero AND Q.Salteado = 0
            ORDER BY Q.ID_OrdenProduccion, Q.Orden;

            IF @Siguiente IS NULL OR @Siguiente <> @ID_OrdenProduccion
                THROW 50002, ''La orden ya no es la siguiente de esta estacion.'', 1;

            SET @FechaAvance = GETDATE();

            UPDATE dbo.Door_Estacion_Secuencia
            SET Puntero_ID_OrdenProduccion = @ID_OrdenProduccion
            WHERE Estacion = @Estacion;

            UPDATE dbo.Validacion_Ornamento
            SET FechaAvancePuntero = @FechaAvance
            WHERE ID_Validacion = @ID_Validacion;
        END;

        -- Produccion_Secuencia references the physical station in dbo.Puesto.
        -- The independent station remains recorded in Validacion_Ornamento.
        IF NOT EXISTS (
            SELECT 1 FROM dbo.Produccion_Secuencia WITH (UPDLOCK, HOLDLOCK)
            WHERE ID_OrdenProduccion = @ID_OrdenProduccion AND Puesto = @PuestoProduccion
        )
        BEGIN
            INSERT INTO dbo.Produccion_Secuencia (ID_OrdenProduccion, ID_OrdenCliente, Puesto, Fecha, Orden)
            VALUES (@ID_OrdenProduccion, @ID_OrdenCliente, @PuestoProduccion, @FechaAvance, @Orden);
        END;

        COMMIT;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK;
        THROW;
    END CATCH;
END;';

SELECT DB_NAME() AS BaseActual,
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('dbo.SP_DoorFinalizarPanelEstacion')) LIKE '%SELECT @PuestoProduccion = P.Puesto%'
           THEN 'CORRECCION INSTALADA' ELSE 'REVISAR VERSION DEL PROCEDIMIENTO' END AS Resultado;
SELECT E.Estacion, E.PuestoOrigen, P.Puesto AS PuestoParaProduccion
FROM dbo.Door_Estacion_Secuencia E
LEFT JOIN dbo.Puesto P ON P.Puesto = E.PuestoOrigen
WHERE E.Estacion IN ('DL01-A','DL01-B')
ORDER BY E.Estacion;
