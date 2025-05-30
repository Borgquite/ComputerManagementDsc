[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Scope = 'Function')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'DSCMachineStatus', Justification = 'GlobalDsc Variable can be ignored')]
param ()

$modulePath = Join-Path -Path (Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent) -ChildPath 'Modules'

# Import the ComputerManagementDsc Common Modules
Import-Module -Name (Join-Path -Path $modulePath `
        -ChildPath (Join-Path -Path 'ComputerManagementDsc.Common' `
            -ChildPath 'ComputerManagementDsc.Common.psm1'))

Import-Module -Name (Join-Path -Path $modulePath -ChildPath 'DscResource.Common')

# Import Localization Strings
$script:localizedData = Get-LocalizedData -DefaultUICulture 'en-US'

$FailToRenameAfterJoinDomainErrorId = 'FailToRenameAfterJoinDomain,Microsoft.PowerShell.Commands.AddComputerCommand'

<#
    .SYNOPSIS
        Gets the current state of the computer.

    .PARAMETER Name
        The desired computer name.

    .PARAMETER DomainName
        The name of the domain to join.

    .PARAMETER JoinOU
        The distinguished name of the organizational unit that the computer
        account will be created in.

    .PARAMETER Credential
        Credential to be used to join a domain.

    .PARAMETER UnjoinCredential
        Credential to be used to leave a domain.

    .PARAMETER WorkGroupName
        The name of the workgroup.

    .PARAMETER Description
        The value assigned here will be set as the local computer description.

    .PARAMETER Server
        The Active Directory Domain Controller to use to join the domain.

    .PARAMETER Options
        Specifies advanced options for the Add-Computer join operation.
#>
function Get-TargetResource
{
    [CmdletBinding()]
    [OutputType([System.Collections.Hashtable])]
    param
    (
        [Parameter(Mandatory = $true)]
        [ValidateLength(1, 15)]
        [ValidateScript( { $_ -inotmatch '[\/\\:*?"<>|]' })]
        [System.String]
        $Name,

        [Parameter()]
        [System.String]
        $DomainName,

        [Parameter()]
        [System.String]
        $JoinOU,

        [Parameter()]
        [System.Management.Automation.PSCredential]
        $Credential,

        [Parameter()]
        [System.Management.Automation.PSCredential]
        $UnjoinCredential,

        [Parameter()]
        [System.String]
        $WorkGroupName,

        [Parameter()]
        [System.String]
        $Description,

        [Parameter()]
        [System.String]
        $Server,

        [Parameter()]
        [ValidateSet('AccountCreate', 'Win9XUpgrade', 'UnsecuredJoin', 'PasswordPass', 'JoinWithNewName', 'JoinReadOnly', 'InstallInvoke')]
        [System.String[]]
        $Options
    )

    Write-Verbose -Message ($script:localizedData.GettingComputerStateMessage -f $Name)

    $convertToCimCredential = New-CimInstance `
        -ClassName DSC_Credential `
        -Property @{
            Username = [System.String] $Credential.UserName
            Password = [System.String] $null
        } `
        -Namespace root/microsoft/windows/desiredstateconfiguration `
        -ClientOnly

    $convertToCimUnjoinCredential = New-CimInstance `
        -ClassName DSC_Credential `
        -Property @{
            Username = [System.String] $UnjoinCredential.UserName
            Password = [System.String] $null
        } `
        -Namespace root/microsoft/windows/desiredstateconfiguration `
        -ClientOnly

    $returnValue = @{
        Name             = $env:COMPUTERNAME
        DomainName       = Get-ComputerDomain
        JoinOU           = $JoinOU
        CurrentOU        = Get-ComputerOU
        Credential       = [ciminstance] $convertToCimCredential
        UnjoinCredential = [ciminstance] $convertToCimUnjoinCredential
        WorkGroupName    = (Get-CimInstance -Class 'Win32_ComputerSystem').Workgroup
        Description      = (Get-CimInstance -Class 'Win32_OperatingSystem').Description
        Server           = Get-LogonServer
    }

    return $returnValue
}

