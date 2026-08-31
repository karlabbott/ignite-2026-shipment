SET QUOTED_IDENTIFIER ON;
GO

DECLARE @user SYSNAME = N'$(appuser)';
DECLARE @pass NVARCHAR(128) = N'$(apppass)';
DECLARE @sql NVARCHAR(MAX);

IF NOT EXISTS (SELECT 1 FROM sys.sql_logins WHERE name = @user)
BEGIN
    SET @sql = N'CREATE LOGIN ' + QUOTENAME(@user) +
               N' WITH PASSWORD = N''' + REPLACE(@pass, '''', '''''') +
               N''', CHECK_POLICY = ON;';
    EXEC sp_executesql @sql;
END
ELSE
BEGIN
    SET @sql = N'ALTER LOGIN ' + QUOTENAME(@user) +
               N' WITH PASSWORD = N''' + REPLACE(@pass, '''', '''''') + N''';';
    EXEC sp_executesql @sql;
END
GO

USE [$(dbname)];
GO

DECLARE @user SYSNAME = N'$(appuser)';
DECLARE @sql NVARCHAR(MAX);

IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = @user)
BEGIN
    SET @sql = N'CREATE USER ' + QUOTENAME(@user) +
               N' FOR LOGIN ' + QUOTENAME(@user) + N';';
    EXEC sp_executesql @sql;
END

IF NOT EXISTS (
    SELECT 1
      FROM sys.database_role_members drm
      JOIN sys.database_principals role_principal
        ON role_principal.principal_id = drm.role_principal_id
      JOIN sys.database_principals member_principal
        ON member_principal.principal_id = drm.member_principal_id
     WHERE role_principal.name = N'db_datareader'
       AND member_principal.name = @user
)
BEGIN
    SET @sql = N'ALTER ROLE db_datareader ADD MEMBER ' + QUOTENAME(@user) + N';';
    EXEC sp_executesql @sql;
END

IF NOT EXISTS (
    SELECT 1
      FROM sys.database_role_members drm
      JOIN sys.database_principals role_principal
        ON role_principal.principal_id = drm.role_principal_id
      JOIN sys.database_principals member_principal
        ON member_principal.principal_id = drm.member_principal_id
     WHERE role_principal.name = N'db_datawriter'
       AND member_principal.name = @user
)
BEGIN
    SET @sql = N'ALTER ROLE db_datawriter ADD MEMBER ' + QUOTENAME(@user) + N';';
    EXEC sp_executesql @sql;
END

SET @sql = N'GRANT EXECUTE ON dbo.usp_record_heartbeat TO ' + QUOTENAME(@user) + N';';
EXEC sp_executesql @sql;
SET @sql = N'GRANT EXECUTE ON dbo.usp_claim_scan TO ' + QUOTENAME(@user) + N';';
EXEC sp_executesql @sql;
GO
