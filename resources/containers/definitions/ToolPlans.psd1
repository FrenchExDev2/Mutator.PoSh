@{
    Apk = @{
        Ag='the_silver_searcher'; Aws='aws-cli'; Cargo='cargo rust'; Cat='coreutils'; Cmake='cmake'; Composer='composer php85'; Ctest='cmake'; Curl='curl'
        Deno='deno'; Df='coreutils'; Diff='diffutils'; Docker='docker-cli'; Dotnet='dotnet10-sdk'; Du='coreutils'; Env='coreutils'; Fail2banClient='fail2ban'
        Fd='fd'; Find='findutils'; Gcc='gcc musl-dev'; Gh='github-cli'; Git='git'; Glab='glab'; Go='go'; GolangciLint='golangci-lint'; Gpp='g++ musl-dev'
        Gradle='gradle openjdk21-jdk'; Grep='grep'; Head='coreutils'; Helm='helm'; Iptables='iptables'; Java='openjdk21-jdk'; Jj='jujutsu'; Jq='jq'; Just='just'
        Kubectl='kubectl'; Ls='coreutils'; Make='make'; Mise='mise'; Mix='elixir erlang28'; Mvn='maven openjdk21-jdk'; Ninja='ninja-build'; Npm='nodejs npm'; Npx='nodejs npm'
        Ollama='ollama'; Php='php85'; Ping='iputils'; Pip='python3 py3-pip'; Podman='podman'; Ps='procps-ng'; Psql='postgresql18-client'; Pulumi='pulumi'
        Python='python3'; Rg='ripgrep'; Rsync='rsync'; Shellcheck='shellcheck'; Skopeo='skopeo'; Sops='sops'; Ssh='openssh-client-default'; Stat='coreutils'
        Tail='coreutils'; Task='go-task'; Tofu='opentofu'; Tree='tree'; Trunk='trunk'; Wc='coreutils'; Wget='wget'; Yadm='yadm'
    }
    Chocolatey = @{
        Aws='awscli'; Cargo='rust'; Cmake='cmake'; Composer='php composer'; Ctest='cmake'; Curl='curl'; Deno='deno'; Docker='docker-cli'; Dotnet='dotnet-sdk'
        Fd='fd'; Gcc='mingw'; Gcloud='gcloudsdk'; Gh='gh'; Git='git'; Glab='glab'; Go='golang'; GolangciLint='golangci-lint'; Gpp='mingw'; Gradle='openjdk gradle'
        Hadolint='hadolint'; Helm='kubernetes-helm'; Java='openjdk'; Jq='jq'; Just='just'; Kubectl='kubernetes-cli'; Liquibase='openjdk liquibase'; Make='make'
        Mise='mise'; Mix='elixir'; Mvn='openjdk maven'; Ninja='ninja'; Npm='nodejs-lts'; Npx='nodejs-lts'; Ollama='ollama'; Php='php'; Pip='python'; Podman='podman-cli'
        Pulumi='pulumi'; Python='python'; Quarto='quarto'; Rg='ripgrep'; Rsync='rsync'; Sbt='openjdk sbt'; Shellcheck='shellcheck'; Sops='sops'; Ssh='openssh'
        Task='go-task'; Terraform='terraform'; Tofu='opentofu'; Wget='wget'; Bun='bun'
    }
    GitWindows = @('Cat','Df','Diff','Du','Env','Find','Grep','Head','Ls','Ps','Stat','Tail','Tree','Wc')
    Npm = @{
        AstGrep='@ast-grep/cli'; Biome='@biomejs/biome'; Eslint='eslint'; Gt='@withgraphite/graphite-cli'; Jest='jest'; Markdownlint='markdownlint-cli'
        Next='next'; Nx='nx'; Oxlint='oxlint'; Playwright='playwright'; Pnpm='pnpm'; Prettier='prettier'; Prisma='prisma'; Shopify='@shopify/cli'; Tsc='typescript'; Turbo='turbo'; Vitest='vitest'; Yarn='yarn'
    }
    Pip = @{
        AnsiblePlaybook='ansible-core'; Basedpyright='basedpyright'; Black='black'; Flake8='flake8'; Mypy='mypy'; Pio='platformio'; Poetry='poetry'; PreCommit='pre-commit'
        Pylint='pylint'; Pytest='pytest'; Ruff='ruff'; Sqlfluff='sqlfluff'; Ty='ty'; Uv='uv'; Yamllint='yamllint'
    }
    Gem = @{Bundle='bundler'; Rails='rails'; Rake='rake'; Rspec='rspec'; Rubocop='rubocop'}
    Composer = @{Ecs='symplify/easy-coding-standard'; Paratest='brianium/paratest'; Pest='pestphp/pest'; Phpstan='phpstan/phpstan'; Phpunit='phpunit/phpunit'; Pint='laravel/pint'}
    Go = @{Jira='github.com/ankitpokhrel/jira-cli/cmd/jira'; Oc='github.com/openshift/oc/cmd/oc'}
    Infrastructure = @('Engine','Utility.Agent','Utility.Filters')
    Unsupported = @{
        Brew=@{Windows='Homebrew has no native Windows installation; WSL is a different Linux environment.'}
        AnsiblePlaybook=@{Windows='Windows is not supported as a native Ansible control node.'}
        Fail2banClient=@{Windows='Fail2ban requires a Unix/Linux host and its firewall/log facilities.'}
        Iptables=@{Windows='iptables requires the Linux netfilter kernel API.'}
        Journalctl=@{Windows='journalctl requires systemd journals and has no native Windows implementation.'}
        Systemctl=@{Windows='systemctl requires systemd and has no native Windows implementation.'}
        Skopeo=@{Windows='No native Windows skopeo build is supported; use the Linux client.'}
        Xcodebuild=@{Linux='xcodebuild is part of Apple Xcode and requires macOS.';Windows='xcodebuild is part of Apple Xcode and requires macOS.'}
        Yadm=@{Windows='yadm is a Bash/POSIX executable; this native Windows image does not substitute WSL or MSYS shell execution.'}
    }
    Constraints = @{
        Docker='CLI only; supply a compatible external Docker daemon.';Podman='CLI only; supply a compatible external Podman service.'
        Kubectl='CLI only; cluster credentials and connectivity are not embedded.';Helm='CLI only; cluster credentials are not embedded.'
        Playwright='The CLI is installed; Playwright browsers do not support Alpine/musl and are not installed here.'
        Gradle='Project gradlew wrappers remain project-owned; the image installs the native Gradle launcher.'
        Mvn='Project mvnw wrappers remain project-owned; the image installs Maven, not project-specific wrappers or mvnd.'
        Rails='Native gems may require additional compiler/SDK dependencies when the image is built.'
        Artisan='Creates a Laravel workload so php artisan is available; it is not a standalone artisan.exe.'
        Phpt='Installs PHP.Gt PHPT and a matching PHP run-tests.php script; php remains the native launcher.'
    }
}
