@{
    # The validated PowerShell. To upgrade, change Version, the URIs and all three official archive checksums.
    # LinuxSHA256 was verified against the release asset digest at https://api.github.com/repos/PowerShell/PowerShell/releases/tags/v7.6.7.
    # Linux images download powershell-<Version>-linux-musl-x64.tar.gz in test/Containerfile.
    Stable = @{
        Version = '7.6.7'
        LinuxMuslSHA256 = 'D74A1B7E1D1FBF150AE6F29E083953CE07FC833FE9D66218D54940A8638249C6'
        LinuxUri = 'https://github.com/PowerShell/PowerShell/releases/download/v7.6.7/powershell-7.6.7-linux-x64.tar.gz'
        LinuxSHA256 = '6896F9E3A6B0A354BF470835A96DA76D2F801CD50DCF047AD7C4563BF93BF431'
        WindowsUri = 'https://github.com/PowerShell/PowerShell/releases/download/v7.6.7/PowerShell-7.6.7-win-x64.zip'
        WindowsSHA256 = 'D2F952EBDBF24386CB8923553AA58E41A846DB35A6155EA04C58142A4B16DBB7'
    }
}
