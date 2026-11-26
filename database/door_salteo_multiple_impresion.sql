USE [TB-L];
GO

IF OBJECT_ID('dbo.Door_Impresion_Salteo', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.Door_Impresion_Salteo (
        ID int IDENTITY(1,1) PRIMARY KEY,
        Estacion varchar(20) NOT NULL,
        ID_OrdenProduccion int NOT NULL,
        Estado varchar(12) NOT NULL CONSTRAINT DF_Door_ImpresionEstado DEFAULT 'PENDIENTE',
        FechaCambio datetime2 NOT NULL CONSTRAINT DF_Door_ImpresionFecha DEFAULT SYSUTCDATETIME(),
        Impresora nvarchar(256) NULL,
        Error nvarchar(1000) NULL
    );
    CREATE INDEX IX_Door_Impresion_Salteo_Cola ON dbo.Door_Impresion_Salteo (Estacion, Estado, ID);
    CREATE INDEX IX_Door_Impresion_Salteo_Panel ON dbo.Door_Impresion_Salteo (Estacion, ID_OrdenProduccion, Estado);
END;
GO

IF OBJECT_ID('dbo.SP_DoorImpresionSalteo', 'P') IS NULL
    EXEC ('CREATE PROCEDURE dbo.SP_DoorImpresionSalteo AS RETURN 0;');
GO
ALTER PROCEDURE dbo.SP_DoorImpresionSalteo
    @Station varchar(20), @Action varchar(12), @Id int = NULL,
    @Printer nvarchar(256) = NULL, @Error nvarchar(1000) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @Action = 'ESTADO'
    BEGIN
        SELECT Estado, COUNT(*) AS Cantidad FROM dbo.Door_Impresion_Salteo
        WHERE Estacion = @Station AND Estado <> 'CANCELADA' GROUP BY Estado;
        RETURN;
    END;

    IF @Action = 'TOMAR'
    BEGIN
        ;WITH Siguiente AS (
            SELECT TOP (1) ID, ID_OrdenProduccion, Estado, FechaCambio, Impresora, Error
            FROM dbo.Door_Impresion_Salteo WITH (UPDLOCK)
            WHERE Estacion = @Station AND Estado = 'PENDIENTE'
            ORDER BY ID
        )
        UPDATE Siguiente SET Estado = 'ENVIANDO', FechaCambio = SYSUTCDATETIME(), Impresora = @Printer, Error = NULL
        OUTPUT inserted.ID AS Id, inserted.ID_OrdenProduccion AS OrderId;
        RETURN;
    END;

    IF @Action IN ('ENVIADA', 'ERROR')
    BEGIN
        UPDATE dbo.Door_Impresion_Salteo
        SET Estado = @Action, FechaCambio = SYSUTCDATETIME(), Error = @Error
        WHERE Estacion = @Station AND ID = @Id AND Estado = 'ENVIANDO';
        RETURN;
    END;

    IF @Action = 'REINTENTAR'
    BEGIN
        UPDATE dbo.Door_Impresion_Salteo
        SET Estado = 'PENDIENTE', FechaCambio = SYSUTCDATETIME(), Error = NULL
        WHERE Estacion = @Station AND Estado = 'ERROR';
        SELECT @@ROWCOUNT;
    END;
END;
GO

ALTER PROCEDURE dbo.SP_DoorPendientesSalteo
    @Station varchar(20), @After int, @Limit int, @SD nvarchar(100) = NULL
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
      AND (@SD IS NULL OR LTRIM(RTRIM(Q.SD)) = @SD)
    ORDER BY Q.ID_OrdenProduccion;

    SELECT DISTINCT LTRIM(RTRIM(Q.SD)) AS SD
    FROM dbo.Door_Cola_Estacion Q
    JOIN dbo.Door_Estacion_Secuencia E ON E.Estacion = Q.Estacion
    WHERE Q.Estacion = @Station AND Q.ID_OrdenProduccion > E.Puntero_ID_OrdenProduccion
      AND NULLIF(LTRIM(RTRIM(Q.SD)), '') IS NOT NULL
    ORDER BY SD;
END;
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
    SELECT Q.ID_OrdenProduccion, Q.Salteado FROM dbo.Door_Cola_Estacion Q
    WHERE Q.Estacion = @Station AND Q.ID_OrdenProduccion > @Puntero
      AND (@Mode = 2 OR Q.Salteado = @Mode)
      AND ((@OrderIds IS NOT NULL AND EXISTS (
          SELECT 1 FROM @Elegidos X JOIN dbo.Door_Cola_Estacion A
              ON A.ID_OrdenProduccion = X.ID AND A.Estacion = @Station
          WHERE A.ID_OrdenProduccion = Q.ID_OrdenProduccion OR (@EntireSequence = 1
            AND A.Secuencia = Q.Secuencia AND CONVERT(date, A.Fecha_Secuencia) = CONVERT(date, Q.Fecha_Secuencia))
        ))
        OR (@OrderIds IS NULL AND (Q.ID_OrdenProduccion = @OrderId OR (@EntireSequence = 1 AND Q.Secuencia = @Secuencia
           AND Q.Fecha_Secuencia >= @Fecha AND Q.Fecha_Secuencia < DATEADD(day, 1, @Fecha)))));

    IF EXISTS (
        SELECT 1 FROM dbo.Validacion_Ornamento V JOIN @Paneles Q ON Q.ID = V.ID_OrdenProduccion
        WHERE Q.Restaurar = 0 AND V.Puesto = @Station AND V.ResultadoGeneral = 'APROBADO'
          AND V.EstadoImpresion IN ('PENDIENTE', 'COMPLETO')
    )
        THROW 50101, 'La selección incluye un panel en proceso o con Kanban impreso.', 1;

    IF EXISTS (
        SELECT 1 FROM dbo.Door_Impresion_Salteo I WITH (UPDLOCK, HOLDLOCK) JOIN @Paneles Q ON Q.ID = I.ID_OrdenProduccion
        WHERE I.Estacion = @Station AND Q.Restaurar = 1 AND I.Estado = 'ENVIANDO'
    )
        THROW 50101, 'Hay una etiqueta de salteo en envío. Esperá a que termine antes de restaurar.', 1;

    UPDATE I SET Estado = 'CANCELADA', FechaCambio = SYSUTCDATETIME()
    FROM dbo.Door_Impresion_Salteo I JOIN @Paneles Q ON Q.ID = I.ID_OrdenProduccion
    WHERE I.Estacion = @Station AND Q.Restaurar = 1 AND I.Estado IN ('PENDIENTE','ERROR');

    INSERT dbo.Door_Impresion_Salteo (Estacion, ID_OrdenProduccion)
    SELECT @Station, ID FROM @Paneles WHERE Restaurar = 0;

    INSERT dbo.Door_Salteo_Puesto (Estacion, ID_OrdenProduccion, Motivo)
    SELECT @Station, ID, CASE WHEN @EntireSequence = 1 THEN 'SECUENCIA' ELSE 'PANEL' END
    FROM @Paneles WHERE Restaurar = 0;
    DECLARE @Affected int = @@ROWCOUNT;

    DELETE S FROM dbo.Door_Salteo_Puesto S JOIN @Paneles Q ON Q.ID = S.ID_OrdenProduccion
    WHERE S.Estacion = @Station AND Q.Restaurar = 1;
    SET @Affected += @@ROWCOUNT;

    -- Los puestos de línea comparten la orden de cliente y su número de orden.
    -- El detalle de salteo sigue siendo independiente por estación.
    DECLARE @Grupos table (ID_OrdenCliente int, Orden int, PRIMARY KEY (ID_OrdenCliente, Orden));
    INSERT @Grupos
    SELECT DISTINCT OP.ID_OrdenCliente, OP.Orden
    FROM dbo.Orden_Produccion OP JOIN @Paneles Q ON Q.ID = OP.ID_OrdenProduccion
    WHERE UPPER(LTRIM(RTRIM(OP.Puesto))) IN ('DL01','DL02','DL03','DL04');

    DECLARE @Relacionadas table (
        ID int PRIMARY KEY, ID_OrdenCliente int, Orden int, Puesto varchar(20)
    );
    INSERT @Relacionadas
    SELECT OP.ID_OrdenProduccion, OP.ID_OrdenCliente, OP.Orden, UPPER(LTRIM(RTRIM(OP.Puesto)))
    FROM dbo.Orden_Produccion OP
    JOIN @Grupos G ON G.ID_OrdenCliente = OP.ID_OrdenCliente AND G.Orden = OP.Orden
    WHERE UPPER(LTRIM(RTRIM(OP.Puesto))) IN ('DL01','DL02','DL03','DL04');

    IF EXISTS (
        SELECT 1 FROM @Relacionadas
        GROUP BY ID_OrdenCliente, Orden, Puesto
        HAVING COUNT(*) > 1
    )
        THROW 50101, 'Hay más de un panel con la misma orden de cliente y orden en un puesto de línea. No se pudo identificar qué fila actualizar.', 1;

    DECLARE @Estados table (ID_OrdenCliente int, Orden int, Estado int, PRIMARY KEY (ID_OrdenCliente, Orden));
    INSERT @Estados
    SELECT R.ID_OrdenCliente, R.Orden, MAX(CASE WHEN S.ID_OrdenProduccion IS NULL THEN 0 ELSE 1 END)
    FROM @Relacionadas R
    LEFT JOIN dbo.Door_Salteo_Puesto S ON S.ID_OrdenProduccion = R.ID
    GROUP BY R.ID_OrdenCliente, R.Orden;

    UPDATE OP SET Estado = E.Estado
    FROM dbo.Orden_Produccion OP
    JOIN @Relacionadas R ON R.ID = OP.ID_OrdenProduccion
    JOIN @Estados E ON E.ID_OrdenCliente = R.ID_OrdenCliente AND E.Orden = R.Orden
    WHERE OP.Estado IS NULL OR OP.Estado <> E.Estado;

    UPDATE OP SET Estado = CASE WHEN EXISTS (
        SELECT 1 FROM dbo.Door_Salteo_Puesto S WHERE S.ID_OrdenProduccion = OP.ID_OrdenProduccion
    ) THEN 1 ELSE 0 END
    FROM dbo.Orden_Produccion OP JOIN @Paneles Q ON Q.ID = OP.ID_OrdenProduccion
    WHERE NOT EXISTS (SELECT 1 FROM @Relacionadas R WHERE R.ID = OP.ID_OrdenProduccion);

    COMMIT;
    SELECT @Affected;
END;
GO
