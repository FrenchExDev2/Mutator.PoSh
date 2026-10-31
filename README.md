# FrenchExDev.Mutator.PoSh

Mutator pilote des campagnes de mutation PowerShell et C# sous **PowerShell 7.6+ Core**. Il prépare des copies isolées des projets, vérifie les tests avant mutation, répartit les workers, conserve les preuves et fournit un suivi dans le terminal et dans une page HTML.

Il utilise **PSMutant** pour PowerShell et **Stryker.NET** pour les projets C# configurés. Les modules à tester lui fournissent leurs sources, leurs tests et leur configuration de mutation.

## Prérequis

- PowerShell 7.6 ou supérieur, édition Core.
- PSMutant **0.6.0** et Pester **6.2.0** pour les mutations PowerShell.
- Campagnes Windows : Windows Sandbox et son CLI `wsb.exe` sur un hôte Windows, avec PowerShell Core 7.6+ et les outils épinglés installés localement pour préparer la copie privée.
- Campagnes Linux : Podman et une image Linux locale contenant PowerShell Core 7.6+, Pester 6.2.0 et PSMutant 0.6.0.
- `powershell-yaml` **0.4.12** pour lire et écrire la configuration YAML des moteurs de conteneurs.
- Pour C# : le SDK .NET, Stryker.NET et les dépendances attendues par le projet, préparés dans l'environnement d'exécution choisi.
- Pour les conteneurs : Podman ou Docker et une connexion utilisable. Les builds Docker nécessitent Buildx.
- Pour les invités Windows : un hôte Linux avec KVM et virtualisation imbriquée, ainsi qu'une image Windows préparée.

L'import du module et la consultation des rapports ne démarrent ni campagne, ni installation d'outil, ni watchdog.

## Isolation obligatoire de PSMutant

| OS des mutants | Environnement obligatoire |
| --- | --- |
| Windows | Windows Sandbox (Bac à sable Windows) |
| Linux | Conteneur Podman |

`-OS Windows` ou `-OS Linux` sélectionne l'OS cible, indépendamment de l'hôte.
Sans `-OS`, la cible est l'OS de l'hôte. Une campagne Windows nécessite un hôte
Windows. Aucun mutant de campagne ne doit s'exécuter directement sur l'hôte :
un environnement absent ou indisponible produit un échec, sans repli.
Docker et l'ancien invité Windows KVM ne sont pas des environnements de campagne PSMutant.
Le recheck historique exécutait aussi des mutants sur l'hôte : cette entrée
est désormais refusée depuis l'hôte, dans l'attente d'un adaptateur de recheck
isolé. Utiliser une campagne complète isolée pour l'instant.

Windows Sandbox reçoit les sources et les outils en lecture seule, prépare une
copie de travail privée et écrit ses rapports/progrès dans le seul partage
accessible en écriture. Le réseau et le presse-papiers sont désactivés. Chaque
package possède son ID de Sandbox ; son arrêt ne vise que cet ID. Le runtime
PowerShell Core et les outils proviennent de l'hôte, sans téléchargement dans
l'invité. Cet adaptateur prend en charge PSMutant ; un projet avec Stryker doit
sélectionner `-SkipStryker` pour cette campagne Windows.

Pour Linux, la recette ou la définition du module reste prioritaire, même si
le binaire existe sur l'hôte. À défaut de définition, fournir explicitement
`-ContainerBaseImage` avec une image locale prête à l'emploi ; le lanceur
utilise son ID immuable et n'effectue aucun pull automatique.

```powershell
Invoke-MutatorRun -ModulePath ../MonModule.PoSh -OS Windows -SkipStryker -Background
Invoke-MutatorRun -ModulePath ../MonModule.PoSh -OS Linux -ContainerEngine Podman `
    -ContainerBaseImage localhost/mon-runtime-tests:stable -Background
