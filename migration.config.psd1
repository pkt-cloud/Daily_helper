@{
    OrgUrl = 'https://dev.azure.com/<organization>'

    GitRemoteUrl = 'https://dev.azure.com/<organization>/<project>/_git/<new-git-repo>'

    # Relative paths are resolved from the config-file location
    BranchListFile = '.\branches.txt'
    BaseFolder      = '.\work\MultiBranch'
    LogFile         = '.\logs\tfvc-git-migration.log'

    RemoteName = 'origin'

    # Restart-safe settings
    ReuseExistingLocalRepo   = $false
    SkipIfRemoteBranchExists = $true
    ContinueOnBranchFailure  = $true
    PushTags                 = $false
}
