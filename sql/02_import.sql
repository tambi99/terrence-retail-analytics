/* Run prepare_import.ps1 first. Change this single path to the folder containing
   the numbered CSVs ON THE SQL SERVER MACHINE. This is not a client-side path.
   All five staging tables reload atomically; an import error restores the old data. */
SET NOCOUNT ON;
SET XACT_ABORT ON;
DECLARE @ImportFolder nvarchar(2000)=N'C:\RetailPortfolio\data\sql_import';
IF DB_NAME() IN ('master','model','msdb','tempdb')
 THROW 50000, 'Select the dedicated portfolio database.', 1;
IF RIGHT(@ImportFolder,1) IN ('\','/') SET @ImportFolder=LEFT(@ImportFolder,LEN(@ImportFolder)-1);
BEGIN TRY
 BEGIN TRANSACTION;
 DECLARE @lock_result int;
 EXEC @lock_result=sys.sp_getapplock @Resource=N'RetailPortfolioReload',
  @LockMode='Exclusive',@LockOwner='Transaction',@LockTimeout=10000;
 IF @lock_result<0 THROW 50001, 'Another portfolio load is running; retry later.', 1;
 DECLARE @tables TABLE(n int PRIMARY KEY,table_name sysname);
 INSERT @tables VALUES(1,'customers'),(2,'products'),(3,'orders'),(4,'order_lines'),(5,'returns');
 DECLARE @n int=1,@name sysname,@sql nvarchar(max);
 WHILE @n<=5
 BEGIN
  SELECT @name=table_name FROM @tables WHERE n=@n;
  SET @sql=N'DELETE FROM retail_stg.'+QUOTENAME(@name)+N';
   BULK INSERT retail_stg.'+QUOTENAME(@name)+N' FROM '''+
   REPLACE(@ImportFolder+N'\'+@name+N'.csv',N'''',N'''''')+N'''
   WITH(FORMAT=''CSV'',FIRSTROW=2,CODEPAGE=''65001'',ROWTERMINATOR=''0x0a'',KEEPNULLS);
   IF EXISTS(SELECT 1 FROM retail_stg.'+QUOTENAME(@name)+N'
    WHERE TRY_CONVERT(int,source_row) IS NULL OR TRY_CONVERT(int,source_row)<1)
    THROW 50002,''Invalid source_row: import the helper-generated CSVs.'',1;
   IF EXISTS(SELECT TRY_CONVERT(int,source_row) FROM retail_stg.'+QUOTENAME(@name)+N'
    GROUP BY TRY_CONVERT(int,source_row) HAVING COUNT(*)>1)
    THROW 50003,''Duplicate source_row in imported file.'',1;
   IF NOT EXISTS(SELECT 1 FROM retail_stg.'+QUOTENAME(@name)+N')
    THROW 50004,''An imported file was empty.'',1;';
  EXEC sys.sp_executesql @sql;
  SET @n+=1;
 END;
 COMMIT TRANSACTION;
END TRY
BEGIN CATCH
 IF XACT_STATE()<>0 ROLLBACK TRANSACTION;
 THROW;
END CATCH;
SELECT 'customers' AS source_table,COUNT(*) AS raw_rows FROM retail_stg.customers
UNION ALL SELECT 'products',COUNT(*) FROM retail_stg.products
UNION ALL SELECT 'orders',COUNT(*) FROM retail_stg.orders
UNION ALL SELECT 'order_lines',COUNT(*) FROM retail_stg.order_lines
UNION ALL SELECT 'returns',COUNT(*) FROM retail_stg.returns;