<#
    .SYNOPSIS
        Sets the current state of the computer.

    .PARAMETER Name
        The desired computer name.

    .PARAMETER DomainName
        The name of the domain to join.

    .PARAMETER JoinOU
        The distinguished name of the organizational unit that the computer
        account will be created in.

    .PARAMETER Credential
        Credential to be used to join a domain.

    .PARAMETER UnjoinCredential
        Credential to be used to leave a domain.

    .PARAMETER WorkGroupName
        The name of the workgroup.

    .PARAMETER Description
        The value assigned here will be set as the local computer description.

    .PARAMETER Server
        The Active Directory Domain Controller to use to join the domain.

    .PARAMETER Options
        Specifies advanced options for the Add-Computer join operation.
#>
function Set-TargetResource
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [ValidateLength(1, 15)]
        [ValidateScript( { $_ -inotmatch '[\/\\:*?"<>|]' })]
        [System.String]
        $Name,

        [Parameter()]
        [System.String]
        $DomainName,

        [Parameter()]
        [System.String]
        $JoinOU,

        [Parameter()]
        [System.Management.Automation.PSCredential]
        $Credential,

        [Parameter()]
        [System.Management.Automation.PSCredential]
        $UnjoinCredential,

        [Parameter()]
        [System.String]
        $WorkGroupName,

        [Parameter()]
        [System.String]
        $Description,

        [Parameter()]
        [System.String]
        $Server,

        [Parameter()]
        [ValidateSet('AccountCreate', 'Win9XUpgrade', 'UnsecuredJoin', 'PasswordPass', 'JoinWithNewName', 'JoinReadOnly', 'InstallInvoke')]
        [System.String[]]
        $Options
    )

    Write-Verbose -Message ($script:localizedData.SettingComputerStateMessage -f $Name)

    Assert-DomainOrWorkGroup -DomainName $DomainName -WorkGroupName $WorkGroupName

    if ($Name -eq 'localhost')
    {
        $Name = $env:COMPUTERNAME
    }

    if ($PSBoundParameters.ContainsKey('Description'))
    {
        Write-Verbose -Message ($script:localizedData.SettingComputerDescriptionMessage -f $Description)
        $win32OperatingSystemCimInstance = Get-CimInstance -ClassName Win32_OperatingSystem
        $win32OperatingSystemCimInstance.Description = $Description
        Set-CimInstance -InputObject $win32OperatingSystemCimInstance
    }

    if ($Credential)
    {
        if ($DomainName)
        {
            if ($DomainName -eq (Get-ComputerDomain))
            {
                # Rename the computer, but stay joined to the domain.
                Rename-Computer -NewName $Name -DomainCredential $Credential -Force
                Write-Verbose -Message ($script:localizedData.RenamedComputerMessage -f $Name)
            }
            else
            {
                $addComputerParameters = @{
                    DomainName = $DomainName
                    Credential = $Credential
                    Force      = $true
                }
                $rename = $false
                if ($Name -ne $env:COMPUTERNAME)
                {
                    $addComputerParameters.Add("NewName", $Name)
                    $rename = $true
                }

                if ($UnjoinCredential)
                {
                    $addComputerParameters.Add("UnjoinDomainCredential", $UnjoinCredential)
                }

                if ($JoinOU)
                {
                    $addComputerParameters.Add("OUPath", $JoinOU)
                }

                if ($Server)
                {
                    $addComputerParameters.Add("Server", $Server)
                }

                # Check for existing computer objecst using ADSI without ActiveDirectory module
                $computerObject = Get-ADSIComputer -Name $Name -DomainName $DomainName -Credential $Credential

                if ($computerObject)
                {
                    Remove-ADSIObject -Path $computerObject.Path -Credential $Credential
                    Write-Verbose -Message ($script:localizedData.DeletedExistingComputerObject -f $Name, $computerObject.Path)
                }

                if (-not [System.String]::IsNullOrEmpty($Options))
                {
                    <#
                        See https://docs.microsoft.com/en-us/powershell/module/microsoft.powershell.management/add-computer?view=powershell-5.1#parameters for available options and their description
                    #>
                    Assert-ResourceProperty @PSBoundParameters
                    $addComputerParameters.Add('Options', $Options)
                }

                # Rename the computer, and join it to the domain.
                try
                {
                    Add-Computer @addComputerParameters
                }
                catch [System.InvalidOperationException]
                {
                    <#
                        If the rename failed during the domain join, re-try the rename.
                        References to this issue:
                        https://social.technet.microsoft.com/Forums/windowsserver/en-US/81105b18-b1ff-4fcc-ae5c-2c1a7cf7bf3d/addcomputer-to-domain-with-new-name-returns-error
                        https://powershell.org/forums/topic/the-directory-service-is-busy/
                    #>
                    if ($_.FullyQualifiedErrorId -eq $failToRenameAfterJoinDomainErrorId)
                    {
                        Write-Verbose -Message $script:localizedData.FailToRenameAfterJoinDomainMessage
                        Rename-Computer -NewName $Name -DomainCredential $Credential
                    }
                    else
                    {
                        New-InvalidOperationException -Message $_.Exception.Message -ErrorRecord $_
                    }
                }
                catch
                {
                    throw $_
                }

                if ($rename)
                {
                    Write-Verbose -Message ($script:localizedData.RenamedComputerAndJoinedDomainMessage -f $Name, $DomainName)
                }
                else
                {
                    Write-Verbose -Message ($script:localizedData.JoinedDomainMessage -f $DomainName)
                }
            }
        }
        elseif ($WorkGroupName)
        {
            if ($WorkGroupName -eq (Get-CimInstance -Class 'Win32_ComputerSystem').Workgroup)
            {
                # Rename the computer, but stay in the same workgroup.
                Rename-Computer `
                    -NewName $Name

                Write-Verbose -Message ($script:localizedData.RenamedComputerMessage -f $Name)
            }
            else
            {
                if ($Name -ne $env:COMPUTERNAME)
                {
                    # Rename the computer, and join it to the workgroup.
                    Add-Computer `
                        -NewName $Name `
                        -Credential $Credential `
                        -WorkgroupName $WorkGroupName `
                        -Force

                    Write-Verbose -Message ($script:localizedData.RenamedComputerAndJoinedWorkgroupMessage -f $Name, $WorkGroupName)
                }
                else
                {
                    # Same computer name, and join it to the workgroup.
                    Add-Computer `
                        -WorkGroupName $WorkGroupName `
                        -Credential $Credential `
                        -Force

                    Write-Verbose -Message ($script:localizedData.JoinedWorkgroupMessage -f $WorkGroupName)
                }
            }
        }
        elseif ($Name -ne $env:COMPUTERNAME)
        {
            if (Get-ComputerDomain)
            {
                Rename-Computer `
                    -NewName $Name `
                    -DomainCredential $Credential `
                    -Force

                Write-Verbose -Message ($script:localizedData.RenamedComputerMessage -f $Name)
            }
            else
            {
                Rename-Computer `
                    -NewName $Name `
                    -Force

                Write-Verbose -Message ($script:localizedData.RenamedComputerMessage -f $Name)
            }
        }
    }
    else
    {
        if ($DomainName)
        {
            New-ArgumentException `
                -Message ($script:localizedData.CredentialsNotSpecifiedError) `
                -ArgumentName 'Credentials'
        }

        if ($WorkGroupName)
        {
            if ($WorkGroupName -eq (Get-CimInstance -Class 'Win32_ComputerSystem').Workgroup)
            {
                # Same workgroup, new computer name
                Rename-Computer `
                    -NewName $Name `
                    -Force

                Write-Verbose -Message ($script:localizedData.RenamedComputerMessage -f $Name)
            }
            else
            {
                if ($name -ne $env:COMPUTERNAME)
                {
                    # New workgroup, new computer name
                    Add-Computer `
                        -WorkgroupName $WorkGroupName `
                        -NewName $Name

                    Write-Verbose -Message ($script:localizedData.RenamedComputerAndJoinedWorkgroupMessage -f $Name, $WorkGroupName)
                }
                else
                {
                    # New workgroup, same computer name
                    Add-Computer `
                        -WorkgroupName $WorkGroupName

                    Write-Verbose -Message ($script:localizedData.JoinedWorkgroupMessage -f $WorkGroupName)
                }
            }
        }
        else
        {
            if ($Name -ne $env:COMPUTERNAME)
            {
                Rename-Computer `
                    -NewName $Name

                Write-Verbose -Message ($script:localizedData.RenamedComputerMessage -f $Name)
            }
        }
    }

    $global:DSCMachineStatus = 1
}

<#
    .SYNOPSIS
        Tests the current state of the computer.

    .PARAMETER Name
        The desired computer name.

    .PARAMETER DomainName
        The name of the domain to join.

    .PARAMETER JoinOU
        The distinguished name of the organizational unit that the computer
        account will be created in.

    .PARAMETER Credential
        Credential to be used to join a domain.

    .PARAMETER UnjoinCredential
        Credential to be used to leave a domain.

    .PARAMETER WorkGroupName
        The name of the workgroup.

    .PARAMETER Description
        The value assigned here will be set as the local computer description.

    .PARAMETER Options
        Specifies advanced options for the Add-Computer join operation.
#>
function Test-TargetResource
{
    [CmdletBinding()]
    [OutputType([System.Boolean])]
    param
    (
        [Parameter(Mandatory = $true)]
        [ValidateLength(1, 15)]
        [ValidateScript( { $_ -inotmatch '[\/\\:*?"<>|]' })]
        [System.String]
        $Name,

        [Parameter()]
        [System.String]
        $JoinOU,

        [Parameter()]
        [System.Management.Automation.PSCredential]
        $Credential,

        [Parameter()]
        [System.Management.Automation.PSCredential]
        $UnjoinCredential,

        [Parameter()]
        [System.String]
        $DomainName,

        [Parameter()]
        [System.String]
        $WorkGroupName,

        [Parameter()]
        [System.String]
        $Description,

        [Parameter()]
        [System.String]
        $Server,

        [Parameter()]
        [ValidateSet('AccountCreate', 'Win9XUpgrade', 'UnsecuredJoin', 'PasswordPass', 'JoinWithNewName', 'JoinReadOnly', 'InstallInvoke')]
        [System.String[]]
        $Options
    )

    Write-Verbose -Message ($script:localizedData.TestingComputerStateMessage -f $Name)

    if (($Name -ne 'localhost') -and ($Name -ne $env:COMPUTERNAME))
    {
        return $false
    }

    if ($PSBoundParameters.ContainsKey('Description'))
    {
        Write-Verbose -Message ($script:localizedData.CheckingComputerDescriptionMessage -f $Description)

        if ($Description -ne (Get-CimInstance -Class 'Win32_OperatingSystem').Description)
        {
            return $false
        }
    }

    Assert-DomainOrWorkGroup -DomainName $DomainName -WorkGroupName $WorkGroupName

    if ($DomainName)
    {
        if (-not ($Credential))
        {
            New-ArgumentException `
                -Message ($script:localizedData.CredentialsNotSpecifiedError) `
                -ArgumentName 'Credentials'
        }

        try
        {
            Write-Verbose -Message ($script:localizedData.CheckingDomainMemberMessage -f $DomainName)

            if ($DomainName.Contains('.'))
            {
                $getComputerDomainParameters = @{
                    netbios = $false
                }
            }
            else
            {
                $getComputerDomainParameters = @{
                    netbios = $true
                }
            }

            return ($DomainName -eq (Get-ComputerDomain @getComputerDomainParameters))
        }
        catch
        {
            Write-Verbose -Message ($script:localizedData.CheckingNotDomainMemberMessage)

            return $false
        }
    }
    elseif ($WorkGroupName)
    {
        Write-Verbose -Message ($script:localizedData.CheckingWorkgroupMemberMessage -f $WorkGroupName)

        return ($WorkGroupName -eq (Get-CimInstance -Class 'Win32_ComputerSystem').Workgroup)
    }
    else
    {
        # No Domain or Workgroup specified and computer name is correct
        return $true
    }
}

<#
    .SYNOPSIS
        Throws an exception if both the domain name and workgroup
        name is set.

    .PARAMETER DomainName
        The name of the domain to join.

    .PARAMETER WorkGroupName
        The name of the workgroup.
#>
function Assert-DomainOrWorkGroup
{
    [CmdletBinding()]
    param
    (
        [Parameter()]
        [System.String]
        $DomainName,

        [Parameter()]
        [System.String]
        $WorkGroupName
    )

    if ($DomainName -and $WorkGroupName)
    {
        New-InvalidOperationException `
            -Message ($script:localizedData.DomainNameAndWorkgroupNameError)
    }
}

