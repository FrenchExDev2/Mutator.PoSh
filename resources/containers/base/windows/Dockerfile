ARG POWERSHELL_IMAGE=localhost/frenchexdev-mutator-base:debian-pwsh-7.6.7-21b87d6376d1
ARG BASE_IMAGE=docker.io/dockurr/windows@sha256:16fd7c39a3e48bb946d29c59dc6015942e5b900a1fa5d7e5552053bfc48ee2ea
FROM ${POWERSHELL_IMAGE} AS mutator-pwsh
FROM ${BASE_IMAGE}
# Build only after Export-MutatorWindowsBase retained a cleanly stopped base VM.
LABEL org.frenchexdev.mutator.base="windows-seed" org.frenchexdev.mutator.fingerprint="21b87d6376d152f91265155ef0949d0059ea2300ede5c99acfda16fb48229404"
ENV VERSION=2025 RAM_SIZE=4G CPU_CORES=2 DISK_SIZE=64G DISK_FMT=qcow2 MUTATOR_BASE_FINGERPRINT=21b87d6376d152f91265155ef0949d0059ea2300ede5c99acfda16fb48229404
COPY ["FrenchExDev.Mutator.PoSh/test/Artifacts/container-bases/windows/seed/", "/seed/"]
COPY ["FrenchExDev.Mutator.PoSh/resources/containers/definitions/guest/Start-SeededGuest.sh", "/opt/mutator/Start-SeededGuest.sh"]
RUN chmod +x /opt/mutator/Start-SeededGuest.sh && test -f /seed/base.json && command -v qemu-img && command -v jq
ENTRYPOINT ["/usr/bin/tini", "-s", "/opt/mutator/Start-SeededGuest.sh"]

# PowerShell Core in the Linux host of a VM image. Guest PowerShell remains separate.
COPY --from=mutator-pwsh /opt/microsoft/powershell/7/ /opt/microsoft/powershell/7/
# The VM host already supplies ICU, Kerberos, OpenSSL and libstdc++ for Samba/QEMU.
# The following execution is the capability gate; no distribution upgrade is performed.
RUN chmod +x /opt/microsoft/powershell/7/pwsh && ln -s /opt/microsoft/powershell/7/pwsh /usr/local/bin/pwsh
RUN ["pwsh", "-NoLogo", "-NoProfile", "-Command", "if ($PSVersionTable.PSEdition -ne 'Core' -or $PSVersionTable.PSVersion.ToString() -ne '7.6.7') { throw 'Required PowerShell Core version is unavailable' }"]
LABEL org.frenchexdev.mutator.controller-fingerprint="8fb2b51ce44a288390ab53773ad433f96eb4f596c873b9ef521e18e616c60d7a"
