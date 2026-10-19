SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
USE shipping;
GO

IF OBJECT_ID('dbo.failure_runners', 'U') IS NULL
CREATE TABLE dbo.failure_runners (
    runner_id UNIQUEIDENTIFIER NOT NULL PRIMARY KEY,
    last_seen DATETIME2 NOT NULL
);
GO

IF OBJECT_ID('dbo.failure_injection_jobs', 'U') IS NULL
CREATE TABLE dbo.failure_injection_jobs (
    poll_id BIGINT NOT NULL PRIMARY KEY
        REFERENCES dbo.failure_polls(poll_id) ON DELETE CASCADE,
    state VARCHAR(12) NOT NULL
        CHECK (state IN ('queued', 'running', 'succeeded', 'failed')),
    runner_id UNIQUEIDENTIFIER NULL,
    requested_at DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
    started_at DATETIME2 NULL,
    finished_at DATETIME2 NULL
);
GO

CREATE OR ALTER PROCEDURE dbo.usp_request_failure_injection @poll_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    BEGIN TRANSACTION;
    DECLARE @lock INT;
    EXEC @lock = sys.sp_getapplock @Resource = 'zava-failure-control',
        @LockMode = 'Exclusive', @LockOwner = 'Transaction', @LockTimeout = 5000;
    IF @lock < 0 THROW 50001, 'Could not lock fault controls', 1;

    DECLARE @reason VARCHAR(32) = NULL;
    IF EXISTS (SELECT 1 FROM dbo.failure_injection_jobs WHERE poll_id = @poll_id)
        SET @reason = 'already_requested';
    ELSE IF NOT EXISTS (
        SELECT 1 FROM dbo.failure_polls WITH (UPDLOCK, HOLDLOCK)
        WHERE poll_id = @poll_id AND state = 'locked'
          AND poll_id = (SELECT MAX(poll_id) FROM dbo.failure_polls)
          AND winner_code IN ('freeze_azurelinux', 'degrade_worker_sql', 'delay_worker_claims')
    )
        SET @reason = 'poll_not_locked';
    ELSE IF EXISTS (
        SELECT 1 FROM dbo.failure_polls p
        LEFT JOIN dbo.failure_injection_jobs j ON j.poll_id = p.poll_id
        WHERE p.state = 'injected'
           OR (p.state NOT IN ('recovered', 'closed') AND j.state IN ('queued', 'running', 'failed'))
    )
        SET @reason = 'fault_unresolved';
    ELSE IF NOT EXISTS (
        SELECT 1 FROM dbo.failure_runners
        WHERE last_seen > DATEADD(second, -15, SYSUTCDATETIME())
    )
        SET @reason = 'runner_offline';

    IF @reason IS NULL
    BEGIN
        INSERT dbo.failure_injection_jobs(poll_id, state) VALUES (@poll_id, 'queued');
        SET @reason = 'queued';
    END;
    COMMIT;
    SELECT @reason AS reason;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_claim_failure_injection @runner_id UNIQUEIDENTIFIER
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    BEGIN TRANSACTION;
    DECLARE @lock INT;
    EXEC @lock = sys.sp_getapplock @Resource = 'zava-failure-control',
        @LockMode = 'Exclusive', @LockOwner = 'Transaction', @LockTimeout = 5000;
    IF @lock < 0 THROW 50001, 'Could not lock fault controls', 1;

    MERGE dbo.failure_runners AS target
    USING (SELECT @runner_id AS runner_id) AS source
    ON target.runner_id = source.runner_id
    WHEN MATCHED THEN UPDATE SET last_seen = SYSUTCDATETIME()
    WHEN NOT MATCHED THEN INSERT (runner_id, last_seen)
        VALUES (@runner_id, SYSUTCDATETIME());

    -- Never execute a delayed request after a runner outage or replay a claimed job.
    UPDATE j SET state = 'failed', finished_at = SYSUTCDATETIME()
    FROM dbo.failure_injection_jobs j JOIN dbo.failure_polls p ON p.poll_id = j.poll_id
    WHERE j.state = 'queued'
      AND (j.requested_at < DATEADD(second, -30, SYSUTCDATETIME())
           OR p.state <> 'locked'
           OR p.poll_id <> (SELECT MAX(poll_id) FROM dbo.failure_polls));

    DECLARE @poll_id BIGINT;
    IF NOT EXISTS (
        SELECT 1 FROM dbo.failure_injection_jobs j
        JOIN dbo.failure_polls p ON p.poll_id = j.poll_id
        WHERE j.state = 'running' AND p.state NOT IN ('recovered', 'closed')
    )
    BEGIN
        SELECT TOP (1) @poll_id = poll_id
        FROM dbo.failure_injection_jobs WHERE state = 'queued' ORDER BY requested_at;
        UPDATE dbo.failure_injection_jobs
        SET state = 'running', runner_id = @runner_id, started_at = SYSUTCDATETIME()
        WHERE poll_id = @poll_id;
    END;
    COMMIT;
    SELECT @poll_id AS poll_id;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_finish_failure_injection
    @poll_id BIGINT, @runner_id UNIQUEIDENTIFIER, @succeeded BIT
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE j SET
        state = CASE WHEN @succeeded = 1 AND p.state = 'injected'
                     THEN 'succeeded' ELSE 'failed' END,
        finished_at = SYSUTCDATETIME()
    FROM dbo.failure_injection_jobs j
    JOIN dbo.failure_polls p ON p.poll_id = j.poll_id
    WHERE j.poll_id = @poll_id AND j.runner_id = @runner_id AND j.state = 'running';
    SELECT CAST(CASE WHEN EXISTS (
        SELECT 1 FROM dbo.failure_injection_jobs
        WHERE poll_id = @poll_id AND runner_id = @runner_id
          AND state IN ('succeeded', 'failed')
    ) THEN 1 ELSE 0 END AS BIT) AS updated;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_open_failure_poll
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    BEGIN TRANSACTION;
    DECLARE @lock INT;
    EXEC @lock = sys.sp_getapplock @Resource = 'zava-failure-control',
        @LockMode = 'Exclusive', @LockOwner = 'Transaction', @LockTimeout = 5000;
    IF @lock < 0 THROW 50001, 'Could not lock fault controls', 1;
    IF EXISTS (
        SELECT 1 FROM dbo.failure_polls p
        LEFT JOIN dbo.failure_injection_jobs j ON j.poll_id = p.poll_id
        WHERE p.state = 'injected'
           OR (p.state NOT IN ('recovered', 'closed') AND j.state IN ('queued', 'running', 'failed'))
    )
    BEGIN
        ROLLBACK;
        SELECT CAST(0 AS BIT) AS opened, NULL AS poll_id;
        RETURN;
    END;
    UPDATE dbo.failure_polls SET state = 'closed', closed_at = SYSUTCDATETIME()
    WHERE state = 'open';
    INSERT dbo.failure_polls(state) VALUES ('open');
    DECLARE @poll_id BIGINT = SCOPE_IDENTITY();
    COMMIT;
    SELECT CAST(1 AS BIT) AS opened, @poll_id AS poll_id;
END;
GO

IF DATABASE_PRINCIPAL_ID(N'shipping_app') IS NOT NULL
BEGIN
    GRANT SELECT ON dbo.failure_runners TO shipping_app;
    GRANT SELECT ON dbo.failure_injection_jobs TO shipping_app;
    GRANT EXECUTE ON dbo.usp_request_failure_injection TO shipping_app;
    GRANT EXECUTE ON dbo.usp_claim_failure_injection TO shipping_app;
    GRANT EXECUTE ON dbo.usp_finish_failure_injection TO shipping_app;
END;
GO