```

Le monitoring distingue l'environnement requis de celui effectivement démarré.
Un ancien run exécuté sur l'hôte affiche `Host`, même si sa configuration
mentionne Podman. `Pending (WindowsSandbox)` ou `Pending (Podman)` indique que
l'environnement requis n'est pas encore démarré.

Par défaut, les rapports restent dans le logiciel PowerShell testé :
`<module testé>/test/Artifacts/mutator/<run-id>/packages/<package-id>/`.
`mutation.json` et son reçu de contexte y sont conservés, ainsi que les journaux
et les rapports partiels. `-RunRoot` permet de choisir explicitement une autre
destination ; il est obligatoire pour une sélection de plusieurs modules.
Dans Windows Sandbox, `C:\MutatorRun` est seulement le chemin invité du partage
`sandbox-run` de ce package. `C:\MutatorRun\stop.json` est un signal d'arrêt,
pas un emplacement de rapports sur l'hôte. Les métadonnées du package exposent
`HostReportDirectory`, `HostExchangeDirectory` et `GuestExchangeDirectory`.

## Démarrage rapide

Les exemples suivants partent du répertoire de Mutator. `../MonModule.PoSh` désigne un module voisin à remplacer par le projet à tester.

```powershell
Import-Module ./FrenchExDev.Mutator.PoSh.psd1 -DisableNameChecking

# À faire une fois pour un module qui possède déjà ses tests.
New-MutatorConfiguration -ModulePath ../MonModule.PoSh

# Démarrer une campagne explicite dans un terminal interactif.
mutator -ModulePath ../MonModule.PoSh -UI
```

`mutator` est l'alias de `Invoke-MutatorRun`. Sans `-UI` ni `-Background`, la commande attend la fin du run et retourne son état. Pour travailler en arrière-plan :

```powershell
$run = Invoke-MutatorRun -ModulePath ../MonModule.PoSh `
    -WorkerBudget 4 -ThrottleLimit 2 -MemoryBudgetMiB 4096 -Background

Get-MutatorProgress -Path $run.Path
Get-MutatorFailure -Path $run.Path -MaxItems 20
```

Les workers d'arrière-plan sont lancés sans fenêtre interactive. Mutator conserve les journaux natifs localement ; les commandes de suivi permettent de consulter l'avancement et les problèmes sans afficher ces journaux.

## Définir le périmètre

Chaque module sélectionné doit posséder `test/psmutant.config.json`. Cette configuration déclare les sources, leurs associations de tests, les seuils et les sous-arbres autorisés dans la sandbox.

`New-MutatorConfiguration` recense le module racine déclaré dans le manifeste, les scripts PowerShell à la racine et les fichiers `.ps1` et `.psm1` sous `src` et `resources`. Il associe chaque source à l'ensemble des fichiers de tests découverts et fixe `coveredLinesOnly` à `false`.

```powershell
# Déclarer aussi les modules voisins nécessaires aux tests.
New-MutatorConfiguration -ModulePath ../MonModule.PoSh `
    -Dependency MonProjet.Common.PoSh

# Remplacer explicitement une configuration existante.
New-MutatorConfiguration -ModulePath ../MonModule.PoSh `
    -Dependency MonProjet.Common.PoSh -Force
```

Les dépendances doivent être déclarées dans `sandboxSubtrees`. Une source ou un test situé hors du périmètre autorisé fait échouer la préparation. La configuration doit être maintenue lors de l'ajout de sources, de tests ou de dépendances.

Un chemin de module sélectionne ce module. Un chemin de racine sélectionne ses modules enfants possédant une configuration de mutation ; `-Include` filtre leurs noms :

```powershell
mutator -Path .. -Include 'MonProjet.*.PoSh' -UI -Parallel -RunRoot ./test/Artifacts/mutator
```

`-ModulePath` accepte aussi plusieurs modules. Tous doivent se trouver sous la même `SourceRoot`, déduite par défaut du parent du premier module sélectionné.

## Déroulement d'une campagne

Chaque package dispose de son processus et de sa sandbox. Le déroulement comprend la préparation des sources et des outils, la baseline des tests, la découverte des mutants, leur exécution et la conservation des résultats. Lorsqu'une image doit être construite, la phase `Building Container` précède les tests ; un échec de build conserve les logs et la phase en erreur, sans démarrer les tests.

