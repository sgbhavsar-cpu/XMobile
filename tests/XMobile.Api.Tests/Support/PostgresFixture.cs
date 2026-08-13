using Npgsql;
using Testcontainers.PostgreSql;

namespace XMobile.Api.Tests.Support;

/// <summary>
/// One real Postgres+PostGIS container, schema loaded from db/schema/*.sql in filename order —
/// exactly db/README.md's own "create a database locally" recipe, run once per test collection.
/// Proving the schema-first EF mappings actually agree with a live database is the point of this
/// project; a container is what makes that provable in CI, not just on a laptop with Postgres
/// already installed.
/// </summary>
public sealed class PostgresFixture : IAsyncLifetime
{
    private readonly PostgreSqlContainer _container = new PostgreSqlBuilder()
        .WithImage("postgis/postgis:16-3.4")
        .WithDatabase("xmobile")
        .WithUsername("xmobile")
        .WithPassword("xmobile")
        .Build();

    public string ConnectionString => _container.GetConnectionString();

    public async Task InitializeAsync()
    {
        await _container.StartAsync();
        await LoadSchemaAsync();
    }

    public Task DisposeAsync() => _container.DisposeAsync().AsTask();

    private async Task LoadSchemaAsync()
    {
        var schemaDir = RepoPaths.SchemaDirectory();
        var files = Directory.GetFiles(schemaDir, "*.sql").OrderBy(f => f, StringComparer.Ordinal);

        await using var connection = new NpgsqlConnection(ConnectionString);
        await connection.OpenAsync();

        foreach (var file in files)
        {
            var sql = await File.ReadAllTextAsync(file);
            await using var command = new NpgsqlCommand(sql, connection) { CommandTimeout = 120 };
            try
            {
                await command.ExecuteNonQueryAsync();
            }
            catch (PostgresException ex)
            {
                throw new InvalidOperationException($"Failed applying {Path.GetFileName(file)}: {ex.Message}", ex);
            }
        }
    }
}
