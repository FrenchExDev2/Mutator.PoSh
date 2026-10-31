BeforeAll { Import-Module (Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'FrenchExDev.Mutator.PoSh.psd1') -Force -DisableNameChecking }
Describe 'Validation native cancellation signal' {
    It 'cancels a quiet child through Mutator without requiring another output record' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$TestDrive} {
            param($Root)
            $signal=Join-Path $Root 'quiet-stop.json'
            $code="[IO.File]::WriteAllText('$signal','stop');Start-Sleep -Seconds 20"
            $r=Invoke-MutatorNative (Join-Path $PSHOME 'pwsh') @('-NoProfile','-Command',$code) $Root -TimeoutSeconds 10 -StopPath $signal
            $r.Outcome|Should -BeExactly Cancelled
        }
    }
    It 'forwards the signal through a validation child and retains its partial native evidence' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$TestDrive} {
            param($Root)
            $signal=Join-Path $Root 'validation-stop.json'
            $proof=Join-Path $Root 'proof'
            $code="[IO.File]::WriteAllText('$signal','stop');Start-Sleep -Seconds 20"
            $r=Invoke-MutatorValidationChild -Arguments @('-NoProfile','-Command',$code) -Directory $Root -Proof $proof -TimeoutSeconds 10 -StopPath $signal
            $r.NativeOutcome|Should -BeExactly Cancelled
            (Read-MutatorJson (Join-Path $proof 'native.json')).Outcome|Should -BeExactly Cancelled
            Test-Path (Join-Path $proof 'stdout.log')|Should -BeTrue
            Test-Path (Join-Path $proof 'stderr.log')|Should -BeTrue
        }
    }
    It 'does not start a child when its stop signal is already present' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$TestDrive} {
            param($Root)
            $signal=Join-Path $Root 'existing-stop.json'
            $sentinel=Join-Path $Root 'must-not-start'
            [IO.File]::WriteAllText($signal,'stop')
            $code="[IO.File]::WriteAllText('$sentinel','started')"
            $r=Invoke-MutatorNative (Join-Path $PSHOME 'pwsh') @('-NoProfile','-Command',$code) $Root -TimeoutSeconds 10 -StopPath $signal
            $r.Outcome|Should -BeExactly Cancelled
            Test-Path $sentinel|Should -BeFalse
        }
    }
}
