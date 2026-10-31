BeforeAll {Import-Module (Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'FrenchExDev.Mutator.PoSh.psd1') -Force -DisableNameChecking}
Describe 'Guest cancellation endpoint' {
    It 'serves fresh stop state only for the owned job and refuses arbitrary paths' {
        InModuleScope FrenchExDev.Mutator.PoSh -Parameters @{Root=$TestDrive} {
            param($Root)
            $id='a'*32;$directory=Join-Path $Root $id
            Write-MutatorJson (Join-Path $directory 'request.json') @{RunId='owner';JobId=$id}
            $path='/jobs/'+$id+'/control'
            $health=Get-MutatorGuestControlResponse $Root owner '/health'
            $health.Data.RunId|Should -BeExactly owner
            $health.Data.Ready|Should -BeTrue
            $reply=Get-MutatorGuestControlResponse $Root owner $path
            $reply.Status|Should -Be 200
            $reply.Data.Stop|Should -BeFalse
            Write-MutatorJson (Join-Path $directory 'stop.json') @{Reason='UserRequested'}
            $reply=Get-MutatorGuestControlResponse $Root owner $path
            $reply.Data.Stop|Should -BeTrue
            $reply.Data.RunId|Should -BeExactly owner
            $reply.Data.JobId|Should -BeExactly $id
            (Get-MutatorGuestControlResponse $Root foreign $path).Status|Should -Be 403
            (Get-MutatorGuestControlResponse $Root owner '/jobs/../control').Status|Should -Be 404
            (Get-MutatorGuestControlResponse $Root owner ($path+'/source.ps1')).Status|Should -Be 404
        }
    }
}