L'adaptateur PSMutant crée une copie privée de l'outil épinglé et vérifie les points d'adaptation attendus. Il désactive TestRegistry et le parallélisme interne de Pester, puis ajoute la progression et l'arrêt coopératif. L'installation d'origine est conservée.

`-TestOrder FocusedFirst`, valeur par défaut, place les tests unitaires proches de la source avant les tests d'intégration. `-TestOrder Configured` conserve l'ordre déclaré. Ces options réordonnent les associations sans retirer de test ni de mutant.

Chaque mutant impose un nouveau chargement du code. Entre les fichiers de tests d'un même mutant, les états de module pris en charge sont restaurés ; un état qui ne peut pas être restauré de façon sûre entraîne un réimport complet.

Pour les modules qui possèdent `engine/dotnet-tools.json`, Stryker.NET est sélectionné sauf avec `-SkipStryker`. `engine/mutator.json` doit nommer `Project` et `TestProject`, et le SDK dotnet doit être présent sur l'hôte : `-StrykerRuntime` accepte `Auto` et `Host`. Les erreurs de restauration et d'outillage restent des échecs.

## Critères de réussite

Le gate de mutation exige une découverte non vide, une baseline verte et **100 % de mutation brute**, sur le périmètre complet.

- Aucun survivant, échantillonnage ou filtrage limité aux lignes couvertes n'est accepté.
- Les exclusions d'équivalence sont refusées à la génération, au lancement et à la validation finale.
- Un score arrondi à 100 % avec un survivant reste un échec.
- Les associations manquantes, outils en erreur et sources modifiées empêchent la validation.
- Un rapport partiel ne possède pas de score final.

Les anciennes déclarations d'équivalence et les anciens rapports ajustés peuvent être conservés comme diagnostics historiques. Ils ne constituent pas une preuve du gate strict. Les rapports Stryker distinguent les mutants ignorés ou non compilables des résultats scorés.

## Parallélisme et budgets

```powershell
mutator -Path .. -Include 'MonProjet.*.PoSh' -UI -Parallel -RunRoot ./test/Artifacts/mutator `
    -ThrottleLimit 4 -Workers 2 -WorkerBudget 8 -MemoryBudgetMiB 8192
```

| Paramètre | Rôle |
| --- | --- |
| `WorkerBudget` | Nombre maximal de workers de mutation allouables au run. |
| `ThrottleLimit` | Nombre maximal de packages actifs simultanément. |
| `Workers` | Nombre de workers demandé par package. |
| `MemoryBudgetMiB` | Budget mémoire utilisé par le planificateur pour ses réservations. |
| `Parallel` | Ajuste automatiquement la concurrence des packages si `ThrottleLimit` n'est pas fourni. |
| `RunRoot` | Racine de stockage des runs et de leur pool de ressources partagé. |

L'exemple autorise au plus quatre packages de deux workers chacun, dans les limites des ressources disponibles. PSMutant peut répartir ses mutants entre workers ; Pester reste séquentiel à l'intérieur de chacun.

Les runs d'un même `RunRoot` partagent un pool protégé par verrou. Le premier run en fixe les budgets ; les réservations des workers encore vivants sont prises en compte avant tout nouveau lancement. Des racines distinctes ne partagent pas ce pool.

Les réservations du planificateur ne constituent pas un plafond de mémoire physique imposé par le système. Les limites des conteneurs et le watchdog hôte ont des rôles séparés.

## Suivi dans le terminal et le dashboard

```powershell
Watch-MutatorRun -Path $run.Path
Get-MutatorProgress -Path $run.Path
Get-MutatorFailure -Path $run.Path -MaxItems 20 -Skip 0

