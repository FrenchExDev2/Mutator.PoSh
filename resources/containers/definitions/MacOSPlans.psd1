@{
    Brew=@{
        Ag='the_silver_searcher'; Aws='awscli'; Bun='bun'; Cargo='rust'; Cmake='cmake'; Composer='composer'; Ctest='cmake'; Deno='deno'; Docker='docker'; Dotnet='dotnet'
        Fd='fd'; Gcc='gcc'; Gcloud='google-cloud-sdk'; Gh='gh'; Glab='glab'; Go='go'; GolangciLint='golangci-lint'; Gpp='gcc'; Gradle='gradle'; Gt='graphite'
        Hadolint='hadolint'; Helm='helm'; Java='openjdk@21'; Jira='jira-cli'; Jj='jj'; Jq='jq'; Just='just'; Kubectl='kubernetes-cli'; Liquibase='liquibase'; Make='make'
        Mise='mise'; Mix='elixir'; Mvn='maven'; Ninja='ninja'; Npm='node'; Npx='node'; Oc='openshift-cli'; Ollama='ollama'; Php='php'; Pip='python'; Podman='podman'
        Psql='libpq'; Pulumi='pulumi'; Python='python'; Quarto='quarto'; Rg='ripgrep'; Rsync='rsync'; Sbt='sbt'; Shellcheck='shellcheck'; Skopeo='skopeo'; Sops='sops'
        Task='go-task'; Terraform='hashicorp/tap/terraform'; Tofu='opentofu'; Tree='tree'; Trunk='trunk'; Wget='wget'; Yadm='yadm'
    }
    Cask=@{Gcloud='gcloud-cli';Quarto='quarto'}
    Builtin=@('Brew','Cat','Curl','Df','Diff','Du','Env','Find','Git','Grep','Head','Ls','Ping','Ps','Ssh','Stat','Swift','Tail','Wc')
    Unsupported=@{Iptables='iptables requires Linux netfilter.';Journalctl='journalctl requires systemd; use the Debian image.';Systemctl='systemctl requires systemd; use the Debian image.'}
    Prerequisites=@{Npm=@('node');Pip=@('python@3.14');Gem=@('ruby');Composer=@('php','composer');Go=@('go','git')}
}
