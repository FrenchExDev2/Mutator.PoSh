FROM __BASE__
__INSTALL__
RUN __PROBE__
ENTRYPOINT ["pwsh", "-NoLogo", "-NoProfile", "-NonInteractive"]