Show-MutatorDashboard -Open
Get-MutatorRun
```

L'interface `-UI` affiche les phases actives, les packages, les workers, les mutants évalués, les survivants, les erreurs et la mémoire. `S` ou `Ctrl+C` demande l'arrêt coopératif ; `Q` détache la vue en laissant le run continuer. `Watch-MutatorRun` rattache ensuite un terminal au run.

L'interface interactive exige une console avec entrée et sortie non redirigées. Pour un script ou un agent, utiliser `Get-MutatorProgress`, `Get-MutatorFailure` ou `Watch-MutatorRun -Once`.

`Get-MutatorFailure` retourne les erreurs d'exécution et les survivants PowerShell/C#, avec leurs fichiers, lignes, opérateurs et rapports. Le résultat est borné à 20 éléments et 8192 octets par défaut. `Truncated` et `NextSkip` indiquent la pagination ; `-MaxItems`, `-MaxOutputBytes` et `-Skip` règlent la lecture.

Le dashboard présente l'historique, les filtres de statut, plateforme et module, les détails des runs et les liens vers les preuves. Le superviseur régénère la page pendant l'exécution ; le navigateur la recharge toutes les cinq secondes. Les observations horaires réelles sont conservées dans `hourly.jsonl`.

Les pourcentages de mutants portent sur les périmètres déjà découverts. La progression des packages n'est pas une estimation du temps restant. Les dates inconnues et les intervalles sans observation ne sont pas reconstitués.

Les catalogues de traduction du terminal, du dashboard et des rapports de validation se trouvent sous `resources/localization/`, avec des textes français et anglais.

## Arrêt et reprise

```powershell
Stop-MutatorRun -Path $run.Path

# En dernier recours : terminer les processus identifiés de ce run.
Stop-MutatorRun -Path $run.Path -Force

# Après l'arrêt, reprendre un seul module du run interrompu.
$resumed = Resume-MutatorRun -Path $run.Path `
    -ModulePath ../MonModule.PoSh -Background
```

L'arrêt coopératif permet à PSMutant d'écrire un rapport partiel avant nettoyage. Un arrêt forcé ou un crash peut empêcher cette dernière écriture ; les preuves déjà conservées restent disponibles.

Le pilote Git conserve les diagnostics d'une inspection de conteneur défaillante. Avant d'arrêter un workload Linux en erreur pendant les mutations, il demande l'arrêt coopératif et attend les rapports. Son conteneur arrêté est conservé pour diagnostic ; seuls les workloads réussis sont supprimés automatiquement. Un OS sélectionné en attente est marqué `Pending`, distinct de `NotSelected`.

Les définitions Git appartiennent à CliEnvironment : utiliser `Export-CliEnvironmentGitDefinition`. Le générateur historique `Export-MutatorContainerDefinition` refuse de les écraser, y compris avec `-Force`. Les autres définitions existantes conservent leur contrat actuel.

Le pilote fige également les sources de CliEnvironment : le code de préparation de l'environnement fait partie des dépendances de la campagne, même s'il n'est pas une cible de mutation Git.

Pour les invités Git Windows, Mutator prépare l'arborescence des rapports partagés avant le démarrage. L'invité écrit les fichiers de preuves dans ces répertoires ; ses sources de travail et ses sandboxes restent sur son disque local. Cela évite les créations de répertoires SMB que le pont Windows/WSL peut signaler en erreur après les avoir matérialisées.

Sous pression mémoire, la récupération du cache Podman compacte aussi les pages libres lorsque le noyau le permet. Cela permet à WSL de restituer les pages libérées à Windows sans redémarrer la VM ; le reçu indique si la compaction a effectivement été exécutée. Le watchdog peut également compacter une VM dont le cache a déjà été vidé mais qui conserve beaucoup de mémoire disponible.

La reprise exige le rapport partiel et son reçu de contexte. Les contenus des sources, tests et dépendances, la configuration effective, le runtime, Pester et l'adaptateur doivent correspondre. Un ancien reçu importé seul ne permet pas une reprise. Aucun run interrompu n'est repris automatiquement à l'import du module ou à l'ouverture du dashboard.

## Réévaluer les survivants

```powershell
Invoke-MutatorRecheck -ModulePath ../MonModule.PoSh `
    -ReportPath ./test/Artifacts/runs/mon-run/packages/p0000/mutation.json
