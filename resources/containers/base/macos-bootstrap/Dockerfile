ARG POWERSHELL_IMAGE=localhost/frenchexdev-mutator-base:debian-pwsh-7.6.7-21b87d6376d1
ARG BASE_IMAGE=docker.io/dockurr/macos@sha256:08d1bcaac74ad44d548b7ce683b3dded083512d2a0d26416f9a620b763f8ea3d
FROM ${POWERSHELL_IMAGE} AS mutator-pwsh
FROM ${BASE_IMAGE}
# Prepare this base once on Apple hardware, then export the cleanly stopped VM.
LABEL org.frenchexdev.mutator.base="macos" org.frenchexdev.mutator.fingerprint="ec1fe92ae9144bd9a64ec0793bf5fb141a39e497e607801c4193d1682aa9bf65" org.frenchexdev.mutator.hardware="apple"
ENV VERSION=15 RAM_SIZE=4G CPU_CORES=2 DISK_SIZE=64G DISK_FMT=qcow2
COPY ["FrenchExDev.Mutator.PoSh/resources/containers/definitions/bootstrap/", "/shared/mutator/bootstrap/"]
COPY ["FrenchExDev.Mutator.PoSh/resources/containers/definitions/macos/", "/shared/mutator/"]
COPY ["FrenchExDev.Mutator.PoSh/resources/containers/base/macos-bootstrap/runtime.json", "/shared/mutator/runtime.json"]
# Complete the macOS installation and run Install-MacOSBase.sh in its terminal.

# PowerShell Core in the Linux host of a VM image. Guest PowerShell remains separate.
COPY --from=mutator-pwsh /opt/microsoft/powershell/7/ /opt/microsoft/powershell/7/
# The VM host already supplies ICU, Kerberos, OpenSSL and libstdc++ for Samba/QEMU.
# The following execution is the capability gate; no distribution upgrade is performed.
RUN chmod +x /opt/microsoft/powershell/7/pwsh && ln -s /opt/microsoft/powershell/7/pwsh /usr/local/bin/pwsh
RUN ["pwsh", "-NoLogo", "-NoProfile", "-Command", "if ($PSVersionTable.PSEdition -ne 'Core' -or $PSVersionTable.PSVersion.ToString() -ne '7.6.7') { throw 'Required PowerShell Core version is unavailable' }"]
LABEL org.frenchexdev.mutator.controller-fingerprint="8fb2b51ce44a288390ab53773ad433f96eb4f596c873b9ef521e18e616c60d7a"