<#
    .SYNOPSIS
        Returns the domain the computer is joined to.

    .PARAMETER NetBios
        Specifies if the NetBIOS name is returned instead of
        the fully qualified domain name.
#>
function Get-ComputerDomain
{
    [CmdletBinding()]
    [OutputType([System.String])]
    param
    (
        [Parameter()]
        [Switch]
        $NetBios
    )

    try
    {
        $domainInfo = Get-CimInstance -ClassName Win32_ComputerSystem
        if ($domainInfo.PartOfDomain -eq $true)
        {
            if ($NetBios)
            {
                $domainName = (Get-CimInstance -ClassName Win32_NTDomain -Filter "DnsForestName='$($domainInfo.Domain)'").DomainName
            }
            else
            {
                $domainName = $domainInfo.Domain
            }
        }
        else
        {
            $domainName = ''
        }

        return $domainName
    }
    catch [System.Management.Automation.MethodInvocationException]
    {
        Write-Verbose -Message ($script:localizedData.ComputerNotInDomainMessage)
    }
}

<#
    .SYNOPSIS
        Gets the organisation unit in the domain that the
        computer account exists in.
#>
function Get-ComputerOU
{
    [CmdletBinding()]
    param
    (
    )

    $ou = $null

    if (Get-ComputerDomain)
    {
        $dn = $null
        $dn = ([adsisearcher]"(&(objectCategory=computer)(objectClass=computer)(cn=$env:COMPUTERNAME))").FindOne().Properties.distinguishedname
        $ou = $dn -replace '^(CN=.*?(?<=,))', ''
    }

    return $ou
}