```

Ce contrôle réexécute les survivants enregistrés dans une copie figée, avec les tests courants et un worker. Les sources de production et les opérateurs doivent correspondre au rapport d'origine.

Il conserve sa provenance, son propre rapport et les compteurs `Rechecked`, `NowKilled` et `Survived`. Il ne modifie pas la baseline et ne produit pas de score global : `FullGateSatisfied` reste `false`. Une campagne complète reste nécessaire pour valider les corrections.

## Configuration de Podman et Docker

Mutator conserve ses réglages dans **`~/.mutator/config.yaml`**. La variable **`MUTATOR_CONFIG_PATH`** permet de choisir un autre fichier. Les sections `docker` et `podman` définissent les endpoints, l'activation et le moteur par défaut :

```yaml
docker:
  pipe: '\\.\pipe\docker_engine'
  enabled: true
  default: false
podman:
  pipe: '\\.\pipe\podman-ma-machine'
  enabled: true
  default: true
```

```powershell
Get-MutatorEngine
Set-MutatorEngine -Podman '\\.\pipe\podman-ma-machine' -PodmanEnabled:$true
Set-MutatorEngine -DefaultEngine Podman
Get-MutatorEngine -Default

# Choisir le moteur et la connexion pour la session Mutator.
Set-MutatorContainerEngine -Engine Docker -Connection mon-contexte-docker

# Ou choisir explicitement le moteur pour un run.
mutator -ModulePath ../MonModule.PoSh `
    -ContainerEngine Podman -ContainerConnection ma-connexion -UI
```

Un seul moteur peut avoir `default: true`, et il doit être activé. Sans marqueur explicite, la sélection préfère Podman s'il est activé, puis Docker. Sans moteur activé, elle échoue. Une chaîne vide passée à `-Docker` ou `-Podman` efface l'endpoint concerné ; `-WhatIf` prépare les changements sans les écrire.

`-ContainerConnection` désigne une connexion Podman ou un contexte Docker. Les appels utilisent `podman --connection` ou `docker --context` sans modifier le contexte global des CLI. Un moteur désactivé est refusé même avec une connexion explicite. La configuration ne démarre aucun service.

Le moteur et ses réglages sont conservés dans les reçus du run. Le choix du CLI Docker ne prouve pas, à lui seul, l'utilisation d'un daemon Docker distinct : un contexte peut pointer vers une API Podman.

## Exécuter les tests dans un conteneur Linux

Un module peut déclarer une recette dans `test/mutator.container.psd1` :

```powershell
@{
    Binary = 'mon-outil'
    UseWhen = 'Missing'
    PackageManager = 'apk'
    Packages = @('mon-paquet=version-revision')
}
```

`UseWhen = 'Windows'` sélectionne le conteneur sur Windows ; `Missing` le sélectionne lorsque le binaire natif est absent ; `Always` le sélectionne sur tous les hôtes. L'absence d'un binaire ne suffit pas sans une recette ou une définition prise en charge.

Les recettes personnalisées exigent une base locale explicite, compatible avec `apk` ou `apt`, contenant PowerShell 7.6+, Pester 6.2.0 et PSMutant 0.6.0. Le parcours C# exige aussi son SDK et ses outils.

```powershell
New-MutatorToolImage -RecipePath ../MonModule.PoSh/test/mutator.container.psd1 `
    -BaseImage localhost/mon-runtime-tests:stable `
    -OutputDirectory ./test/Artifacts/images/mon-outil

mutator -ModulePath ../MonModule.PoSh `
    -ContainerBaseImage localhost/mon-runtime-tests:stable -UI
```

`New-MutatorToolImage` prépare l'image sans démarrer une campagne. Le cache dépend du Containerfile et de l'identité complète de la base ; le reçu conserve les empreintes de la recette et des images. Une image construite ne constitue pas, à elle seule, une validation des tests ou des mutations.

Les sources sont montées en lecture seule et les rapports en écriture. Les tests s'exécutent sans réseau. Les limites CPU et mémoire dépendent des contrôleurs cgroup disponibles ; leur absence apparaît dans `Container.ResourceWarning`, tandis que les réservations du planificateur restent actives.

Avec Podman, Mutator peut sélectionner une connexion sœur rootful lorsque la connexion courante ne permet pas d'appliquer la limite mémoire. Une connexion explicitement fournie désactive cette sélection automatique. Les reçus conservent la connexion et les limites réellement utilisées.

## Mutations dans un invité Windows

`-WindowsGuestImage` sélectionne une image module Windows déjà préparée. Ce choix prend priorité sur la recette Linux du module :

```powershell
mutator -ModulePath ../MonModule.PoSh `
    -WindowsGuestImage localhost/mon-module:windows `
    -ContainerConnection ma-connexion-root -MemoryBudgetMiB 6144 `
    -WorkerBudget 1 -Workers 1 -SkipStryker -UI
```

