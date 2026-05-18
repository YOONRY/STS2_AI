using System.Reflection.Metadata;
using System.Reflection.PortableExecutable;

if (args.Length == 0)
{
    Console.Error.WriteLine("usage: MetadataDump <assembly.dll> [filter]");
    Environment.Exit(2);
    return;
}

var path = args[0];
var filter = args.Length > 1 ? args[1] : "";
using var stream = File.OpenRead(path);
using var pe = new PEReader(stream);
var md = pe.GetMetadataReader();

string S(StringHandle h) => md.GetString(h);

foreach (var typeHandle in md.TypeDefinitions)
{
    var type = md.GetTypeDefinition(typeHandle);
    var ns = S(type.Namespace);
    var name = S(type.Name);
    var full = string.IsNullOrEmpty(ns) ? name : ns + "." + name;
    if (!string.IsNullOrEmpty(filter) && !full.Contains(filter, StringComparison.OrdinalIgnoreCase))
    {
        var methodHit = false;
        foreach (var methodHandle in type.GetMethods())
        {
            var method = md.GetMethodDefinition(methodHandle);
            if (S(method.Name).Contains(filter, StringComparison.OrdinalIgnoreCase))
            {
                methodHit = true;
                break;
            }
        }
        if (!methodHit)
        {
            continue;
        }
    }

    Console.WriteLine($"TYPE {full}");
    foreach (var attrHandle in type.GetCustomAttributes())
    {
        Console.WriteLine($"  ATTR {AttributeName(attrHandle)}");
    }
    foreach (var methodHandle in type.GetMethods())
    {
        var method = md.GetMethodDefinition(methodHandle);
        Console.WriteLine($"  METHOD {S(method.Name)} {method.Attributes}");
        foreach (var attrHandle in method.GetCustomAttributes())
        {
            Console.WriteLine($"    ATTR {AttributeName(attrHandle)}");
        }
    }
}

return;

string AttributeName(CustomAttributeHandle attrHandle)
{
    var attr = md.GetCustomAttribute(attrHandle);
    var ctor = attr.Constructor;
    EntityHandle parent;
    switch (ctor.Kind)
    {
        case HandleKind.MemberReference:
            parent = md.GetMemberReference((MemberReferenceHandle)ctor).Parent;
            break;
        case HandleKind.MethodDefinition:
            parent = md.GetMethodDefinition((MethodDefinitionHandle)ctor).GetDeclaringType();
            break;
        default:
            return ctor.Kind.ToString();
    }

    return TypeName(parent);
}

string TypeName(EntityHandle handle)
{
    switch (handle.Kind)
    {
        case HandleKind.TypeReference:
        {
            var tr = md.GetTypeReference((TypeReferenceHandle)handle);
            var ns = S(tr.Namespace);
            var name = S(tr.Name);
            return string.IsNullOrEmpty(ns) ? name : ns + "." + name;
        }
        case HandleKind.TypeDefinition:
        {
            var td = md.GetTypeDefinition((TypeDefinitionHandle)handle);
            var ns = S(td.Namespace);
            var name = S(td.Name);
            return string.IsNullOrEmpty(ns) ? name : ns + "." + name;
        }
        default:
            return handle.Kind.ToString();
    }
}
