USE [TB-L];
GO

IF OBJECT_ID('dbo.Door_Estacion_Secuencia', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.Door_Estacion_Secuencia
    (
        Estacion VARCHAR(20) NOT NULL PRIMARY KEY,
        PuestoOrigen VARCHAR(20) NOT NULL,
        Puntero_ID_OrdenProduccion INT NOT NULL,
        CONSTRAINT CK_Door_Estacion_DistintaDelOrigen CHECK (Estacion <> PuestoOrigen)
    );
END;
GO

IF OBJECT_ID('dbo.SP_DoorSiguientePanelEstacion', 'P') IS NULL
    EXEC ('CREATE PROCEDURE dbo.SP_DoorSiguientePanelEstacion AS RETURN 0;');
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
    ORDER BY OP.ID_OrdenProduccion, OP.Orden;
END;
GO

IF OBJECT_ID('dbo.SP_DoorFinalizarPanelEstacion', 'P') IS NULL
    EXEC ('CREATE PROCEDURE dbo.SP_DoorFinalizarPanelEstacion AS RETURN 0;');
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

-- Ajustar los identificadores antes de ejecutar en otra instalacion.
-- Cada alta nueva toma el puntero actual del origen. Volver a ejecutar no reinicia punteros.
SET XACT_ABORT ON;
BEGIN TRANSACTION;

IF NOT EXISTS (SELECT 1 FROM dbo.Puesto WHERE Puesto = 'DL01')
    THROW 50001, 'No existe el puesto de origen DL01.', 1;

INSERT dbo.Door_Estacion_Secuencia (Estacion, PuestoOrigen, Puntero_ID_OrdenProduccion)
SELECT N.Estacion, P.Puesto, P.Puntero_ID_OrdenProduccion
FROM dbo.Puesto P
CROSS JOIN (VALUES ('DL01-A'), ('DL01-B')) N(Estacion)
WHERE P.Puesto = 'DL01' AND NOT EXISTS (
    SELECT 1 FROM dbo.Door_Estacion_Secuencia E WITH (UPDLOCK, HOLDLOCK)
    WHERE E.Estacion = N.Estacion
);

COMMIT;
GO