Le backend utilise `dockurr/windows` : Windows s'exécute dans une VM hébergée par un conteneur Linux. La sélection d'une image préparée ne déclenche ni installation Windows ni reconstruction de cette image.

Chaque invité réserve 6144 Mio dans le planificateur, applique ce plafond au conteneur et attribue 4096 Mio à Windows, avec deux vCPU. Le nombre de workers PSMutant reste limité à un par invité ; plusieurs packages peuvent recevoir chacun une VM si les budgets le permettent.

La baseline, la découverte complète et les mutations s'exécutent dans une sandbox locale à Windows. Les états et rapports sont recopiés vers le partage ; les preuves de l'invité sont conservées sous `windows-reports`. Stryker participe pour les projets C# configurés, sauf avec `-SkipStryker`.

`-WindowsGuestTimeoutMinutes`, 120 par défaut, inclut le démarrage. `-WindowsGuestJobTimeoutSeconds` ajoute une limite après préparation ; la première échéance atteinte s'applique. Un timeout demande un rapport partiel avant l'arrêt, sans garantir qu'un rapport de mutation existe si la découverte n'a pas commencé. La publication finale et l'arrêt ACPI peuvent prolonger la fermeture.

Les disques et journaux sont conservés. Les commandes `Start-MutatorGuestBase`, `Get-MutatorGuestBase`, `Wait-MutatorGuestBase`, `Stop-MutatorGuestBase`, `Restart-MutatorGuestBase` et `Export-MutatorGuestBase` couvrent le cycle des bases gérées. L'export exige une base vérifiée et arrêtée proprement.

## Validation par suite et système

Depuis le répertoire de Mutator :

```powershell
./Invoke-Validation.ps1 -Test Unit,Integration -OS Linux

./Invoke-Validation.ps1 -Test Unit,Integration,Mutations `
    -OS Linux,Windows -ContainerConnection ma-connexion-root -UI -Ram 40go

# macOS exige une machine adaptée et une base déjà préparée.
./Invoke-Validation.ps1 -OS MacOS -MacOSConnection ma-connexion-macos
```

Le script s'appuie sur `Invoke-MutatorValidation`. Par défaut, il sélectionne Mutator, les trois suites et Linux/Windows. Les paramètres `-Test` et `-OS` acceptent des listes. `-ModulePath` permet de sélectionner d'autres modules voisins de Mutator avec leur configuration complète.

Les systèmes sont exécutés successivement ; chaque environnement passe Unit, Integration puis Mutations. Linux exécute PowerShell dans son conteneur ; Windows et macOS l'exécutent dans leur invité. Une base absente, obsolète ou nécessitant une préparation manuelle peut bloquer la validation. macOS reste `NotSelected` s'il n'est pas demandé ; sa prise en charge réelle doit être qualifiée sur une machine adaptée.

Le budget initial est de 6144 Mio, avec `Workers = 1` et `WorkerBudget = 2`. Le répertoire `-OutputDirectory` doit être neuf ou vide. Les preuves sont conservées sous `test/Artifacts/validation/<run-id>/` : `summary.json`, `index.html`, sources figées, logs et rapports par système, suite et module.

Les gates complets exigent 100 % de couverture des commandes, lignes et branches, ainsi que 100 % de mutation brute. Une sélection partielle ne valide pas le gate complet. Une réussite Linux ne qualifie pas Windows ou macOS ; un build réussi ne prouve pas l'exécution dans le système invité.

## Pilote Git avec bases réutilisables

`Invoke-MutatorGitImageValidation` utilise les définitions et bases préparées par `FrenchExDev.CliEnvironment.PoSh`. Il exécute Unit, Integration, couverture complète et PSMutant, avec un worker, Linux puis Windows invité. Les sources montées restent en lecture seule ; les mutations travaillent dans des copies locales. Les empreintes du module et de ses dépendances doivent rester identiques pendant toute la campagne.

Depuis la racine du workspace :

```powershell
Invoke-MutatorGitImageValidation -ModuleRoot ./PoSh/FrenchExDev `
    -OS Linux,Windows -Connection podman-frenchexdev-root -Ram 40go -UI

# Sur un hôte Windows : contrôleur indépendant du terminal appelant.
$run = Invoke-MutatorGitImageValidation -ModuleRoot ./PoSh/FrenchExDev `
    -OS Linux,Windows -Connection podman-frenchexdev-root -Ram 40go -Background
