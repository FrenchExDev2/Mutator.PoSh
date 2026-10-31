ARG POWERSHELL_IMAGE=localhost/frenchexdev-mutator-base:debian-pwsh-7.6.7-21b87d6376d1
ARG BASE_IMAGE=docker.io/dockurr/windows@sha256:16fd7c39a3e48bb946d29c59dc6015942e5b900a1fa5d7e5552053bfc48ee2ea
FROM ${POWERSHELL_IMAGE} AS mutator-pwsh
FROM ${BASE_IMAGE}
# Bootstrap common Windows once in a VM, then export its stopped qcow2 disk.
LABEL org.frenchexdev.mutator.base="windows" org.frenchexdev.mutator.fingerprint="21b87d6376d152f91265155ef0949d0059ea2300ede5c99acfda16fb48229404"
ENV VERSION=2025 RAM_SIZE=4G CPU_CORES=2 DISK_SIZE=64G DISK_FMT=qcow2
COPY ["FrenchExDev.Mutator.PoSh/resources/containers/definitions/bootstrap/", "/oem/mutator/bootstrap/"]
COPY ["FrenchExDev.Mutator.PoSh/resources/containers/definitions/guest/", "/oem/"]
COPY ["FrenchExDev.Mutator.PoSh/resources/containers/base/windows-bootstrap/image.json", "/oem/mutator/image.json"]
# This shared folder receives base-ready.json from the guest, for export validation.
RUN mkdir -p /shared

# PowerShell Core in the Linux host of a VM image. Guest PowerShell remains separate.
COPY --from=mutator-pwsh /opt/microsoft/powershell/7/ /opt/microsoft/powershell/7/
# The VM host already supplies ICU, Kerberos, OpenSSL and libstdc++ for Samba/QEMU.
# The following execution is the capability gate; no distribution upgrade is performed.
RUN chmod +x /opt/microsoft/powershell/7/pwsh && ln -s /opt/microsoft/powershell/7/pwsh /usr/local/bin/pwsh
RUN ["pwsh", "-NoLogo", "-NoProfile", "-Command", "if ($PSVersionTable.PSEdition -ne 'Core' -or $PSVersionTable.PSVersion.ToString() -ne '7.6.7') { throw 'Required PowerShell Core version is unavailable' }"]
LABEL org.frenchexdev.mutator.controller-fingerprint="8fb2b51ce44a288390ab53773ad433f96eb4f596c873b9ef521e18e616c60d7a"