<#
    .SYNOPSIS
        Returns the logon server.
#>
function Get-LogonServer
{
    [CmdletBinding()]
    [OutputType([System.String])]
    param ()

    $logonserver = $env:LOGONSERVER -replace "\\", ""
    return $logonserver
}

<#
    .SYNOPSIS
        Returns an ADSI Computer Object.

    .PARAMETER Name
        Name of the computer to search for in the given domain.

    .PARAMETER Domain
        Domain to search.

    .PARAMETER Credential
        Credential to search domain with.
#>
function Get-ADSIComputer
{
    [CmdletBinding()]
    [OutputType([System.DirectoryServices.SearchResult])]
    param
    (
        [Parameter(Mandatory = $true)]
        [ValidateLength(1, 15)]
        [ValidateScript( { $_ -inotmatch '[\/\\:*?"<>|]' })]
        [System.String]
        $Name,

        [Parameter(Mandatory = $true)]
        [System.String]
        $DomainName,

        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCredential]
        $Credential
    )

    $searcher = New-Object -TypeName System.DirectoryServices.DirectorySearcher
    $searcher.Filter = "(&(objectCategory=computer)(objectClass=computer)(cn=$Name))"
    if ($DomainName -notlike "LDAP://*")
    {
        $DomainName = "LDAP://$DomainName"
    }

    $params = @{
        TypeName     = 'System.DirectoryServices.DirectoryEntry'
        ArgumentList = @(
            $DomainName,
            $Credential.UserName,
            $Credential.GetNetworkCredential().password
        )
        ErrorAction  = 'Stop'
    }
    $searchRoot = New-Object @params
    $searcher.SearchRoot = $searchRoot

    return $searcher.FindOne()
}