$run.Path
```

Le mode détaché conserve `controller.request.json`, l'identité réelle du processus dans `controller.json` et son résultat dans `controller.result.json`. Le suivi reste disponible dans `summary.json` et `index.html`. Il ne reprend pas une ancienne campagne et n'utilise pas sa réussite partielle comme score final. `-BaselineOnly` omet les mutations et ne satisfait jamais le gate complet.

L'exécution Windows utilise une politique `Bypass` limitée au processus PowerShell de l'invité, nécessaire aux modules de développement non signés chargés depuis le partage. La politique d'exécution de l'hôte n'est pas modifiée.

## Watchdog mémoire de l'hôte Windows

`mutator ... -Ram 40go` active ou reconfigure un watchdog indépendant, avec un seuil de 40 Go et une marge préventive de 2 Go. `40go` et `40GB` utilisent des unités décimales ; `40GiB` et `40Gio` utilisent des unités binaires. Sans `-Ram`, un run ne modifie pas le watchdog existant.

```powershell
Start-MutatorMemoryWatchdog -LimitGB 50 -HeadroomGB 2 -PollSeconds 2
Get-MutatorMemoryWatchdog
Stop-MutatorMemoryWatchdog
```

Le seuil porte sur la RAM physique totale utilisée du poste, tous logiciels compris. Le watchdog fonctionne dans un processus caché et indépendant. Il intervient uniquement sur les workers et superviseurs Mutator enregistrés : chemin du script, répertoire de run, PID et heure de création doivent correspondre. Les sessions PowerShell et les éditeurs extérieurs à ces runs sont exclus.

Pour un worker Mutator identifié, il demande d'abord l'arrêt avec conservation des preuves. Un verrou exclusif empêche deux récupérations concurrentes ; tous les processus possédés doivent être arrêtés avant une relance. Les packages non terminés peuvent ensuite redémarrer dans de nouveaux runs : reprise avec contexte valide, ou exécution complète si aucun rapport partiel exploitable n'existe. Les paramètres de workers, de moteur et de délais sont conservés. Les packages déjà réussis ne sont pas relancés.

`-PodmanMachine` permet aussi la récupération du cache Linux propre d'une machine Podman identifiée. Les interventions et mesures restent sous `test/Artifacts/memory-watchdog`. Le watchdog reste actif jusqu'à son arrêt explicite ou la fermeture de session Windows ; il n'est pas installé au démarrage du poste. Son échantillonnage ne constitue pas un plafond matériel garanti.

## Rapports et intégration

| Emplacement par défaut | Contenu |
| --- | --- |
| `src/` et `resources/` | Code du module, adaptateurs, templates et catalogues. |
| `test/Artifacts/runs/<run-id>/` | Plan `run.json`, états des packages, événements, rapports et reçus. |
| `test/Artifacts/validation/<run-id>/` | Synthèse et preuves des validations par système. |
| `test/Artifacts/rechecks/` | Réévaluations ciblées des survivants. |
| `.cache/mutation-tools/` | Copies privées des outils adaptés. |

`-RunRoot` permet de déplacer le stockage des campagnes. Les états, rapports complets et partiels conservent leur provenance ; une erreur, une interruption et un résultat incomplet ne deviennent pas des réussites lors de leur consultation.

```powershell
Export-MutatorReport -Path $run.Path -RunId validation-locale
```

Cette commande copie les preuves dans le répertoire d'artefacts de chaque module testé, avec les rapports de mutation, une synthèse et un reçu comparant les empreintes des sources. `Import-MutatorRun` référence des reçus anciens dans le dashboard sans exécuter de mutation. Un reçu importé ne fournit pas à lui seul le contexte nécessaire à une reprise.

La consultation du dashboard est bornée à 100 runs par défaut (`-MaxRuns`). Elle ne modifie pas l'historique des runs terminés. Une erreur de rendu est conservée dans `dashboard-error.json` et n'interrompt pas la supervision.

La rétention est explicite et désactivée par défaut :

```powershell
Get-MutatorRetentionPlan -RunRoot ./test/Artifacts/runs -KeepLast 20
Remove-MutatorRun -RunRoot ./test/Artifacts/runs -KeepLast 20 -WhatIf
```

Seuls les anciens runs natifs réussis sont candidats après le délai de 30 jours par défaut. Les runs incomplets, importés, actifs ou liés sont conservés. `Remove-MutatorRun` redemande confirmation et contrôle les chemins et l'éligibilité au moment de supprimer ; aucune purge n'est déclenchée par l'import, les tests ou le dashboard.

## Vérifier Mutator

```powershell
# Tests unitaires du module.
./test/Invoke-Tests.ps1

