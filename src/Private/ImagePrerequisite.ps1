function Initialize-MutatorImagePrerequisite {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Private dependency builder runs inside the explicit New-MutatorContainerImage ShouldProcess boundary.')]
    [CmdletBinding()]
    param([string]$Dockerfile,[string]$ModuleRoot,[string]$OutputDirectory,[string]$Connection,[int]$MemoryMiB,[int]$Cpus,[int]$TimeoutSeconds,[string]$BaseImage)
    $runtime=Get-MutatorContainerRuntime $ModuleRoot
    $text=[IO.File]::ReadAllText($Dockerfile)
    $parents=@([regex]::Matches($text,'(?m)^ARG (BASE_IMAGE|POWERSHELL_IMAGE)=(localhost/[^\s]+)')|Where-Object {!$BaseImage -or $_.Groups[1].Value -ne 'BASE_IMAGE'}|ForEach-Object {$_.Groups[2].Value}|Sort-Object -Unique)
    foreach($image in $parents){
        $known=@($runtime.Images.Keys|Where-Object {$runtime.Images[$_] -ceq $image})
        if($known.Count -ne 1){throw ('Unknown local build dependency: '+$image)}
        $variant=switch($known[0]){'Bootstrap'{'WindowsBootstrap'};'Alpine'{'Alpine'};'Debian'{'Debian'};'Swift'{'Swift'};'Windows'{'Windows'};'MacBootstrap'{'MacOSBootstrap'};'MacOS'{'MacOS'};default{throw ('Unsupported build dependency: '+$known[0])}}
        $lockRoot=Join-Path $script:MutatorRoot 'test/Artifacts/image-build-locks'
        [void][IO.Directory]::CreateDirectory($lockRoot)
        $key=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes(($Connection+'|'+$image))))
        $lock=$null;$deadline=[datetimeoffset]::UtcNow.AddSeconds($TimeoutSeconds)
        try{
            while(!$lock){
                try{$lock=[IO.File]::Open((Join-Path $lockRoot ($key+'.lock')),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}
                catch [IO.IOException]{if([datetimeoffset]::UtcNow -ge $deadline){throw 'Timed out waiting for the shared image build.'};Start-Sleep -Milliseconds 500}
            }
            $inspect=Invoke-MutatorContainerCommand -Arguments @('image','inspect',$image) -Directory $ModuleRoot -Connection $Connection
            if($inspect.Outcome -ne 'Success'){
                $parameters=@{ModulePath=(Join-Path $ModuleRoot 'FrenchExDev.Mutator.PoSh');BaseVariant=$variant;OutputDirectory=(Join-Path $OutputDirectory ('dependencies/'+$variant))
                    Connection=$Connection;MemoryMiB=$MemoryMiB;Cpus=$Cpus;TimeoutSeconds=$TimeoutSeconds}
                $built=New-MutatorContainerImage @parameters
                @{Image=$image;ImageId=$built.ImageId;Built=$true;Receipt=(Join-Path $parameters.OutputDirectory 'build.json')}
            }else{
                $value=@($inspect.Stdout|ConvertFrom-Json -AsHashtable)[0]
                @{Image=$image;ImageId=$value.Id;Built=$false}
            }
        }finally{if($lock){$lock.Dispose()}}
    }
}
