USE [TB-L];
GO

-- Aplicar después de la migración de Salteo. Un puesto sin asignación recibe todos los paneles.
IF OBJECT_ID('dbo.Door_Paneles_Puesto', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.Door_Paneles_Puesto (
        Estacion varchar(20) NOT NULL PRIMARY KEY REFERENCES dbo.Door_Estacion_Secuencia (Estacion),
        Mascara tinyint NOT NULL CHECK (Mascara BETWEEN 1 AND 15)
    );
END;
GO

ALTER VIEW dbo.Door_Cola_Estacion
AS
SELECT E.Estacion, E.PuestoOrigen, OP.ID_OrdenProduccion, OP.ID_OrdenCliente,
       OP.Secuencia, OP.Fecha_Secuencia, OP.SD, OP.Referencia, OP.Posicion, OP.Mano, OP.Orden,
       CAST(CASE WHEN S.ID_OrdenProduccion IS NOT NULL THEN 1 ELSE 0 END AS bit) AS Salteado
FROM dbo.Door_Estacion_Secuencia E
JOIN dbo.Puesto P ON P.Puesto = E.PuestoOrigen
JOIN dbo.Orden_Produccion OP ON OP.Puesto = P.Puesto AND OP.Lector = P.Lector
LEFT JOIN dbo.Door_Salteo_Puesto S ON S.Estacion = E.Estacion AND S.ID_OrdenProduccion = OP.ID_OrdenProduccion
LEFT JOIN dbo.Door_Paneles_Puesto A ON A.Estacion = E.Estacion
CROSS APPLY (VALUES (UPPER(LTRIM(RTRIM(OP.Posicion))), UPPER(LTRIM(RTRIM(OP.Mano))))) N(Posicion, Mano)
CROSS APPLY (VALUES (CASE
    WHEN N.Posicion IN ('F','FR','DELANTERA','DELANTERO') AND N.Mano IN ('L','LH','IZQ','IZQUIERDA','IZQUIERDO') THEN 1
    WHEN N.Posicion IN ('F','FR','DELANTERA','DELANTERO') AND N.Mano IN ('R','RH','DER','DERECHA','DERECHO') THEN 2
    WHEN N.Posicion IN ('R','RR','TRASERA','TRASERO') AND N.Mano IN ('L','LH','IZQ','IZQUIERDA','IZQUIERDO') THEN 4
    WHEN N.Posicion IN ('R','RR','TRASERA','TRASERO') AND N.Mano IN ('R','RH','DER','DERECHA','DERECHO') THEN 8
    ELSE 0 END)) T(Tipo)
WHERE A.Estacion IS NULL OR (A.Mascara & T.Tipo) <> 0;
GO

IF OBJECT_ID('dbo.SP_DoorPanelesPuesto', 'P') IS NULL
    EXEC ('CREATE PROCEDURE dbo.SP_DoorPanelesPuesto AS RETURN 0;');
GO
ALTER PROCEDURE dbo.SP_DoorPanelesPuesto
    @Station varchar(20), @Mask int = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF @Mask IS NULL
    BEGIN
        SELECT CONVERT(int, ISNULL(A.Mascara, 0)) FROM dbo.Door_Estacion_Secuencia E
        LEFT JOIN dbo.Door_Paneles_Puesto A ON A.Estacion = E.Estacion
        WHERE E.Estacion = @Station;
        RETURN;
    END;

    IF @Mask NOT BETWEEN 0 AND 15 THROW 50100, 'La asignación no es válida.', 1;
    BEGIN TRANSACTION;
    DECLARE @Pointer int;
    SELECT @Pointer = Puntero_ID_OrdenProduccion FROM dbo.Door_Estacion_Secuencia WITH (UPDLOCK, HOLDLOCK)
    WHERE Estacion = @Station;
    IF @Pointer IS NULL THROW 50100, 'No se encontró el puesto.', 1;

    DELETE dbo.Door_Paneles_Puesto WHERE Estacion = @Station;
    IF @Mask <> 0 INSERT dbo.Door_Paneles_Puesto (Estacion, Mascara) VALUES (@Station, @Mask);

    IF EXISTS (
        SELECT 1 FROM dbo.Validacion_Ornamento V
        WHERE V.Puesto = @Station AND V.ID_OrdenProduccion > @Pointer
          AND V.ResultadoGeneral = 'APROBADO' AND V.EstadoImpresion IN ('PENDIENTE', 'COMPLETO')
          AND NOT EXISTS (SELECT 1 FROM dbo.Door_Cola_Estacion Q
              WHERE Q.Estacion = @Station AND Q.ID_OrdenProduccion = V.ID_OrdenProduccion)
    )
        THROW 50101, 'Terminá la orden en proceso antes de quitar su tipo de panel.', 1;

    COMMIT;
    SELECT @Mask;
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

    SELECT TOP (1) Q.Referencia, Q.ID_OrdenProduccion, Q.ID_OrdenCliente, Q.Orden, Q.Secuencia, Q.SD,
           CONCAT(Q.Posicion, Q.Mano) AS Expr1, Q.Estacion AS Puesto,
           Q.Fecha_Secuencia AS FechaSecuencia, Q.Mano, Q.Posicion
    FROM dbo.Door_Cola_Estacion Q
    JOIN dbo.Door_Estacion_Secuencia E ON E.Estacion = Q.Estacion
    WHERE Q.Estacion = @Estacion AND Q.PuestoOrigen = @PuestoOrigen
      AND Q.ID_OrdenProduccion > E.Puntero_ID_OrdenProduccion AND Q.Salteado = 0
    ORDER BY Q.ID_OrdenProduccion, Q.Orden;
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

        DECLARE @Puntero INT, @Siguiente INT, @FechaAvance DATETIME,
                @ID_OrdenCliente INT, @Orden INT, @PuestoProduccion VARCHAR(20);
        SELECT @Puntero = Puntero_ID_OrdenProduccion
        FROM dbo.Door_Estacion_Secuencia WITH (UPDLOCK, HOLDLOCK)
        WHERE Estacion = @Estacion AND PuestoOrigen = @PuestoOrigen;

        IF @Puntero IS NULL
            THROW 50001, 'La estacion no esta registrada para el puesto de origen.', 1;

        SELECT @PuestoProduccion = P.Puesto
        FROM dbo.Puesto P
        WHERE P.Puesto = @PuestoOrigen;

        IF @PuestoProduccion IS NULL
            THROW 50003, 'El puesto de origen de la estacion no existe en dbo.Puesto.', 1;

        IF NOT EXISTS (
            SELECT 1 FROM dbo.Validacion_Ornamento
            WHERE ID_Validacion = @ID_Validacion
              AND ID_OrdenProduccion = @ID_OrdenProduccion AND Puesto = @Estacion
              AND ResultadoGeneral = 'APROBADO' AND EstadoImpresion = 'COMPLETO'
        )
            THROW 50002, 'La orden requiere una validacion impresa de esta estacion.', 1;

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
                THROW 50002, 'La orden ya no es la siguiente de esta estacion.', 1;

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
END;
GO