<#
    .SYNOPSIS
        Deletes an ADSI DirectoryEntry Object.

    .PARAMETER Path
        Path to Object to delete.

    .PARAMETER Credential
        Credential to authenticate to the domain.
#>
function Remove-ADSIObject
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [ValidateScript( { $_ -imatch "LDAP://*" })]
        [System.String]
        $Path,

        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCredential]
        $Credential
    )

    $params = @{
        TypeName     = 'System.DirectoryServices.DirectoryEntry'
        ArgumentList = @(
            $Path,
            $Credential.UserName,
            $Credential.GetNetworkCredential().password
        )
        ErrorAction  = 'Stop'
    }
    $adsiObj = New-Object @params

    $adsiObj.DeleteTree()
}

<#
    .SYNOPSIS
    This function validates the parameters passed. Called by Set-Resource.
        Will throw an error if any parameters are invalid.

    .PARAMETER Name
        The desired computer name.

    .PARAMETER DomainName
        The name of the domain to join.

    .PARAMETER JoinOU
        The distinguished name of the organizational unit that the computer
        account will be created in.

    .PARAMETER Credential
        Credential to be used to join a domain.

    .PARAMETER UnjoinCredential
        Credential to be used to leave a domain.

    .PARAMETER WorkGroupName
        The name of the workgroup.

    .PARAMETER Description
        The value assigned here will be set as the local computer description.

    .PARAMETER Options
        Specifies advanced options for the Add-Computer join operation.
