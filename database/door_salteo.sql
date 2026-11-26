USE [TB-L];
GO

-- Ejecutar después de door_estaciones_independientes.sql.
-- Los valores 1 anteriores a esta instalación deben auditarse por separado.
SET XACT_ABORT ON;
BEGIN TRANSACTION;
IF OBJECT_ID('dbo.Door_Salteo_Puesto', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.Door_Salteo_Puesto (
        Estacion varchar(20) NOT NULL,
        ID_OrdenProduccion int NOT NULL,
        Fecha datetime2(0) NOT NULL CONSTRAINT DF_Door_Salteo_Fecha DEFAULT SYSDATETIME(),
        Motivo varchar(12) NOT NULL,
        CONSTRAINT PK_Door_Salteo_Puesto PRIMARY KEY (Estacion, ID_OrdenProduccion)
    );
END;

-- Las órdenes nuevas nacen normales. No se reescriben estados históricos.
DECLARE @DefaultName sysname, @DefaultDefinition nvarchar(max);
SELECT @DefaultName = D.name, @DefaultDefinition = D.definition
FROM sys.default_constraints D
JOIN sys.columns C ON C.object_id = D.parent_object_id AND C.column_id = D.parent_column_id
WHERE D.parent_object_id = OBJECT_ID('dbo.Orden_Produccion') AND C.name = 'Estado';
IF @DefaultName IS NULL OR REPLACE(REPLACE(REPLACE(@DefaultDefinition, '(', ''), ')', ''), ' ', '') <> '0'
BEGIN
    IF @DefaultName IS NOT NULL
    BEGIN
        DECLARE @DropDefault nvarchar(max) = 'ALTER TABLE dbo.Orden_Produccion DROP CONSTRAINT ' + QUOTENAME(@DefaultName);
        EXEC sys.sp_executesql @DropDefault;
    END;
    ALTER TABLE dbo.Orden_Produccion ADD CONSTRAINT DF_Door_OrdenProduccion_Estado DEFAULT (0) FOR Estado;
END;
COMMIT;
GO

IF OBJECT_ID('dbo.Door_Cola_Estacion', 'V') IS NULL
    EXEC ('CREATE VIEW dbo.Door_Cola_Estacion AS SELECT 0 AS Placeholder;');
GO
ALTER VIEW dbo.Door_Cola_Estacion
AS
SELECT E.Estacion, E.PuestoOrigen, OP.ID_OrdenProduccion, OP.ID_OrdenCliente,
       OP.Secuencia, OP.Fecha_Secuencia, OP.SD, OP.Referencia, OP.Posicion, OP.Mano, OP.Orden,
       CAST(CASE WHEN S.ID_OrdenProduccion IS NOT NULL THEN 1 ELSE 0 END AS bit) AS Salteado
FROM dbo.Door_Estacion_Secuencia E
JOIN dbo.Puesto P ON P.Puesto = E.PuestoOrigen
JOIN dbo.Orden_Produccion OP ON OP.Puesto = P.Puesto AND OP.Lector = P.Lector
LEFT JOIN dbo.Door_Salteo_Puesto S ON S.Estacion = E.Estacion AND S.ID_OrdenProduccion = OP.ID_OrdenProduccion;
GO

IF OBJECT_ID('dbo.SP_DoorBloquearOrdenActual', 'P') IS NULL
    EXEC ('CREATE PROCEDURE dbo.SP_DoorBloquearOrdenActual AS RETURN 0;');
GO
ALTER PROCEDURE dbo.SP_DoorBloquearOrdenActual
    @Station varchar(20)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Pointer int;
    SELECT @Pointer = Puntero_ID_OrdenProduccion
    FROM dbo.Door_Estacion_Secuencia WITH (UPDLOCK, HOLDLOCK)
    WHERE Estacion = @Station;

    SELECT TOP (1) ID_OrdenProduccion
    FROM dbo.Door_Cola_Estacion
    WHERE Estacion = @Station AND ID_OrdenProduccion > @Pointer AND Salteado = 0
    ORDER BY ID_OrdenProduccion;
END;
GO

IF OBJECT_ID('dbo.SP_DoorPuestosSalteo', 'P') IS NULL
    EXEC ('CREATE PROCEDURE dbo.SP_DoorPuestosSalteo AS RETURN 0;');
GO
ALTER PROCEDURE dbo.SP_DoorPuestosSalteo
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Estacion AS Station, PuestoOrigen AS Source,
        CAST(NULL AS int) AS LastValidatedOrderId, CAST(NULL AS int) AS LastValidatedSequence
    FROM dbo.Door_Estacion_Secuencia ORDER BY Estacion;
END;
GO

IF OBJECT_ID('dbo.SP_DoorPendientesSalteo', 'P') IS NULL
    EXEC ('CREATE PROCEDURE dbo.SP_DoorPendientesSalteo AS RETURN 0;');
GO
ALTER PROCEDURE dbo.SP_DoorPendientesSalteo
    @Station varchar(20), @After int, @Limit int
AS
BEGIN
    SET NOCOUNT ON;
    SELECT E.Estacion AS Station, E.PuestoOrigen AS Source,
           V.ID_OrdenProduccion AS LastValidatedOrderId, V.Secuencia AS LastValidatedSequence
    FROM dbo.Door_Estacion_Secuencia E
    OUTER APPLY (
        SELECT TOP (1) ID_OrdenProduccion, Secuencia
        FROM dbo.Validacion_Ornamento
        WHERE Puesto = E.Estacion AND ResultadoGeneral = 'APROBADO' AND FechaAvancePuntero IS NOT NULL
        ORDER BY FechaAvancePuntero DESC, ID_Validacion DESC
    ) V
    WHERE E.Estacion = @Station;

    SELECT TOP (@Limit) Q.ID_OrdenProduccion AS OrderId, Q.Secuencia AS Sequence, Q.SD,
           Q.Referencia AS Reference, Q.Posicion AS Position, Q.Mano AS Hand,
           CONVERT(varchar(10), Q.Fecha_Secuencia, 23) AS ProductionDate,
           Q.Salteado AS Skipped, CAST(CASE WHEN EXISTS (
               SELECT 1 FROM dbo.Validacion_Ornamento V
               WHERE V.Puesto = Q.Estacion AND V.ID_OrdenProduccion = Q.ID_OrdenProduccion
                 AND V.ResultadoGeneral = 'APROBADO' AND V.EstadoImpresion IN ('PENDIENTE', 'COMPLETO')
           ) THEN 1 ELSE 0 END AS bit) AS Started
    FROM dbo.Door_Cola_Estacion Q
    JOIN dbo.Door_Estacion_Secuencia E ON E.Estacion = Q.Estacion
    WHERE Q.Estacion = @Station AND Q.ID_OrdenProduccion > E.Puntero_ID_OrdenProduccion
      AND Q.ID_OrdenProduccion > @After
    ORDER BY Q.ID_OrdenProduccion;
END;
GO

IF OBJECT_ID('dbo.SP_DoorRegistrarSalteo', 'P') IS NULL
    EXEC ('CREATE PROCEDURE dbo.SP_DoorRegistrarSalteo AS RETURN 0;');
GO
ALTER PROCEDURE dbo.SP_DoorRegistrarSalteo
    @Station varchar(20), @OrderId int, @EntireSequence bit, @Mode tinyint = 0, @OrderIds xml = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    BEGIN TRANSACTION;

    DECLARE @Lock int;
    EXEC @Lock = sys.sp_getapplock @Resource = 'Door_Salteo_Registro',
        @LockMode = 'Exclusive', @LockOwner = 'Transaction', @LockTimeout = 5000;
    IF @Lock < 0 THROW 50101, 'Otro salteo está en proceso. Reintentá.', 1;

    -- Esta fila también serializa el inicio de validación y el cierre de la estación.
    DECLARE @Puntero int, @Secuencia int, @Fecha date;
    SELECT @Puntero = Puntero_ID_OrdenProduccion
    FROM dbo.Door_Estacion_Secuencia WITH (UPDLOCK, HOLDLOCK)
    WHERE Estacion = @Station;

    SELECT @Secuencia = Secuencia, @Fecha = CONVERT(date, Fecha_Secuencia)
    FROM dbo.Door_Cola_Estacion
    WHERE Estacion = @Station AND ID_OrdenProduccion = @OrderId AND ID_OrdenProduccion > @Puntero;
    IF @Puntero IS NULL OR (@OrderIds IS NULL AND @Secuencia IS NULL)
        THROW 50100, 'La orden seleccionada ya no está pendiente de este puesto.', 1;

    DECLARE @Elegidos table (ID int PRIMARY KEY);
    IF @OrderIds IS NOT NULL
    BEGIN
        INSERT @Elegidos SELECT DISTINCT N.Item.value('(text())[1]', 'int') FROM @OrderIds.nodes('/ids/id') N(Item);
        IF EXISTS (SELECT 1 FROM @Elegidos X WHERE NOT EXISTS (
            SELECT 1 FROM dbo.Door_Cola_Estacion Q
            WHERE Q.Estacion = @Station AND Q.ID_OrdenProduccion = X.ID
              AND Q.ID_OrdenProduccion > @Puntero))
            THROW 50100, 'Al menos un panel marcado ya no está en la cola del puesto.', 1;
    END;

    DECLARE @Paneles table (ID int PRIMARY KEY, Restaurar bit NOT NULL);
    INSERT INTO @Paneles
    SELECT ID_OrdenProduccion, Salteado FROM dbo.Door_Cola_Estacion
    WHERE Estacion = @Station AND ID_OrdenProduccion > @Puntero
      AND (@Mode = 2 OR Salteado = @Mode)
      AND ((@OrderIds IS NOT NULL AND ID_OrdenProduccion IN (SELECT ID FROM @Elegidos))
        OR (@OrderIds IS NULL AND (ID_OrdenProduccion = @OrderId OR (@EntireSequence = 1 AND Secuencia = @Secuencia
           AND Fecha_Secuencia >= @Fecha AND Fecha_Secuencia < DATEADD(day, 1, @Fecha)))));

    IF EXISTS (
        SELECT 1 FROM dbo.Validacion_Ornamento V JOIN @Paneles Q ON Q.ID = V.ID_OrdenProduccion
        WHERE Q.Restaurar = 0 AND V.Puesto = @Station AND V.ResultadoGeneral = 'APROBADO'
          AND V.EstadoImpresion IN ('PENDIENTE', 'COMPLETO')
    )
        THROW 50101, 'La selección incluye un panel en proceso o con Kanban impreso.', 1;

    INSERT dbo.Door_Salteo_Puesto (Estacion, ID_OrdenProduccion, Motivo)
    SELECT @Station, ID, CASE WHEN @EntireSequence = 1 THEN 'SECUENCIA' ELSE 'PANEL' END
    FROM @Paneles WHERE Restaurar = 0;
    DECLARE @Affected int = @@ROWCOUNT;

    DELETE S FROM dbo.Door_Salteo_Puesto S JOIN @Paneles Q ON Q.ID = S.ID_OrdenProduccion
    WHERE S.Estacion = @Station AND Q.Restaurar = 1;
    SET @Affected += @@ROWCOUNT;

    UPDATE OP SET Estado = CASE WHEN EXISTS (
        SELECT 1 FROM dbo.Door_Salteo_Puesto S WHERE S.ID_OrdenProduccion = OP.ID_OrdenProduccion
    ) THEN 1 ELSE 0 END
    FROM dbo.Orden_Produccion OP JOIN @Paneles Q ON Q.ID = OP.ID_OrdenProduccion;

    COMMIT;
    SELECT @Affected;
END;
GO

ALTER PROCEDURE dbo.SP_DoorSiguientePanelEstacion
    @Estacion VARCHAR(20),
    @PuestoOrigen VARCHAR(20)
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM dbo.Door_Estacion_Secuencia
                   WHERE Estacion = @Estacion AND PuestoOrigen = @PuestoOrigen)
        THROW 50001, 'La estacion no esta registrada para el puesto de origen.', 1;

    SELECT TOP (1)
           OP.Referencia, OP.ID_OrdenProduccion, OP.ID_OrdenCliente,
           OP.Orden, OP.Secuencia, OP.SD,
           CONCAT(OP.Posicion, OP.Mano) AS Expr1,
           E.Estacion AS Puesto, OP.Fecha_Secuencia AS FechaSecuencia,
           OP.Mano, OP.Posicion
    FROM dbo.Door_Estacion_Secuencia E
    JOIN dbo.Puesto P ON P.Puesto = E.PuestoOrigen
    JOIN dbo.Orden_Produccion OP ON OP.Puesto = P.Puesto AND OP.Lector = P.Lector
    WHERE E.Estacion = @Estacion AND E.PuestoOrigen = @PuestoOrigen
      AND OP.ID_OrdenProduccion > E.Puntero_ID_OrdenProduccion
      AND NOT EXISTS (SELECT 1 FROM dbo.Door_Salteo_Puesto S
          WHERE S.Estacion = E.Estacion AND S.ID_OrdenProduccion = OP.ID_OrdenProduccion)
    ORDER BY OP.ID_OrdenProduccion, OP.Orden;
