#compdef ev

_ev() {
    local -a commands
    commands=(
        'scan:Scan for reclaimable space'
        'clean:Clean selected items'
        'purge:Find projects and clean build artifacts'
        'analyze:Disk usage analysis with category breakdown'
        'status:System dashboard'
        'config:Configuration management'
        'help:Show help'
    )

    local -a categories
    categories=(dev system package ai browser)

    _arguments -C \
        '(-h --help)'{-h,--help}'[Show help]' \
        '(-v --version)'{-v,--version}'[Show version]' \
        '1:command:->command' \
        '*::arg:->args' && return

    case $state in
        command)
            _describe -t commands 'ev command' commands
            ;;
        args)
            case ${words[1]} in
                scan)
                    _arguments \
                        '(-c --category)'{-c,--category}'[Filter by category]:category:('"${categories[*]}"')' \
                        '(-h --help)'{-h,--help}'[Show help]' \
                        '1:path:_files -/'
                    ;;
                clean)
                    _arguments \
                        '--dry-run[Show what would be deleted]' \
                        '--force[Delete without confirmation]' \
                        '--dev[Only dev artifacts]' \
                        '--system[Only system caches]' \
                        '--package[Only package manager caches]' \
                        '--ai[Only AI/ML model caches]' \
                        '--browser[Only browser caches]' \
                        '(-c --category)'{-c,--category}'[Filter by category]:category:('"${categories[*]}"')' \
                        '(-h --help)'{-h,--help}'[Show help]'
                    ;;
                purge)
                    _arguments \
                        '--depth[Maximum scan depth]:depth:' \
                        '--dry-run[Show what would be deleted]' \
                        '--force[Delete without confirmation]' \
                        '(-h --help)'{-h,--help}'[Show help]' \
                        '1:path:_files -/'
                    ;;
                analyze)
                    _arguments \
                        '--depth[Scan depth for category analysis]:depth:' \
                        '--top[Number of top directories]:count:' \
                        '(-h --help)'{-h,--help}'[Show help]' \
                        '1:path:_files -/'
                    ;;
                status)
                    _arguments \
                        '(-h --help)'{-h,--help}'[Show help]'
                    ;;
                config)
                    local -a config_commands
                    config_commands=(
                        'show:Show current configuration'
                        'whitelist:Add a path to the whitelist'
                    )
                    _arguments \
                        '(-h --help)'{-h,--help}'[Show help]' \
                        '1:subcommand:->config_cmd' \
                        '*::config_arg:->config_args'
                    case $state in
                        config_cmd)
                            _describe -t config_commands 'config subcommand' config_commands
                            ;;
                        config_args)
                            case ${words[1]} in
                                whitelist)
                                    _arguments '1:path:_files'
                                    ;;
                            esac
                            ;;
                    esac
                    ;;
            esac
            ;;
    esac
}

_ev "$@"