# Tests d'intégration, avec de petits projets isolés.
./test/Invoke-Tests.ps1 -Path ./test/Integration

# Couverture du périmètre de production de Mutator.
./test/Invoke-Tests.ps1 -CoverageModulePath .
```

Les tests d'intégration peuvent exécuter PSMutant sur de petites fixtures réelles. Les rapports de développement sont conservés sous `test/Artifacts/development/`.

Le harnais de couverture conserve `tests.xml`, `sources.json`, `coverage.xml` et `coverage.json`. Pester 6.2 fournit la couverture des commandes, mais ne mesure pas les branches. Le rapport signale cette limite avec `MissingMetrics = ['BranchCoverage']` et `FullGateSatisfied = false` ; des compteurs XML à zéro ne prouvent pas une couverture complète des branches.

Mutator conserve les résultats et les diagnostics. Les corrections des sources et des tests restent une action explicite de leur auteur.

## Validation Git : arrêt et preuves

Le pilote choisit désormais Linux par défaut. Les travaux de qualification en cours sont exécutés dans un conteneur Linux avec --init ; aucun invité Windows ne doit être lancé avant clôture de la matrice Linux applicable.

`Invoke-MutatorGitImageValidation` vérifie d'abord la configuration de mutation du module `FrenchExDev.QuietCli.Git.PoSh`. En son absence, il échoue avant de créer une validation ou un watchdog. Les tests actuels sous `dev/` et les images CliEnvironment nécessitent encore une qualification distincte ; ce pilote ne constitue pas une validation de Git.

`Stop-MutatorGitImageValidation -Path <validation>` demande un arrêt coopératif, lié à l'identité du run. Le contrôleur transmet le signal au workload. Les enfants Pester silencieux reçoivent aussi ce signal via QuietCli. Pour une mutation, le workload demande l'arrêt du run enfant, attend sa terminaison puis conserve ses preuves ; un état final ne suffit pas si un worker possédé reste vivant.

Une erreur de copie reste l'erreur principale même si l'arrêt ou la copie finale échoue également. La copie du miroir et les écritures JSON partagent le remplacement atomique borné : seul le même fichier temporaire terminé est retenté, jamais une commande de tests ou une campagne. L'ancienne destination reste conservée et le temporaire est nettoyé. Les lecteurs de progression autorisent le remplacement du fichier ouvert.

Un workload Git non réussi conserve sa sandbox et écrit retained-sandbox.json. Un arrêt ou un rapport partiel ne possède pas de score final de mutation. Les seules sandboxes supprimées automatiquement par ce wrapper sont celles dont la validation a réussi.