END;
GO

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

        DECLARE @Puntero INT, @Siguiente INT, @FechaAvance DATETIME;
        SELECT @Puntero = Puntero_ID_OrdenProduccion
        FROM dbo.Door_Estacion_Secuencia WITH (UPDLOCK, HOLDLOCK)
        WHERE Estacion = @Estacion AND PuestoOrigen = @PuestoOrigen;

        IF @Puntero IS NULL
            THROW 50001, 'La estacion no esta registrada para el puesto de origen.', 1;

        IF NOT EXISTS (
            SELECT 1 FROM dbo.Validacion_Ornamento
            WHERE ID_Validacion = @ID_Validacion
              AND ID_OrdenProduccion = @ID_OrdenProduccion AND Puesto = @Estacion
              AND ResultadoGeneral = 'APROBADO' AND EstadoImpresion = 'COMPLETO'
        )
            THROW 50002, 'La orden requiere una validacion impresa de esta estacion.', 1;

        SELECT @FechaAvance = FechaAvancePuntero
        FROM dbo.Validacion_Ornamento WHERE ID_Validacion = @ID_Validacion;

        IF @FechaAvance IS NOT NULL AND @ID_OrdenProduccion <= @Puntero
        BEGIN
            COMMIT;
            RETURN;
        END;

        SELECT TOP (1) @Siguiente = OP.ID_OrdenProduccion
        FROM dbo.Puesto P
        JOIN dbo.Orden_Produccion OP ON OP.Puesto = P.Puesto AND OP.Lector = P.Lector
        WHERE P.Puesto = @PuestoOrigen AND OP.ID_OrdenProduccion > @Puntero
          AND NOT EXISTS (SELECT 1 FROM dbo.Door_Salteo_Puesto S
              WHERE S.Estacion = @Estacion AND S.ID_OrdenProduccion = OP.ID_OrdenProduccion)
        ORDER BY OP.ID_OrdenProduccion, OP.Orden;

        IF @Siguiente IS NULL OR @Siguiente <> @ID_OrdenProduccion
            THROW 50002, 'La orden ya no es la siguiente de esta estacion.', 1;

        UPDATE dbo.Door_Estacion_Secuencia
        SET Puntero_ID_OrdenProduccion = @ID_OrdenProduccion
        WHERE Estacion = @Estacion;

        UPDATE dbo.Validacion_Ornamento
        SET FechaAvancePuntero = GETDATE()
        WHERE ID_Validacion = @ID_Validacion;

        COMMIT;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK;
        THROW;
    END CATCH;
END;
GO
