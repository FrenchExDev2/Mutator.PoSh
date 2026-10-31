BeforeAll { Import-Module (Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'FrenchExDev.Mutator.PoSh.psd1') -Force -DisableNameChecking }
Describe 'Explicit base transfer after switching the default connection to rootful' {
    It 'finds the explicitly requested rootless base with rootful selection <Explicit>' -ForEach @(@{Explicit=$true},@{Explicit=$false}) {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$TestDrive;Explicit=$Explicit} {
            param($Root,$Explicit)
            $target=if($Explicit){'machine-root'}else{''}
            $recipe=Join-Path $Root 'image.psd1'
            Set-Content $recipe "@{Binary='ag';Packages=@('ag')}"
            $script:BaseLoaded=$false
            Mock Invoke-MutatorContainerCommand {
                param($Arguments,$Connection)
                switch($Arguments[0]) {
                    'system' {return @{Outcome='Success';Stdout='[{"Name":"machine-root","Default":true},{"Name":"machine","Default":false}]'}}
                    'save' {
                        $Connection | Should -BeExactly machine
                        Set-Content -LiteralPath $Arguments[2] 'archive'
                        return @{Outcome='Success'}
                    }
                    'load' {
                        $Connection | Should -BeExactly $target
                        $script:BaseLoaded=$true
                        return @{Outcome='Success'}
                    }
                    'image' {
                        if($Arguments[-1] -eq ('a'*64)){
                            if($Connection -ne 'machine' -and !$script:BaseLoaded){return @{Outcome='Failed'}}
                            return @{Outcome='Success';Stdout=('[{"Id":"'+('a'*64)+'","Os":"linux"}]')}
                        }
                        return @{Outcome='Success';Stdout=('[{"Id":"'+('b'*64)+'","Os":"linux"}]')}
                    }
                    default {throw ('Unexpected native operation: '+$Arguments[0])}
                }
            }
            $result=New-MutatorToolImage -RecipePath $recipe -BaseImage ('a'*64) -Connection $target -OutputDirectory (Join-Path $Root 'built')
            $result.BaseSourceConnection | Should -BeExactly machine
            $result.BaseImageId | Should -BeExactly ('a'*64)
            $result.Connection | Should -BeExactly $target
            Should -Invoke Invoke-MutatorContainerCommand -Times 1 -ParameterFilter {$Arguments[0] -eq 'save' -and $Connection -eq 'machine'}
            Should -Invoke Invoke-MutatorContainerCommand -Times 1 -ParameterFilter {$Arguments[0] -eq 'load'}
            Should -Invoke Invoke-MutatorContainerCommand -Times 0 -ParameterFilter {$Arguments[0] -eq 'images'}
            @(Get-ChildItem (Join-Path $Root 'built') -File -Filter '*.tar').Count | Should -Be 0
        }
    }
}