#>
function Assert-ResourceProperty
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [ValidateLength(1, 15)]
        [ValidateScript( { $_ -inotmatch '[\/\\:*?"<>|]' })]
        [System.String]
        $Name,

        [Parameter()]
        [System.String]
        $DomainName,

        [Parameter()]
        [System.String]
        $JoinOU,

        [Parameter()]
        [System.Management.Automation.PSCredential]
        $Credential,

        [Parameter()]
        [System.Management.Automation.PSCredential]
        $UnjoinCredential,

        [Parameter()]
        [System.String]
        $WorkGroupName,

        [Parameter()]
        [System.String]
        $Description,

        [Parameter()]
        [System.String]
        $Server,

        [Parameter()]
        [ValidateSet('AccountCreate', 'Win9XUpgrade', 'UnsecuredJoin', 'PasswordPass', 'JoinWithNewName', 'JoinReadOnly', 'InstallInvoke')]
        [System.String[]]
        $Options
    )

    if ($options -contains 'PasswordPass' -and
        $options -notcontains 'UnsecuredJoin')
    {
        New-ArgumentException `
            -Message $script:localizedData.InvalidOptionPasswordPassUnsecuredJoin `
            -ArgumentName 'PasswordPass'
    }

    if ($Options -contains 'PasswordPass' -and
        $options -contains 'UnsecuredJoin' -and
        -not [System.String]::IsNullOrEmpty($Credential.UserName))
    {

        New-ArgumentException `
            -Message $script:localizedData.InvalidOptionCredentialUnsecuredJoinNullUsername `
            -ArgumentName 'Credential'
    }
}
