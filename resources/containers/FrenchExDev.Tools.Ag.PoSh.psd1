@{
    # Ag also has a Windows port. Use Linux only when the native executable is missing.
    Binary = 'ag'
    UseWhen = 'Missing'
    PackageManager = 'apk'
    Packages = @('the_silver_searcher=2.2.0-r1')
}
