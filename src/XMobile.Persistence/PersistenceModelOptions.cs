using System.Reflection;

namespace XMobile.Persistence;

/// <summary>
/// XMobile.Persistence cannot reference the feature modules (they reference it), so each
/// module's `Add{Module}()` DI extension registers its own assembly here; `XMobileDbContext`
/// applies every `IEntityTypeConfiguration&lt;&gt;` found in each one when the model is built.
/// </summary>
public sealed class PersistenceModelOptions
{
    public List<Assembly> ModuleAssemblies { get; } = [];
}
