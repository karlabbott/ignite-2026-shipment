/* Zava Logistics — seed data.
   Idempotent: re-running tops the board back up without duplicating carriers. */

USE shipping;
GO

MERGE dbo.carriers AS target
USING (VALUES
    ('ZAV', N'Zava Logistics',       N'Seattle'),
    ('CAS', N'Cascade Logistics',    N'Portland'),
    ('PSX', N'Puget Sound Express',  N'Tacoma'),
    ('RNR', N'Rainier Overland',     N'Spokane')
) AS source (code, name, hub_city)
ON target.code = source.code
WHEN NOT MATCHED THEN
    INSERT (code, name, hub_city) VALUES (source.code, source.name, source.hub_city);
GO

/* Seed a starting board only if the table is empty, so rehearsals that already
   generated traffic are not disturbed. */
IF NOT EXISTS (SELECT 1 FROM dbo.shipments)
BEGIN
    DECLARE @routes TABLE (
        origin NVARCHAR(60), destination NVARCHAR(60),
        description NVARCHAR(120), weight DECIMAL(6,2));

    INSERT INTO @routes VALUES
        (N'Seattle, WA',   N'Chicago, IL',      N'Server chassis, 2U',      28.40),
        (N'Portland, OR',  N'Austin, TX',       N'Network switches (x4)',   11.25),
        (N'Tacoma, WA',    N'Atlanta, GA',      N'Cold chain, pharma',       6.80),
        (N'Spokane, WA',   N'Denver, CO',       N'Machine parts',           64.10),
        (N'Seattle, WA',   N'Boston, MA',       N'Trade show crate',       142.00),
        (N'Everett, WA',   N'Phoenix, AZ',      N'Avionics, AOG',            3.60),
        (N'Bellevue, WA',  N'Nashville, TN',    N'Retail apparel',          19.75),
        (N'Olympia, WA',   N'Miami, FL',        N'Marine hardware',         52.30),
        (N'Redmond, WA',   N'Raleigh, NC',      N'Lab equipment',           27.90),
        (N'Kent, WA',      N'Salt Lake City, UT', N'Palletised consumables', 88.15),
        (N'Renton, WA',    N'Minneapolis, MN',  N'Printed materials',        9.40),
        (N'Auburn, WA',    N'Columbus, OH',     N'Automotive spares',       41.60);

    DECLARE @statuses TABLE (idx INT, status VARCHAR(20));
    INSERT INTO @statuses VALUES
        (0, 'CREATED'), (1, 'PICKED_UP'), (2, 'IN_TRANSIT'),
        (3, 'AT_HUB'),  (4, 'OUT_FOR_DELIVERY'), (5, 'DELIVERED');

    DECLARE @i INT = 0;
    DECLARE @origin NVARCHAR(60), @dest NVARCHAR(60),
            @desc NVARCHAR(120), @weight DECIMAL(6,2);

    DECLARE route_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT origin, destination, description, weight FROM @routes;
    OPEN route_cursor;
    FETCH NEXT FROM route_cursor INTO @origin, @dest, @desc, @weight;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        DECLARE @carrier INT =
            (SELECT carrier_id FROM dbo.carriers
              ORDER BY carrier_id OFFSET (@i % 4) ROWS FETCH NEXT 1 ROWS ONLY);
        DECLARE @status VARCHAR(20) =
            (SELECT status FROM @statuses WHERE idx = @i % 6);
        DECLARE @tracking VARCHAR(20) =
            CONCAT('ZAV', RIGHT(CONCAT('00000000', CAST(100000 + @i * 7919 AS VARCHAR(9))), 8));

        INSERT INTO dbo.shipments
            (tracking_number, carrier_id, origin, destination, description,
             weight_kg, status, created_by, created_at, updated_at)
        VALUES
            (@tracking, @carrier, @origin, @dest, @desc, @weight, @status,
             N'seed', DATEADD(hour, -(@i * 3 + 6), SYSUTCDATETIME()),
             DATEADD(minute, -(@i * 11 + 5), SYSUTCDATETIME()));

        DECLARE @sid BIGINT = SCOPE_IDENTITY();

        INSERT INTO dbo.status_history (shipment_id, from_status, to_status, changed_by, changed_at)
        VALUES (@sid, NULL, 'CREATED', N'seed', DATEADD(hour, -(@i * 3 + 6), SYSUTCDATETIME()));

        INSERT INTO dbo.scan_events
            (shipment_id, scan_type, location, notes, worker_host, worker_site, occurred_at)
        VALUES
            (@sid, 'ORIGIN_ACCEPT', @origin, N'Accepted at origin depot',
             N'seed', N'on-prem/hyper-v', DATEADD(hour, -(@i * 3 + 5), SYSUTCDATETIME()));

        SET @i = @i + 1;
        FETCH NEXT FROM route_cursor INTO @origin, @dest, @desc, @weight;
    END;

    CLOSE route_cursor;
    DEALLOCATE route_cursor;
END;
GO

SELECT COUNT(*) AS seeded_shipments FROM dbo.shipments;
GO
